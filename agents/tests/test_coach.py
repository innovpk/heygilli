"""Break-message suggestions: written for the parent, never for the child.

Offline with the fake model. The guarantee under test is the one that made this
design worth switching to: nothing a model writes can reach a child. These are
lines a parent sees, edits and saves, and even at that stage the safety gate
keeps careless ones off the screen.
"""

from __future__ import annotations

from typing import Any

import pytest

from heygilli_agents import breaks, coach
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import AgeBand, BreakMessage, Kid


def kid(age: int = 8) -> Kid:
    return Kid(household_id="hh_1", nickname="Abu", age=age)


def agent_returning(messages: list[dict[str, str]]):
    """A coach agent whose model always answers with these drafts."""

    def canned(model_name: str, _text: str) -> dict[str, Any]:
        return {"messages": messages} if model_name == "SuggestedMessages" else {}

    return make_agent("coach", "s", model=FakeModel(canned))


def agent_that_fails():
    def boom(_model_name: str, _text: str) -> dict[str, Any]:
        raise RuntimeError("provider is down")

    return make_agent("coach", "s", model=FakeModel(boom))


class TestTheParentGetsUsableLines:
    def test_safe_drafts_are_passed_through(self) -> None:
        drafts = [
            {"text": "Go and kick a ball against the wall.", "spoken": "Go and kick a ball."},
            {"text": "Tell someone the score.", "spoken": "Go and tell someone the score."},
        ]
        kept, rejected = coach.suggest_messages(kid(), ["Barcelona highlights"], agent_returning(drafts))

        assert rejected == []
        assert kept[0].text == "Go and kick a ball against the wall."
        assert len(kept) == coach.WANTED, "the screen is topped up rather than left short"

    def test_the_prompt_carries_what_was_actually_watched(self) -> None:
        prompt = coach.suggest_prompt("7_8", "Abu", ["Barcelona highlights", "Danny Go dance"])

        assert "Barcelona highlights" in prompt and "Danny Go dance" in prompt
        assert "Abu" in prompt and "7_8" in prompt

    def test_no_history_still_produces_a_prompt(self) -> None:
        assert "nothing recent" in coach.suggest_prompt("4_6", "Abeeha", [])

    @pytest.mark.parametrize("band", ["4_6", "7_8", "9_11"])
    def test_a_provider_failure_still_fills_the_screen(self, band: AgeBand) -> None:
        age = {"4_6": 5, "7_8": 8, "9_11": 10}[band]
        kept, rejected = coach.suggest_messages(kid(age), ["anything"], agent_that_fails())

        assert len(kept) == coach.WANTED
        assert rejected and "generation failed" in rejected[0]
        assert all(breaks.validate_message(m, band) is None for m in kept)


class TestTheGateProtectsTheParentToo:
    def test_an_unsafe_draft_never_reaches_the_parents_screen(self) -> None:
        drafts = [
            {"text": "Climb on the sofa and jump off.", "spoken": "Climb on the sofa."},
            {"text": "Tidy one thing in your room.", "spoken": "Go and tidy one thing."},
        ]
        kept, rejected = coach.suggest_messages(kid(), [], agent_returning(drafts))

        assert all("Climb" not in m.text for m in kept)
        assert len(rejected) == 1 and "climbing" in rejected[0]

    def test_a_pre_reader_is_never_given_a_routine_to_remember(self) -> None:
        drafts = [{
            "text": "First, get your blocks. Next, build a tower. After that, knock it down.",
            "spoken": "First, get your blocks. Next, build a tower. After that, knock it down.",
        }]
        kept, rejected = coach.suggest_messages(kid(5), [], agent_returning(drafts))

        assert rejected and "sequence" in rejected[0]
        assert all("After that" not in m.text for m in kept)

    def test_a_draft_with_no_spoken_line_is_refused_for_a_pre_reader(self) -> None:
        drafts = [{"text": "Tidy your toys.", "spoken": ""}]
        _, rejected = coach.suggest_messages(kid(5), [], agent_returning(drafts))

        assert rejected and "spoken" in rejected[0]

    def test_the_built_ins_all_pass_the_gate(self) -> None:
        for band in ("4_6", "7_8", "9_11"):
            for m in coach.builtin_suggestions(band):
                assert breaks.validate_message(m, band) is None, m.text

    def test_going_to_find_a_grown_up_is_allowed(self) -> None:
        """Needing an adult was a hazard for a child miming alone; in a break
        message it is exactly what a parent wants."""
        msg = BreakMessage(text="Go and find a grown-up.", spoken="Go and find a grown-up.")
        assert breaks.validate_message(msg, "4_6") is None
