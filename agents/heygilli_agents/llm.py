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
    """Invoke the agent and return a validated `output_model` (Strands structured output)."""
    t0 = time.perf_counter()
    result = agent(prompt, structured_output_model=output_model)
    ms = int((time.perf_counter() - t0) * 1000)
    out = result.structured_output
    if out is None:
        raise LLMError(f"{agent.name}: no {output_model.__name__} in model response")
    if not isinstance(out, output_model):
        out = output_model.model_validate(out.model_dump())
    log.info("%s -> %s in %d ms", agent.name, output_model.__name__, ms)
    return out
