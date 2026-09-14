"""Not asking a child what they have already shown you they know."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from heygilli_agents import known
from heygilli_agents.schemas import (
    Answer,
    Kid,
    Question,
    QuestionPlan,
    Session,
    Video,
)
from heygilli_agents.store import LocalStore

HH = "hh_known"
CONCEPT = "Ice melts"
VIDEO = Video(id="vid00000001", channel_id="UCx", title="Why Ice Melts", duration_s=900)


def day(n: int) -> str:
    return (datetime.now(UTC).date() - timedelta(days=n)).isoformat()


def kid(age: int = 8) -> Kid:
    return Kid(id="kid_1", household_id=HH, nickname="Abu", age=age)


def plan_for(video: Video, *expected: str) -> QuestionPlan:
    """One question per concept. `expected` is what the concept label comes from."""
    return QuestionPlan(
        video_id=video.id,
        age_band="7_8",
        language="en",
        questions=[
            Question(
                t_sec=100 + 200 * i,
                type="why",
                input="voice",
                text=f"Question {i}?",
                expected=e,
            )
            for i, e in enumerate(expected)
        ],
    )


def watched(store: LocalStore, k: Kid, date: str, results: list[str]) -> Session:
    s = Session(
        household_id=HH,
        kid_id=k.id,
        video_id=VIDEO.id,
        age_band="7_8",
        language="en",
        watched_sec=600,
        date=date,
        started_at=f"{date}T10:00:00+00:00",
    )
    store.put_session(s)
    for i, result in enumerate(results):
        store.put_answer(
            HH,
            Answer(
                session_id=s.id,
                question_idx=i,
                input_used="voice",
                result=result,
                created_at=f"{date}T10:0{i}:00+00:00",
            ),
        )
    return s


@pytest.fixture
def answered_right(store: LocalStore) -> Kid:
    """A child who got the first concept right a week ago."""
    k = kid()
    store.put_kid(k)
    store.put_video(VIDEO)
    plan = plan_for(VIDEO, CONCEPT, "something else")
    store.put_plan(plan)
    watched(store, k, day(7), ["correct", "partial"])
    return k


class TestWhatCountsAsKnown:
    def test_a_correct_answer_makes_the_concept_known(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        assert CONCEPT.lower() in known.known_concepts(answered_right, store)

    def test_a_partial_does_not(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        # `partial` is SHAKY for revisit, so it must not be UNDERSTOOD here or
        # the two would disagree about the same answer.
        assert "something else" not in known.known_concepts(answered_right, store)

    def test_nothing_is_known_before_anything_is_answered(
        self, store: LocalStore
    ) -> None:
        k = kid()
        store.put_kid(k)
        assert known.known_concepts(k, store) == set()


class TestSwapping:
    def test_a_known_question_is_replaced(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        plan = plan_for(VIDEO, CONCEPT, "something else")
        out = known.swap_known(plan, answered_right, store, VIDEO)
        assert out.questions[0].text != plan.questions[0].text

    def test_the_one_they_got_wrong_is_left_alone(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        plan = plan_for(VIDEO, CONCEPT, "something else")
        out = known.swap_known(plan, answered_right, store, VIDEO)
        assert out.questions[1].text == plan.questions[1].text

    def test_the_count_and_the_timings_are_untouched(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        # An Answer stores the index it was given, and analytics reads
        # plan.questions[idx] out of the stored plan afterwards. Change the
        # length here and every later index points at the wrong concept.
        plan = plan_for(VIDEO, CONCEPT, "something else")
        out = known.swap_known(plan, answered_right, store, VIDEO)
        assert len(out.questions) == len(plan.questions)
        assert [q.t_sec for q in out.questions] == [q.t_sec for q in plan.questions]

    def test_the_stored_plan_is_not_changed(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        # The plan is shared by every household; this is one child's session.
        plan = plan_for(VIDEO, CONCEPT, "something else")
        known.swap_known(plan, answered_right, store, VIDEO)
        stored = store.get_plan(VIDEO.id, "7_8", "en")
        assert stored is not None
        assert stored.questions[0].expected == CONCEPT

    def test_a_first_viewing_is_left_exactly_as_it_was(
        self, store: LocalStore
    ) -> None:
        k = kid()
        store.put_kid(k)
        plan = plan_for(VIDEO, CONCEPT, "something else")
        assert known.swap_known(plan, k, store, VIDEO) is plan

    def test_a_pre_reader_swaps_known(self, store: LocalStore) -> None:
        # A child who already answered correctly gets a different question on rewatch.
        k = Kid(id="kid_2", household_id=HH, nickname="Zara", age=4)
        store.put_kid(k)
        store.put_video(VIDEO)
        plan = plan_for(VIDEO, CONCEPT)
        store.put_plan(plan)
        watched(store, k, day(3), ["correct"])
        swapped = known.swap_known(plan, k, store, VIDEO)
        assert swapped.questions[0].text != plan.questions[0].text

    def test_an_empty_plan_survives(
        self, store: LocalStore, answered_right: Kid
    ) -> None:
        empty = QuestionPlan(
            video_id=VIDEO.id, age_band="7_8", language="en", questions=[]
        )
        assert known.swap_known(empty, answered_right, store, VIDEO) is empty
