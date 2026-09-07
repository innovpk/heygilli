"""The written question bank, and the parent's say over it.

Every video used to end with one hardcoded line per band — "can you clap for
the video?" for a five-year-old, every video. With no transcript reachable
from the deployed gateway that was every video they ever saw, and a child
stops answering by the third time.
"""
from __future__ import annotations

import pytest

from heygilli_agents import planner, question_bank
from heygilli_agents.schemas import TYPES_FOR_BAND, Video


def test_every_prompt_is_askable_in_the_band_it_claims() -> None:
    """A band is not a label: it is what the child can actually do. A written
    question in the wrong band asks a pre-reader to compare two things."""
    seen_ids = set()
    for p in question_bank.PROMPTS:
        assert p.id not in seen_ids, f"duplicate prompt id {p.id}"
        seen_ids.add(p.id)
        assert p.type in TYPES_FOR_BAND[p.band], f"{p.id} is a {p.type} in band {p.band}"
        assert p.text.get("en") and p.text.get("ur"), f"{p.id} is missing a language"
        # A pre-reader is never shown text, so their questions are spoken and
        # answered by voice or by doing something — never by reading options.
        if p.band == "4_6":
            assert p.input in ("voice", "copy"), f"{p.id} asks a pre-reader to read"


def test_every_band_has_enough_that_a_child_is_not_asked_one_thing() -> None:
    for band in ("4_6", "7_8", "9_11"):
        assert len(question_bank.for_band(band)) >= 5, f"{band} has too few to vary"


def test_different_videos_get_different_questions_and_the_same_one_repeats() -> None:
    """Chosen by hashing the video id: a child returning to a video is asked
    what they were asked before — the question is part of that video for them
    — while the next video asks something else."""
    picks = [question_bank.pick("4_6", f"vid{i}") for i in range(24)]
    assert len({p.id for p in picks}) > 1, "every video got the same question again"
    assert question_bank.pick("4_6", "vid7").id == question_bank.pick("4_6", "vid7").id


def test_a_parent_can_turn_one_off_and_it_is_never_picked() -> None:
    band = "4_6"
    everything = {p.id for p in question_bank.for_band(band)}
    off = ["p46_clap"]
    assert "p46_clap" in everything

    assert {p.id for p in question_bank.allowed(band, off)} == everything - {"p46_clap"}
    picks = {question_bank.pick(band, f"vid{i}", off).id for i in range(60)}
    assert "p46_clap" not in picks, "a question the parent removed was still asked"


def test_turning_everything_off_asks_nothing_rather_than_falling_back() -> None:
    """A quiet video is a real setting. Falling back to an ignored question
    would make the parent's choice a suggestion."""
    band = "4_6"
    off = [p.id for p in question_bank.for_band(band)]
    assert question_bank.pick(band, "vid1", off) is None

    plan = planner.fallback_plan(Video(id="vid1", title="T", duration_s=600), band, "en", off)
    assert plan.questions == []


def test_an_id_that_no_longer_exists_is_ignored_not_fatal() -> None:
    """Households outlive releases: a prompt removed from the bank must not
    break every plan for the parents who had turned it off."""
    assert question_bank.allowed("4_6", ["p46_gone_in_a_later_release"]) == question_bank.for_band("4_6")


def test_urdu_is_written_not_translated_at_runtime() -> None:
    p = question_bank.find("p46_clap")
    q = question_bank.as_question(p, 100, "ur")
    assert q.text == p.text["ur"] and q.text != p.text["en"]
    assert q.t_sec == 100


@pytest.mark.parametrize("band", ["4_6", "7_8", "9_11"])
def test_the_fallback_no_longer_asks_the_same_thing_every_time(band) -> None:
    texts = {
        planner.fallback_plan(Video(id=f"v{i}", title="T", duration_s=600), band, "en").questions[0].text
        for i in range(24)
    }
    assert len(texts) > 1, f"{band} still has one hardcoded question for every video"
