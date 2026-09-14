"""What a child has already shown you they know.

A plan is cached per (video, band, language) and shared by every household,
which is what keeps the Planner's bill following unique videos rather than
sessions. It also means the second time a child watches a video they meet
exactly the questions they met the first time — including the ones they got
right. Asking those again teaches nothing, tells the parent nothing, and to a
nine-year-old reads as not having been heard.

So the sharing stays and the *selection* becomes per child, in the same place
and the same shape as `revisit.seed` and `words.seed`: a transform of the
cached plan for one session, never written back to the store.

This is the mirror of `revisit`, and deliberately uses its rules rather than
new ones — concepts come from `analytics.concept_label`, "right" means
`analytics.UNDERSTOOD`, and the window is the same 30 days. What revisit does
with a concept a child got wrong, this does with one they got right.

Two decisions worth stating, because both could reasonably have gone the other
way:

**Questions are replaced, never removed.** An `Answer` stores the index it was
given, and `analytics` and `revisit` both read `plan.questions[answer_index]`
out of the *stored* plan afterwards. Drop a question from one session's copy
and every index after it points at the wrong thing — the digest would report
concepts the child was never asked about. Replacing keeps the contract, and
gives the child a question at that moment instead of a gap.

**Band 4_6 is left alone**, for the reason revisit gives for skipping it: a
pre-reader's plan has no concepts, and repetition there is the method rather
than a failure of it. A four-year-old who said "giraffe" last week is exactly
who should be asked again — the digest counts words said against words heard,
and a word only moves between those lists by being said more than once.
"""

from __future__ import annotations

import logging
from datetime import date

from . import analytics, question_bank
from .schemas import AgeBand, Kid, QuestionPlan, Video
from .store import Store

log = logging.getLogger(__name__)

#: The same window revisit uses. A concept known a month ago is worth asking
#: about again; one known on Tuesday is not.
WINDOW_DAYS = 30


def known_concepts(
    kid: Kid, store: Store, days: int = WINDOW_DAYS, today: date | None = None
) -> set[str]:
    """Concept keys this child has answered correctly, lowercased."""
    concepts, _ = known_questions_and_concepts(kid, store, days, today)
    return concepts


def known_questions_and_concepts(
    kid: Kid, store: Store, days: int = WINDOW_DAYS, today: date | None = None
) -> tuple[set[str], set[str]]:
    """Concept keys and question texts this child has answered correctly."""
    sessions, answers, plans, videos, _ = analytics.load_window(kid, days, store, today)
    by_session = {s.id: s for s in sessions}
    concepts: set[str] = set()
    texts: set[str] = set()
    for a in answers:
        if a.result not in analytics.UNDERSTOOD:
            continue
        session = by_session.get(a.session_id)
        if session is None:
            continue
        plan = plans.get(
            QuestionPlan.key(session.video_id, session.age_band, session.language)
        )
        if plan is None or not (0 <= a.question_idx < len(plan.questions)):
            continue
        q = plan.questions[a.question_idx]
        if q.text:
            texts.add(q.text.strip().lower())
        video = videos.get(session.video_id)
        label = analytics.concept_label(
            q, video.title if video else ""
        )
        if label:
            concepts.add(label.lower())
    return concepts, texts


def swap_known(
    plan: QuestionPlan,
    kid: Kid,
    store: Store,
    video: Video,
    days: int = WINDOW_DAYS,
    today: date | None = None,
) -> QuestionPlan:
    """This session's plan, with what the child already knows swapped out.

    Returns the plan unchanged when there is nothing to do, which is the common
    case: a first viewing has no history to read.
    """
    if not plan.questions:
        return plan

    band: AgeBand = kid.age_band or "7_8"
    concepts, texts = known_questions_and_concepts(kid, store, days, today)
    if not concepts and not texts:
        return plan

    title = video.title if video else ""
    stale = []
    for i, q in enumerate(plan.questions):
        label = analytics.concept_label(q, title).lower()
        text = q.text.strip().lower()
        if (label and label in concepts) or (text and text in texts):
            stale.append(i)

    if not stale:
        return plan

    # Prompts this plan is not already using, so a swap cannot hand a child the
    # same question under a different index or a question they already got right.
    in_plan = {q.text.strip().lower() for q in plan.questions}
    spares = [
        p
        for p in question_bank.pick_many(
            band, video.id, len(stale) + len(plan.questions) + 10, kid.disabled_prompts
        )
        if p.text.get(plan.language, p.text["en"]).strip().lower() not in in_plan
        and p.text.get(plan.language, p.text["en"]).strip().lower() not in texts
    ]

    questions = list(plan.questions)
    swapped = 0
    for i in stale:
        if not spares:
            break
        prompt = spares.pop(0)
        questions[i] = question_bank.as_question(
            prompt, questions[i].t_sec, plan.language
        )
        swapped += 1

    if not swapped:
        return plan
    log.info(
        "swapped %d already-known question(s) for kid %s on video %s",
        swapped,
        kid.id,
        video.id,
    )
    return plan.model_copy(update={"questions": questions})
