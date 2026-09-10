"""The one place agents are built and structured output is requested.

Keeping every model call behind `structured()` means the eval, the tests and
the gateway all exercise the same path, and swapping providers is an env var.
"""
from __future__ import annotations

import logging
import time
from collections.abc import Sequence
from typing import Any

from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode
from pydantic import BaseModel
from strands import Agent
from strands.models import Model

from . import agent_audit, guardrails, tracing
from .models import model_for

log = logging.getLogger(__name__)


class LLMError(RuntimeError):
    """The model did not return the structured object we asked for."""


class GuardrailError(LLMError):
    """The answer broke a guardrail twice, the second time after being told.

    An `LLMError`, so every caller's existing fallback handles it: to them it
    is one more way of the model not giving a usable answer.
    """

    def __init__(self, role: str, violations: list[guardrails.Violation]) -> None:
        self.violations = violations
        super().__init__(f"heygilli-{role}: guardrail: " + "; ".join(v.detail for v in violations))


def make_agent(
    role: str,
    system_prompt: str,
    tools: Sequence[Any] = (),
    model: Model | None = None,
) -> Agent:
    """One Strands Agent per role. A fresh instance per request is cheap and avoids
    Strands' one-invocation-at-a-time rule when sessions run concurrently."""
    return Agent(
        name=f"heygilli-{role}",
        model=model or model_for(role),
        system_prompt=system_prompt,
        tools=list(tools),
        callback_handler=None,  # no stdout streaming inside a server
    )


def structured[T: BaseModel](
    agent: Agent,
    prompt: str,
    output_model: type[T],
    *,
    context: dict[str, Any] | None = None,
) -> T:
    """One agent call, traced, with its answer checked before anyone uses it.

    Every call is a root span (`heygilli.agent`) that Strands' own spans nest
    under, so the stored trace has the prompt, the model call, any tool calls,
    the tokens and the answer. The answer then goes through `guardrails.check`
    with `context` (what the check needs to know that the answer does not
    carry: a video's title, the words a child was asked). A blocking
    violation sends it back to the agent once, saying what was wrong; a second
    one raises `GuardrailError`, which callers already treat as a failed call
    and answer with their safe fallback. Each call is recorded, and each
    violation becomes an incident (`agent_audit`).
    """
    role = agent.name.removeprefix("heygilli-")
    household, kid_id = tracing.current()
    t0 = time.perf_counter()
    tracer = trace.get_tracer("heygilli")
    with tracer.start_as_current_span(
        tracing.ROOT,
        attributes={
            "heygilli.role": role,
            "heygilli.household": household,
            "heygilli.kid_id": kid_id,
            "heygilli.output": output_model.__name__,
        },
    ) as span:
        trace_id = f"{span.get_span_context().trace_id:032x}"

        def finish(outcome: str, violations: list[guardrails.Violation], error: str = "") -> None:
            span.set_attribute("heygilli.outcome", outcome)
            span.set_attribute("heygilli.rules", ",".join(v.rule for v in violations))
            if error:
                span.set_status(Status(StatusCode.ERROR, error[:300]))
            agent_audit.record(
                role=role, output=output_model.__name__, outcome=outcome, violations=violations,
                ms=int((time.perf_counter() - t0) * 1000), trace_id=trace_id,
                household=household, kid_id=kid_id,
            )

        try:
            out = _invoke(agent, prompt, output_model)
        except LLMError as e:
            finish("model_error", [], str(e))
            raise
        found = guardrails.check(output_model.__name__, out, context)
        blocked = guardrails.blocking(found)
        if not blocked:
            finish("warned" if found else "ok", found)
            return out

        span.add_event("guardrail.blocked", {"rules": [v.rule for v in blocked],
                                             "detail": [v.detail for v in blocked]})
        log.info("%s answer blocked (%s), asking again", agent.name, ", ".join(v.rule for v in blocked))
        try:
            # The first answer is in the agent's history, so the feedback alone
            # is enough for it to know what to change.
            retry = _invoke(agent, guardrails.feedback(blocked), output_model)
            still = guardrails.blocking(guardrails.check(output_model.__name__, retry, context))
        except LLMError:
            retry, still = None, blocked
        if retry is not None and not still:
            span.add_event("guardrail.fixed")
            finish("fixed", found)
            return retry
        finish("blocked", found, "guardrail")
        raise GuardrailError(role, still)


def _invoke[T: BaseModel](agent: Agent, prompt: str, output_model: type[T]) -> T:
    """Invoke the agent and return a validated `output_model` (Strands structured output).

    Every failure leaves here as `LLMError`, including the provider's own. That
    is the whole job of the `try` below.

    Callers catch `LLMError` and fall back — `build_plan` to canned questions, the
    Curator to asking the parent. None of them caught a `botocore` exception,
    because none of them import botocore, and they should not have to: a model
    that cannot be reached is one failure with one meaning, whoever is hosting it.

    It cost a production outage to learn. A model id the account was not entitled
    to invoke raised `ResourceNotFoundException`, which is not an `LLMError`, so
    it went straight past the handler written for exactly this and out of the
    gateway as a 500 — and an unhandled 500 carries no CORS headers, so the
    browser reported a CORS problem and the model was never mentioned. Videos
    with a cached plan kept working, which made it look intermittent.
    """
    t0 = time.perf_counter()
    try:
        result = agent(prompt, structured_output_model=output_model)
    except LLMError:
        raise
    except Exception as e:  # provider SDK, transport, throttling, entitlement
        raise LLMError(f"{agent.name}: {type(e).__name__}: {e}") from e
    ms = int((time.perf_counter() - t0) * 1000)
    out = result.structured_output
    if out is None:
        raise LLMError(f"{agent.name}: no {output_model.__name__} in model response")
    if not isinstance(out, output_model):
        out = output_model.model_validate(out.model_dump())
    log.info("%s -> %s in %d ms", agent.name, output_model.__name__, ms)
    return out
