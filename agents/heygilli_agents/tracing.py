"""Full traces of every agent call, kept with the household's own data.

Strands emits OpenTelemetry spans for each agent run: the agent itself, every
event-loop cycle, every model call with its messages and token counts, every
tool call. `structured()` opens one root span around each call
(`heygilli.agent`) carrying the role, the household and the child. This module
collects every span under that root and, when the root ends, stores the whole
trace as one document beside the household's other data.

Kept there rather than in an observability backend for two reasons. A trace is
readable on the free tier with nothing else deployed, and a household's traces
go when the household is deleted, like everything else about it. Set
`OTEL_EXPORTER_OTLP_ENDPOINT` and they are also sent to a collector (X-Ray,
Langfuse, Jaeger); set `HEYGILLI_TRACE_CONSOLE=1` to print them.

One thing is never kept: what a child said. Buddy's prompt carries the
child's words, and they are replaced before anything is written, in the same
way the rest of HeyGilli keeps only a score and a ten-word paraphrase.
"""
from __future__ import annotations

import json
import logging
import os
import re
import threading
import time
from collections import OrderedDict
from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from opentelemetry import trace
from opentelemetry.sdk.trace import ReadableSpan, TracerProvider
from opentelemetry.sdk.trace.export import (
    ConsoleSpanExporter,
    SimpleSpanProcessor,
    SpanExporter,
    SpanExportResult,
)

log = logging.getLogger(__name__)

ROOT = "heygilli.agent"
MAX_STR = 4000  # a transcript excerpt is the longest thing in a prompt
MAX_SPANS = 80  # per trace, applied while they are held and not only when they are stored
MAX_OPEN = 200  # traces waiting on their root; a leak guard, never reached in practice
MAX_OPEN_AGE_S = 300  # a trace nothing has added to for this long is dropped, root or no root
MAX_DOC = 350_000  # DynamoDB items stop at 400 KB

_household: ContextVar[str] = ContextVar("heygilli_household", default="")
_kid: ContextVar[str] = ContextVar("heygilli_kid", default="")


@contextmanager
def scope(household: str = "", kid_id: str = "") -> Iterator[None]:
    """Whose agent calls these are. Set once per request by the gateway."""
    t1 = _household.set(household or _household.get())
    t2 = _kid.set(kid_id or _kid.get())
    try:
        yield
    finally:
        _household.reset(t1)
        _kid.reset(t2)


def current() -> tuple[str, str]:
    return _household.get(), _kid.get()


# `child said: "..."` in Buddy's prompt, raw or JSON-escaped inside a message.
_CHILD_SAID = re.compile(r'(child said:\s*\\?")(.*?)(\\?")', re.IGNORECASE | re.DOTALL)


def redact(text: str) -> str:
    """The child's words out, the shape of the prompt kept."""
    return _CHILD_SAID.sub(lambda m: f"{m.group(1)}[not kept]{m.group(3)}", text)


def _clip(value: Any, limit: int = MAX_STR) -> Any:
    if isinstance(value, str):
        value = redact(value)
        return value if len(value) <= limit else value[:limit] + "…"
    if isinstance(value, (list, tuple)):
        return [_clip(v, limit) for v in list(value)[:50]]
    return value


def _iso(ns: int | None) -> str:
    return datetime.fromtimestamp(ns / 1e9, UTC).isoformat(timespec="milliseconds") if ns else ""


def span_doc(s: ReadableSpan, limit: int = MAX_STR) -> dict[str, Any]:
    ctx = s.get_span_context()
    return {
        "name": s.name,
        "span_id": format(ctx.span_id, "016x"),
        "parent_id": format(s.parent.span_id, "016x") if s.parent else "",
        "start": _iso(s.start_time),
        "ms": round((s.end_time - s.start_time) / 1e6, 1) if s.end_time and s.start_time else 0,
        "status": s.status.status_code.name,
        "error": s.status.description or "",
        "attributes": {k: _clip(v, limit) for k, v in dict(s.attributes or {}).items()},
        "events": [
            {"name": e.name, "attributes": {k: _clip(v, limit) for k, v in dict(e.attributes or {}).items()}}
            for e in list(s.events)[:40]
        ],
    }


