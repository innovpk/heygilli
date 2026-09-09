"""The one place agents are built and structured output is requested.

Keeping every model call behind `structured()` means the eval, the tests and
the gateway all exercise the same path, and swapping providers is an env var.
"""
from __future__ import annotations

import logging
import time
from collections.abc import Sequence
from typing import Any

from pydantic import BaseModel
from strands import Agent
from strands.models import Model

from .models import model_for

log = logging.getLogger(__name__)


class LLMError(RuntimeError):
    """The model did not return the structured object we asked for."""


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


def structured[T: BaseModel](agent: Agent, prompt: str, output_model: type[T]) -> T:
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
