"""A deterministic Strands model provider so the test suite runs with no network.

Strands implements invocation-time structured output by registering a tool named
after the Pydantic class and asking the model to call it. `FakeModel.stream`
plays along: when such a tool is in `tool_specs` it emits one tool-use block
with canned JSON; otherwise it emits a short text reply. `structured_output`
(the legacy path) yields the same canned object directly.

Select it with `HEYGILLI_MODEL_<ROLE>=fake:` or pass `FakeModel()` to an agent.
"""
from __future__ import annotations

import json
import re
import uuid
from collections.abc import AsyncGenerator, AsyncIterable, Callable
from typing import Any, TypeVar

from pydantic import BaseModel
from strands.models import Model
from strands.types.content import Messages
from strands.types.streaming import StreamEvent
from strands.types.tools import ToolSpec

T = TypeVar("T", bound=BaseModel)
Canned = Callable[[str, str], dict[str, Any]]  # (pydantic class name, last user text) -> payload


def _last_user_text(messages: Messages) -> str:
    for m in reversed(messages):
        if m.get("role") == "user":
            return " ".join(b.get("text", "") for b in m.get("content", []) if "text" in b)
    return ""


def _band(text: str) -> str:
    m = re.search(r"age_band:\s*(4_6|7_8|9_11)", text)
    return m.group(1) if m else "7_8"


def _duration(text: str) -> int:
    m = re.search(r"duration_s:\s*(\d+)", text)
    return int(m.group(1)) if m else 600


def _lang(text: str) -> str:
    m = re.search(r"language:\s*(en|ur)", text)
    return m.group(1) if m else "en"


# Urdu question texts keyed by the English canned text, so the eval's language check holds offline.
_UR = {
    "What animal is that?": "یہ کون سا جانور ہے؟",
    "Show me the red one.": "مجھے لال والا دکھاؤ۔",
    "Can you roar like him?": "کیا تم اس کی طرح دہاڑ سکتے ہو؟",
    "What did the giraffe eat?": "زرافے نے کیا کھایا؟",
    "Why did the ice melt?": "برف کیوں پگھلی؟",
    "What do you think happens next?": "تمہارے خیال میں آگے کیا ہوگا؟",
    "How does a volcano erupt?": "آتش فشاں کیسے پھٹتا ہے؟",
    "How is a volcano like a fizzy drink?": "آتش فشاں فزی ڈرنک جیسا کیسے ہے؟",
    "Do you agree with him? Why?": "کیا تم اس سے متفق ہو؟ کیوں؟",
}


def default_canned(model_name: str, text: str) -> dict[str, Any]:
    """Valid-looking payloads for every structured output HeyGilli asks for."""
    band = _band(text)
    if model_name == "PlanDraft":
        if band == "4_6":
            qs = [
                {"t_sec": 130, "type": "name_it", "input": "voice", "text": "What animal is that?",
                 "expected": "giraffe", "variants": ["raffe", "giraf"],
                 "model_line": "A giraffe! Gi-raffe.", "gesture": "stretch"},
                {"t_sec": 520, "type": "pick_it", "input": "pick", "text": "Show me the red one.",
                 "expected": "red",
                 "options": [{"icon_id": "icon_red", "label": "red", "correct": True},
                             {"icon_id": "icon_fish", "label": "fish", "correct": False},
                             {"icon_id": "icon_car", "label": "car", "correct": False}]},
                {"t_sec": 900, "type": "copy_it", "input": "copy", "text": "Can you roar like him?",
                 "expected": "roar", "gesture": "roar"},
            ]
        elif band == "7_8":
            qs = [
                {"t_sec": 100, "type": "recall", "input": "voice",
                 "text": "What did the giraffe eat?", "expected": "leaves", "variants": ["tree leaves"]},
                {"t_sec": 400, "type": "why", "input": "voice", "text": "Why did the ice melt?",
                 "expected": "the sun warmed it", "variants": ["it got hot", "heat"]},
                {"t_sec": 700, "type": "predict", "input": "voice",
                 "text": "What do you think happens next?", "expected": "the ball rolls away"},
            ]
        else:
            qs = [
                {"t_sec": 100, "type": "explain", "input": "voice",
                 "text": "How does a volcano erupt?", "expected": "pressure pushes magma up"},
                {"t_sec": 400, "type": "compare", "input": "voice",
                 "text": "How is a volcano like a fizzy drink?", "expected": "gas builds pressure"},
                {"t_sec": 700, "type": "opinion", "input": "voice",
                 "text": "Do you agree with him? Why?", "expected": "any reasoned opinion"},
            ]
        if _lang(text) == "ur":
            for q in qs:
                q["text"] = _UR.get(q["text"], q["text"])
        return {"questions": qs}
    if model_name in ("ScoredReply", "Score"):
        said = re.search(r"child said:\s*\"([^\"]*)\"", text)
        transcript = said.group(1) if said else ""
        result = "correct" if transcript else "silence"
        out = {"result": result, "paraphrase": " ".join(transcript.split()[:10])}
        if model_name == "ScoredReply":
            out["reply_text"] = "Yes! That is exactly it. Here is one more thing: giraffes have purple tongues."
        return out
    if model_name == "BreakTask":
        if band == "4_6":
            return {
                "title": "Be a volcano",
                "steps": ["Crouch down teeny tiny and erupt up tall with your arms."],
                "seconds": 90,
                "spoken": "Let's be a volcano! Crouch down teeny tiny... and ERUPT up taaall!",
            }
        return {
            "title": "Volcano countdown",
            "steps": [
                "Crouch as low as you can and count down from five.",
                "Erupt up tall on zero with your arms wide.",
                "Five eruptions, each one slower than the last.",
            ],
            "seconds": 120,
            "spoken": "Crouch low, count down from five, and erupt up tall. Five times!",
        }
    if model_name == "CuratorDecision":
        return {"decision": "approve", "reason": "Educational animal video, calm tone.", "topics": ["animals"]}
    if model_name == "ChannelReviewDraft":
        return {
            "verdict": "good",
            "summary": "Short science explainers for young children, one topic per video.",
            "flags": [],
            "good_for": ["4_6", "7_8"],
        }
    if model_name == "AnalyticsNote":
        return {
            "kind": "suggestion",
            "text": "Steady watching this fortnight. Try asking about volcanoes on the way to school.",
        }
    if model_name == "DigestNarrative":
        return {
            "understood": ["why ice melts"],
            "shaky": [],
            "words_heard": ["giraffe", "red"],
            "dinner_prompt": "Ask what the giraffe ate today.",
            "notify": False,
            "notify_reason": "",
        }
    return {}


