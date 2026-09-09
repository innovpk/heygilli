"""Questions a parent wrote themselves (SPEC 7.6).

The Planner is good at "what happened in this video". A parent is the only one
who knows that this child has been asking about volcanoes all week, or that
the grandmother they are about to see on screen is the one they call Nani. So
the parent may add their own question to a video, in their own words, and it
is asked exactly as written.

Two rules hold here rather than anywhere else, and both are the reason this is
a module and not a branch inside the planner:

- **A parent's question is never dropped.** `rules.select` chooses among the
  model's candidates and trims to a target; running a parent's question
  through that would let a mixing heuristic silently discard the one question
  in the plan somebody actually asked for. So these are merged *after*
  selection, and the plan grows to fit them.
- **It is still spaced.** Never in the first stretch of the video, and never
  on top of another question — a child asked two things in twenty seconds
  stops answering either. Where the parent named a second, it is honoured and
  the plan's own question moves aside; where they did not, it goes in the
  largest gap the video has left.

Never written into the cached plan: plans are shared by every household and
this belongs to one child in one home, so `seed` returns a copy for the
session, exactly as a revisit does.
"""
from __future__ import annotations

import logging
from itertools import pairwise

from . import rules
from .schemas import (
    AgeBand,
    Kid,
    Option,
    ParentQuestion,
    Question,
    QuestionPlan,
    Video,
)
from .store import Store

log = logging.getLogger(__name__)

#: How many a parent may have on one video. Not a storage limit — a limit on
#: how much of one video can be interruption. Past this the video stops being
#: something the child is watching and becomes a worksheet.
MAX_PER_VIDEO = 3


def as_question(pq: ParentQuestion, band: AgeBand, t_sec: int, language: str) -> Question:
    """One stored parent question, scheduled at a second of this video.

    Typed `pick_it` rather than `yes_no` when the parent asked for yes/no,
    because `rules.build_yes_no` derives the correct answer from `expected`
    and a parent's question has no correct answer — "did you like the ending?"
    is not something a child can be wrong about. Nothing is marked correct, so
    `score_pick` accepts whichever card they tap.
    """
    if pq.yes_no:
        yes, no = rules.YES_NO_LABELS.get(language, rules.YES_NO_LABELS["en"])
        return Question(
            t_sec=t_sec,
            type="pick_it",
            input="pick",
            text=pq.text,
            gesture="think",
            options=[
                Option(icon_id=rules.YES_ID, label=yes),
                Option(icon_id=rules.NO_ID, label=no),
            ],
        )
    return Question(
        t_sec=t_sec,
        type="recall" if band != "4_6" else "name_it",
        input="voice",
        text=pq.text,
        gesture="think",
    )


def place(taken: list[int], duration_s: int, band: AgeBand, wanted: int | None) -> int | None:
    """A second to ask at: the parent's if they named one, else the roomiest gap.

    None when the video has nowhere legal left — a two-minute video with a
    question already in it cannot take another without breaking the spacing
    that stops a child being interrogated.
    """
    gap = rules.min_gap_s(band)
    first = rules.TIMING[band].first_question_s
    last = (duration_s - rules.END_MARGIN_S) if duration_s > 0 else first
    if last < first:
        return None

    if wanted is not None:
        at = max(first, min(wanted, last))
        return at

    # The middle of the widest interval that clears every existing question by
    # a full gap. Bounds count as questions so the first-question threshold and
    # the end margin are respected without a special case for either.
    edges = sorted({first - gap, *taken, last + gap})
    best: tuple[int, int] | None = None
    for left, right in pairwise(edges):
        room = right - left
        if room >= 2 * gap:
            mid = (left + right) // 2
            if first <= mid <= last and (best is None or room > best[0]):
                best = (room, mid)
    return None if best is None else best[1]


def seed(
    plan: QuestionPlan, kid: Kid, store: Store, video: Video, language: str | None = None
) -> QuestionPlan:
    """The plan with this child's parent-written questions merged in."""
    try:
        wanted = store.list_parent_questions(kid.household_id, kid.id, video.id)
    except Exception as e:  # noqa: BLE001 - a broken read must not take a session down
        log.warning("could not read parent questions for %s/%s: %s", kid.id, video.id, e)
        return plan
    if not wanted:
        return plan

    band = kid.age_band or "7_8"
    language = language or plan.language
    questions = list(plan.questions)
    for pq in wanted[:MAX_PER_VIDEO]:
        at = place([q.t_sec for q in questions], video.duration_s, band, pq.t_sec)
        if at is None:
            log.info("no room for parent question %s in %s", pq.id, video.id)
            continue
        if pq.t_sec is not None:
            # They named this second, so anything of ours too close to it moves
            # out rather than their question being refused. Only here: when we
            # chose the second ourselves, evicting a planner question to make
            # room for the one we just placed would be the tail wagging the dog
            # — `place` already found a gap, or returned None and we skipped.
            gap = rules.min_gap_s(band)
            questions = [q for q in questions if abs(q.t_sec - at) >= gap]
        questions.append(as_question(pq, band, at, language))
    questions.sort(key=lambda q: q.t_sec)
    return plan.model_copy(update={"questions": questions})
