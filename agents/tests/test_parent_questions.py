"""A question the parent wrote is asked, and asked where it belongs.

The Planner knows what happened in a video. A parent knows their own child —
that this one has been asking about volcanoes all week, or that the woman about
to appear is the grandmother they call Nani. Nothing in a model can supply that.
"""
from __future__ import annotations

from itertools import pairwise

import pytest

from heygilli_agents import parent_questions, rules
from heygilli_agents.schemas import Kid, ParentQuestion, Question, QuestionPlan, Video


def q(t: int, text: str = "planner question", mode: str = "voice") -> Question:
    return Question(t_sec=t, type="recall", input=mode, text=text)


def plan(*questions: Question) -> QuestionPlan:
    return QuestionPlan(video_id="v1", age_band="7_8", language="en", questions=list(questions))


@pytest.fixture
def kid() -> Kid:
    return Kid(
        id="kid_1", household_id="hh_1", nickname="A", age=7,
        age_band="7_8", languages=["en"],
    )


VIDEO = Video(id="v1", title="Volcanoes", description="", duration_s=1200)


def add(store, kid, **kw) -> ParentQuestion:
    pq = ParentQuestion(kid_id=kid.id, video_id="v1", **kw)
    store.put_parent_question(kid.household_id, pq)
    return pq


class TestItIsAsked:
    def test_the_parent_s_words_reach_the_child_unchanged(self, store, kid) -> None:
        add(store, kid, text="Which animal was the fastest?")
        out = parent_questions.seed(plan(q(300)), kid, store, VIDEO)
        texts = [x.text for x in out.questions]
        assert "Which animal was the fastest?" in texts

    def test_a_plan_with_none_is_untouched(self, store, kid) -> None:
        before = plan(q(300), q(600))
        after = parent_questions.seed(before, kid, store, VIDEO)
        assert after.questions == before.questions

    def test_yes_no_becomes_two_cards_with_no_right_answer(self, store, kid) -> None:
        add(store, kid, text="Did you like the ending?", yes_no=True)
        out = parent_questions.seed(plan(q(300)), kid, store, VIDEO)
        added = next(x for x in out.questions if x.text == "Did you like the ending?")
        assert added.input == "pick"
        assert [o.icon_id for o in added.options] == [rules.YES_ID, rules.NO_ID]
        # "Did you like it?" has no correct answer and a child cannot get it wrong.
        assert not any(o.correct for o in added.options)

    def test_the_cached_plan_is_not_written_to(self, store, kid) -> None:
        # Plans are shared by every household; this belongs to one child.
        add(store, kid, text="Mine")
        before = plan(q(300))
        parent_questions.seed(before, kid, store, VIDEO)
        assert [x.text for x in before.questions] == ["planner question"]


class TestWhereItGoes:
    def test_it_is_never_crammed_against_another_question(self, store, kid) -> None:
        add(store, kid, text="Mine")
        out = parent_questions.seed(plan(q(300), q(600)), kid, store, VIDEO)
        times = sorted(x.t_sec for x in out.questions)
        gap = rules.min_gap_s("7_8")
        assert all(b - a >= gap for a, b in pairwise(times))

    def test_it_respects_the_first_question_threshold(self, store, kid) -> None:
        add(store, kid, text="Mine", t_sec=5)
        out = parent_questions.seed(plan(q(600)), kid, store, VIDEO)
        mine = next(x for x in out.questions if x.text == "Mine")
        assert mine.t_sec >= rules.TIMING["7_8"].first_question_s

    def test_a_named_second_is_honoured_and_ours_moves(self, store, kid) -> None:
        # The parent said "ask this at 300". A planner question sitting there is
        # the one that gives way — they asked, we guessed.
        add(store, kid, text="Mine", t_sec=300)
        out = parent_questions.seed(plan(q(310, "ours")), kid, store, VIDEO)
        assert [x.text for x in out.questions] == ["Mine"]

    def test_it_lands_in_the_roomiest_gap(self, store, kid) -> None:
        add(store, kid, text="Mine")
        out = parent_questions.seed(plan(q(100), q(1100)), kid, store, VIDEO)
        mine = next(x for x in out.questions if x.text == "Mine")
        assert 300 < mine.t_sec < 900, f"landed at {mine.t_sec}, not in the middle"

    def test_a_video_with_no_room_simply_does_not_take_one(self, store, kid) -> None:
        add(store, kid, text="Mine")
        short = Video(id="v1", title="t", description="", duration_s=200)
        out = parent_questions.seed(plan(q(100)), kid, store, short)
        assert all(x.text != "Mine" for x in out.questions)


class TestLimits:
    def test_a_video_cannot_become_a_worksheet(self, store, kid) -> None:
        for i in range(6):
            add(store, kid, text=f"Q{i}")
        out = parent_questions.seed(plan(), kid, store, VIDEO)
        assert len(out.questions) <= parent_questions.MAX_PER_VIDEO

    def test_a_broken_read_does_not_take_the_session_down(self, kid, store) -> None:
        class Broken:
            def list_parent_questions(self, *a, **kw):
                raise RuntimeError("storage is having a day")

        before = plan(q(300))
        got = parent_questions.seed(before, kid, Broken(), VIDEO)
        assert got.questions == before.questions


class TestAutoPlacementNeverEvicts:
    """Where the parent named a second, ours gives way. Where we chose it, it does not.

    Both questions were wanted by somebody. Only one of them was placed by a
    person who knows the child, and only when they said where.
    """

    def test_choosing_a_slot_ourselves_keeps_every_planner_question(self, store, kid) -> None:
        add(store, kid, text="Mine")
        before = plan(q(100, "a"), q(400, "b"), q(700, "c"))
        out = parent_questions.seed(before, kid, store, VIDEO)
        kept = [x.text for x in out.questions]
        for original in ("a", "b", "c"):
            assert original in kept, f"auto-placement evicted {original}"

    def test_and_still_respects_the_gap(self, store, kid) -> None:
        add(store, kid, text="Mine")
        out = parent_questions.seed(plan(q(100, "a"), q(400, "b"), q(700, "c")), kid, store, VIDEO)
        times = sorted(x.t_sec for x in out.questions)
        gap = rules.min_gap_s("7_8")
        assert all(b - a >= gap for a, b in pairwise(times))

    def test_a_gap_that_exists_but_is_too_small_is_not_used(self, store, kid) -> None:
        # 620 seconds with questions at 200 and 500 leaves three intervals, and
        # the widest is 300 against a 180-second minimum — enough to look like
        # room, not enough to be it. Dropping the width check puts the parent's
        # question at 350, fifty seconds under the gap, and a child gets two
        # questions almost on top of each other.
        add(store, kid, text="Mine")
        cramped = Video(id="v1", title="t", description="", duration_s=620)
        out = parent_questions.seed(plan(q(200, "a"), q(500, "b")), kid, store, cramped)
        times = sorted(x.t_sec for x in out.questions)
        gap = rules.min_gap_s("7_8")
        assert all(b - a >= gap for a, b in pairwise(times)), times