class FakeModel(Model):
    """Deterministic provider. `canned(model_name, last_user_text) -> dict`."""

    def __init__(self, canned: Canned | None = None, text_reply: str = "ok") -> None:
        self.canned = canned or default_canned
        self.text_reply = text_reply
        self.calls: list[dict[str, Any]] = []
        self._config: dict[str, Any] = {"model_id": "fake"}

    def update_config(self, **model_config: Any) -> None:
        self._config.update(model_config)

    def get_config(self) -> dict[str, Any]:
        return self._config

    def _payload(self, model_name: str, messages: Messages) -> dict[str, Any]:
        text = _last_user_text(messages)
        payload = self.canned(model_name, text)
        self.calls.append({"model": model_name, "prompt": text})
        return payload

    async def structured_output(
        self, output_model: type[T], prompt: Messages, system_prompt: str | None = None, **kwargs: Any
    ) -> AsyncGenerator[dict[str, T | Any], None]:
        yield {"output": output_model.model_validate(self._payload(output_model.__name__, prompt))}

    async def stream(
        self,
        messages: Messages,
        tool_specs: list[ToolSpec] | None = None,
        system_prompt: str | None = None,
        **kwargs: Any,
    ) -> AsyncIterable[StreamEvent]:
        target = self._structured_tool(tool_specs or [], messages)
        yield {"messageStart": {"role": "assistant"}}
        if target is None:
            self.calls.append({"model": None, "prompt": _last_user_text(messages)})
            yield {"contentBlockStart": {"start": {}}}
            yield {"contentBlockDelta": {"delta": {"text": self.text_reply}}}
            yield {"contentBlockStop": {}}
            yield {"messageStop": {"stopReason": "end_turn"}}
        else:
            name, payload = target
            tool_use_id = f"tooluse_{uuid.uuid4().hex[:24]}"
            yield {"contentBlockStart": {"start": {"toolUse": {"name": name, "toolUseId": tool_use_id}}}}
            yield {"contentBlockDelta": {"delta": {"toolUse": {"input": json.dumps(payload)}}}}
            yield {"contentBlockStop": {}}
            yield {"messageStop": {"stopReason": "tool_use"}}
        yield {
            "metadata": {
                "usage": {"inputTokens": 1, "outputTokens": 1, "totalTokens": 2},
                "metrics": {"latencyMs": 1},
            }
        }

    def _structured_tool(
        self, tool_specs: list[ToolSpec], messages: Messages
    ) -> tuple[str, dict[str, Any]] | None:
        """Find the structured-output tool Strands injected (its name is the Pydantic class)."""
        for spec in tool_specs:
            name = spec.get("name", "")
            if name and name[0].isupper() and self.canned(name, "") != {}:
                return name, self._payload(name, messages)
        return None
