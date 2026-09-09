"""A model that cannot be reached is one failure with one meaning."""
from __future__ import annotations

import pytest
from pydantic import BaseModel

from heygilli_agents.llm import LLMError, structured


class Out(BaseModel):
    x: int


class _Boom:
    """Stands in for a Strands agent whose provider raises."""

    name = "heygilli-planner"

    def __init__(self, exc: Exception) -> None:
        self._exc = exc

    def __call__(self, *_args, **_kwargs):
        raise self._exc


class _ResourceNotFound(Exception):
    """Shaped like botocore's, which is all that matters here."""


def test_a_provider_exception_becomes_an_llm_error():
    # The one that took the gateway down: an entitlement error is not an
    # LLMError, so `except LLMError` in build_plan never saw it and a 500 went
    # out instead of the canned questions that handler exists to produce.
    agent = _Boom(_ResourceNotFound("Model use case details have not been submitted"))
    with pytest.raises(LLMError) as caught:
        structured(agent, "prompt", Out)
    assert "_ResourceNotFound" in str(caught.value)
    assert "use case details" in str(caught.value)


def test_the_cause_is_kept():
    original = _ResourceNotFound("nope")
    agent = _Boom(original)
    with pytest.raises(LLMError) as caught:
        structured(agent, "prompt", Out)
    assert caught.value.__cause__ is original


def test_an_llm_error_passes_through_unwrapped():
    agent = _Boom(LLMError("already ours"))
    with pytest.raises(LLMError, match="already ours"):
        structured(agent, "prompt", Out)
