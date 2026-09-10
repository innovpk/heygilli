"""Guardrails on every agent's answer: checked, sent back once, then the fallback. Offline."""
from __future__ import annotations

from types import SimpleNamespace

import pytest

from heygilli_agents import guardrails, tracing
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import GuardrailError, LLMError, make_agent, structured
from heygilli_agents.playmate import PlayDraft, PlayIn, next_turn
from heygilli_agents.schemas import (
    CuratorDecision,
    DigestNarrative,
    Kid,
    Option,
    PlanDraft,
    Score,
    ScoredReply,
)
from heygilli_agents.schemas import Question as Q


def q(text: str, **kw) -> Q:
    return Q(t_sec=60, type="name_it", input="voice", text=text, **kw)


def rules(found) -> list[str]:
    return [v.rule for v in found]


# --- the checks ---------------------------------------------------------------------------------------


def test_gilli_never_tells_a_child_they_were_wrong() -> None:
    bad = ScoredReply(result="off_topic", paraphrase="a cat", reply_text="No, that is wrong.")
    assert "harsh_reply" in rules(guardrails.check("ScoredReply", bad))
    ok = ScoredReply(result="off_topic", paraphrase="a cat", reply_text="A cat! I saw a giraffe too.")
    assert guardrails.check("ScoredReply", ok) == []


def test_a_question_may_not_ask_a_child_about_themselves() -> None:
    found = guardrails.check("PlanDraft", PlanDraft(questions=[q("What is your name?")]))
    assert rules(found) == ["personal_question"]


def test_science_is_not_scary() -> None:
    assert guardrails.check("PlanDraft", PlanDraft(questions=[q("Why is blood red?")])) == []


def test_a_picture_card_is_child_text_too() -> None:
    plan = PlanDraft(questions=[
        q("Which one?", options=[Option(icon_id="icon_x", label="zombie", correct=True)]),
    ])
    assert rules(guardrails.check("PlanDraft", plan)) == ["unsafe_word"]


def test_the_curator_cannot_approve_its_own_red_flags() -> None:
    yes = CuratorDecision(decision="approve", reason="Fine.")
    assert rules(guardrails.check("CuratorDecision", yes, {"title": "Zombie dance party"})) == ["approved_unsafe"]
    assert rules(guardrails.check("CuratorDecision", yes, {"title": "Toy unboxing"})) == ["approved_without_asking"]
    hide = CuratorDecision(decision="hide", reason="Scary.")
    assert guardrails.check("CuratorDecision", hide, {"title": "Zombie dance party"}) == []


def test_approving_with_concerns_is_flagged_not_blocked() -> None:
    found = guardrails.check("CuratorDecision", CuratorDecision(decision="approve", reason="Ok.", concerns=["loud"]))
    assert rules(found) == ["approved_with_concerns"] and guardrails.blocking(found) == []


def test_a_digest_cannot_invent_words_a_child_heard() -> None:
    d = DigestNarrative(words_heard=["giraffe", "pizza"], dinner_prompt="Ask about giraffes.")
    found = guardrails.check("DigestNarrative", d, {"words": ["giraffe"]})
    assert rules(found) == ["invented_words"] and "pizza" in found[0].detail


def test_the_paraphrase_stays_under_ten_words() -> None:
    # `Score` already trims it when built, so the check is exercised on the
    # raw shape a model could hand back before that.
    long = SimpleNamespace(paraphrase="one two three four five six seven eight nine ten eleven")
    assert rules(guardrails.check("Score", long)) == ["long_paraphrase"]
    assert guardrails.check("Score", Score(result="correct", paraphrase="a red ball")) == []


# --- enforcement in structured() -------------------------------------------------------------------------


BAD = {"level": 2, "line": "You scored 3 points!"}
GOOD = {"level": 2, "line": "Find me if you can!"}


def scripted(learns: bool):
    """A model that breaks the rule, and fixes it only once told (if it `learns`).

    Keyed on what it was told rather than on call count: Strands may call a
    model more than once within a single structured-output run.
    """
    seen: list[str] = []

    def canned(name: str, text: str) -> dict:
        seen.append(text)
        return GOOD if learns and "cannot be used" in text else BAD

    return make_agent("playmate", "sys", model=FakeModel(canned)), seen


def test_a_blocked_answer_is_sent_back_and_the_fix_is_used(store) -> None:
    agent, seen = scripted(learns=True)
    with tracing.scope("hh_g", "kid_g"):
        out = structured(agent, "go", PlayDraft, context={"band": "7_8"})
    assert out.line == GOOD["line"]
    assert any("cannot be used" in s for s in seen)  # the agent was told what was wrong
    [event] = store.list("hh_g", "agent_event")
    assert event["outcome"] == "fixed" and event["rules"] == ["game_line"] and event["kid_id"] == "kid_g"
    [incident] = store.list("hh_g", "agent_incident")
    assert incident["outcome"].startswith("fixed") and incident["trace_id"] == event["trace_id"]


def test_twice_wrong_means_the_fallback(store) -> None:
    agent, _ = scripted(learns=False)
    with tracing.scope("hh_g", "kid_g"), pytest.raises(GuardrailError) as err:
        structured(agent, "go", PlayDraft, context={"band": "7_8"})
    assert isinstance(err.value, LLMError)  # so every caller's fallback already handles it
    [event] = store.list("hh_g", "agent_event")
    assert event["outcome"] == "blocked"
    [incident] = store.list("hh_g", "agent_incident")
    assert incident["outcome"].startswith("fallback")


def test_a_model_failure_is_recorded_but_is_not_an_incident(store) -> None:
    def boom(name, text):
        raise RuntimeError("model down")

    with tracing.scope("hh_g"), pytest.raises(LLMError):
        structured(make_agent("digest", "sys", model=FakeModel(boom)), "go", DigestNarrative)
    [event] = store.list("hh_g", "agent_event")
    assert event["outcome"] == "model_error"
    assert store.list("hh_g", "agent_incident") == []


def test_the_playmate_falls_back_to_its_rule_when_the_agent_keeps_breaking_one(store) -> None:
    agent, _ = scripted(learns=False)
    kid = Kid(household_id="hh_g", nickname="k", age=8)
    turn = next_turn(kid, PlayIn(game="find"), 10, agent=agent)
    assert turn.decided_by == "rule" and not any(c.isdigit() for c in turn.line)