def _shrink(value: Any, limit: int) -> Any:
    """Cut an already-clipped span document down further, for a trace too big to store.

    Redaction has happened by the time anything gets here: this only shortens.
    """
    if isinstance(value, str):
        return value if len(value) <= limit else value[:limit] + "\u2026"
    if isinstance(value, list):
        return [_shrink(v, limit) for v in value]
    if isinstance(value, dict):
        return {k: _shrink(v, limit) for k, v in value.items()}
    return value


class StoreSpanExporter(SpanExporter):
    """Holds a trace's spans until its root ends, then stores them as one document.

    What is held is each span's *document*, not the span. A model-call span
    carries the whole prompt, and a Curator prompt is a transcript; keeping the
    spans themselves meant a handful of traces in flight could hold tens of
    megabytes of text that only ever gets clipped on the way out. Clipping on
    the way in costs the same work and bounds what is resident to
    `MAX_SPANS` clipped documents per trace.

    Two guards on top of that, because a trace is only released by its root
    ending and a span tree that never reaches one would otherwise sit forever:
    `MAX_OPEN` traces at once, and nothing older than `MAX_OPEN_AGE_S` since
    its last span.
    """

    def __init__(self) -> None:
        # trace id -> [monotonic time of the last span, that trace's span docs]
        self._open: OrderedDict[int, list[Any]] = OrderedDict()
        self._lock = threading.Lock()

    def export(self, spans: Sequence[ReadableSpan]) -> SpanExportResult:
        for s in spans:
            tid = s.get_span_context().trace_id
            doc = span_doc(s)  # clipped and redacted here, not when the trace is stored
            now = time.monotonic()
            with self._lock:
                held = self._open.setdefault(tid, [now, []])
                held[0] = now
                if len(held[1]) < MAX_SPANS:
                    held[1].append(doc)
                self._open.move_to_end(tid)
                self._evict(now)
                done = self._open.pop(tid)[1] if s.name == ROOT else None
            if done is not None:
                self._save(tid, s, done)
        return SpanExportResult.SUCCESS

    def _evict(self, now: float) -> None:
        """Drop the traces least recently added to. Caller holds the lock."""
        while self._open:
            tid = next(iter(self._open))
            touched = self._open[tid][0]
            if len(self._open) > MAX_OPEN or now - touched > MAX_OPEN_AGE_S:
                self._open.popitem(last=False)
            else:
                break

    def _save(self, tid: int, root: ReadableSpan, spans: list[dict[str, Any]]) -> None:
        from .store import GLOBAL, get_store

        a = dict(root.attributes or {})
        ordered = sorted(spans, key=lambda d: d["start"])[:MAX_SPANS]
        doc: dict[str, Any] = {}
        for limit in (MAX_STR, 1000, 300):  # shrink until it fits one item
            doc = {
                "trace_id": f"{tid:032x}",
                "role": a.get("heygilli.role", ""),
                "kid_id": a.get("heygilli.kid_id", ""),
                "output": a.get("heygilli.output", ""),
                "outcome": a.get("heygilli.outcome", ""),
                "rules": a.get("heygilli.rules", ""),
                "started": _iso(root.start_time),
                "ms": round(((root.end_time or 0) - (root.start_time or 0)) / 1e6, 1),
                "status": root.status.status_code.name,
                "spans": ordered if limit == MAX_STR else _shrink(ordered, limit),
            }
            if len(json.dumps(doc, ensure_ascii=False)) <= MAX_DOC:
                break
        try:
            get_store().put(a.get("heygilli.household") or GLOBAL, "trace", doc["trace_id"], doc)
        except Exception as e:  # noqa: BLE001 - a trace must never break the call it describes
            log.warning("could not store trace %s: %s", doc["trace_id"], e)

    def shutdown(self) -> None:
        with self._lock:
            self._open.clear()


_ready = False


def setup_tracing() -> None:
    """Install the tracer provider every Strands agent reports to. Idempotent."""
    global _ready
    if _ready or os.getenv("HEYGILLI_TRACES", "on").lower() == "off":
        return
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(StoreSpanExporter()))
    if os.getenv("HEYGILLI_TRACE_CONSOLE"):
        provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
    if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        try:
            from strands.telemetry import StrandsTelemetry

            StrandsTelemetry(tracer_provider=provider).setup_otlp_exporter()
        except Exception as e:  # noqa: BLE001 - the stored traces still work without a collector
            log.warning("OTLP export not set up: %s", e)
    trace.set_tracer_provider(provider)
    _ready = True
