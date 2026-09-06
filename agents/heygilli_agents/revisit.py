"""Revisiting a shaky concept (PROTOCOL.md "Revisiting a shaky concept").

Analytics already knows which concepts a child was shaky on. Acting on it is one
question: a later video's session may carry one question about an earlier idea,
asked as a fresh question about the video the child is watching now.

The failure mode is a child noticing they are being retested, so every rule that
protects against it is enforced here in code rather than asked for in a prompt:

- **At most one per session, and never the first question.** The revisit
  replaces a question that is already in the plan, at an index past the first,
  so both are properties of how it is placed rather than promises.
- **Never two sessions in a row about the same concept**, and never a third time
  ever: the concept last asked about is excluded, and a concept asked twice
  leaves the list for good.
- **Nothing in the question refers to the past.** The model is told, and then
  the text is checked: a question that mentions last time, or remembering, or
  getting something wrong, is dropped. The session simply has no revisit, which
  is a much smaller loss than a child being reminded they failed.
- **A concept the child has since got right twice leaves the list**, counted
  only from answers given after the last shaky one.

Plans are cached globally per (video, band, language), shared by every
household. A revisit belongs to one child, so it is never written into that
cached plan: `seed` returns a copy for this session only.

There is no deterministic fallback question here on purpose. A revisit has to be
answerable from the video the child just watched, and no canned sentence can be.
When the model is unavailable or writes something unusable, the session runs
without a revisit and nothing about it is worse.
"""
from __future__ import annotations

import logging
import re
from datetime import date

from strands import Agent

from . import analytics
from .llm import make_agent, structured
from .planner import SAFETY_RULES
from .schemas import (
    Kid,
    Question,
    QuestionPlan,
    RevisitConcept,
    RevisitDraft,
    RevisitRecord,
    RevisitTag,
    Video,
    now_iso,
)
from .store import Store

log = logging.getLogger(__name__)

MAX_ASKED_AGAIN = 2  # PROTOCOL.md: nothing is ever asked a third time
CORRECT_TO_CLEAR = 2  # a concept the child gets right twice leaves the list
WINDOW_DAYS = 30  # how far back a shaky concept stays worth revisiting
MAX_QUESTION_CHARS = 200
OTHER_QUESTIONS_IN_PROMPT = 4

# Anything that would tell a child this is a second attempt. A question carrying
# one of these is thrown away rather than repaired: a near miss here is exactly
# the thing the feature exists to avoid.
_PAST_REFERENCES = (
    "remember when", "remember how", "last time", "the other day", "last week", "earlier",
    "before", "again", "previously", "we talked", "you said", "you told me", "got it wrong",
    "you didn't", "you couldn't", "did not know", "struggled", "one more time", "try that",
)
_PAST = re.compile(r"(?<![a-z])(" + "|".join(re.escape(p) for p in _PAST_REFERENCES) + r")(?![a-z])",
                   re.IGNORECASE)


def refers_to_the_past(text: str) -> str | None:
    """The phrase that gives the game away, or None. `text` is what a child hears."""
    m = _PAST.search(text)
    return m.group(1).lower() if m else None


# --- which concepts are worth asking about again ------------------------------


def _records(kid: Kid, store: Store) -> dict[str, RevisitRecord]:
    return {r.concept.lower(): r for r in store.list_revisits(kid.household_id, kid.id)}


def candidates(
    kid: Kid, store: Store, days: int = WINDOW_DAYS, today: date | None = None
) -> list[RevisitConcept]:
    """The concepts still worth another look, most shaky first.

    Built from the same records analytics reads, but with one difference that
    matters: a concept only clears once the child has got it right *since* the
    last time they were shaky on it. Counting corrects from the whole window
    would clear a concept on the strength of an answer given before it went
    shaky.
    """
    if (kid.age_band or "7_8") == "4_6":
        return []  # a pre-reader's plan has no concepts; vocabulary is the 4_6 story
    sessions, answers, plans, videos, _ = analytics.load_window(kid, days, store, today)
    by_session = {s.id: [] for s in sessions}
    for a in answers:
        if a.session_id in by_session:
            by_session[a.session_id].append(a)

    seen: dict[str, list[tuple[tuple[str, str], str, str]]] = {}
    display: dict[str, str] = {}
    for s in sorted(sessions, key=lambda s: (s.date, s.started_at)):
        plan = plans.get(QuestionPlan.key(s.video_id, s.age_band, s.language))
        video = videos.get(s.video_id)
        for a in sorted(by_session[s.id], key=lambda a: (a.created_at, a.question_idx)):
            if plan is None or not (0 <= a.question_idx < len(plan.questions)):
                continue
            label = analytics.concept_label(plan.questions[a.question_idx], video.title if video else "")
            key = label.lower()
            display.setdefault(key, label)
            seen.setdefault(key, []).append(((s.date, a.created_at), a.result, s.date))

    records = _records(kid, store)
    out: list[RevisitConcept] = []
    for key, entries in seen.items():
        shaky = [e for e in entries if e[1] in analytics.SHAKY]
        if len({e[2] for e in shaky}) < analytics.SHAKY_DAYS_FOR_REVIEW:
            continue  # one bad day is noise, two is a pattern (same rule as analytics)
        last_shaky = max(e[0] for e in shaky)
        got_right_since = sum(
            1 for e in entries if e[1] in analytics.UNDERSTOOD and e[0] > last_shaky
        )
        if got_right_since >= CORRECT_TO_CLEAR:
            continue
        asked_again = records[key].asked_again if key in records else 0
        if asked_again >= MAX_ASKED_AGAIN:
            continue
        out.append(RevisitConcept(
            concept=display[key],
            times_shaky=len(shaky),
            last_seen=max(e[2] for e in entries),
            asked_again=asked_again,
        ))
    return sorted(out, key=lambda c: (-c.times_shaky, c.concept))


def last_asked(kid: Kid, store: Store) -> RevisitRecord | None:
    """The concept the previous session revisited, if any."""
    records = [r for r in store.list_revisits(kid.household_id, kid.id) if r.last_asked_at]
    return max(records, key=lambda r: r.last_asked_at) if records else None


def pick(kid: Kid, store: Store, session_id: str = "") -> RevisitConcept | None:
    """The one concept this session may revisit, or None.

    The concept the last session asked about is skipped: two sessions running on
    the same idea is the pattern a child notices.
    """
    options = candidates(kid, store)
    if not options:
        return None
    previous = last_asked(kid, store)
    if previous is not None and previous.last_session_id != session_id:
        options = [c for c in options if c.concept.lower() != previous.concept.lower()]
    return options[0] if options else None


# --- writing the question -----------------------------------------------------

REVISIT_SYSTEM_PROMPT = f"""You write ONE question for a co-watching buddy to ask a child about the
video they are watching right now. The question should happen to be about an idea the child met in
an earlier video and did not quite have.

The child must not be able to tell this is a second attempt. That is the whole job.

Rules:
- Ask about THIS video. The question must be answerable from what this child has just watched.
- Never refer to the past in any way: no "remember", no "last time", no "again", no "before", no
  mention of another video, and nothing about how they answered anything.
- If this video gives you no honest way to ask about the idea, return an EMPTY text. That is a
  correct answer and a good one; forcing the idea into an unrelated video is not.
- One sentence, in the same language as the other questions.

{SAFETY_RULES}
""".strip()


def revisit_agent(model=None) -> Agent:
    return make_agent("planner", REVISIT_SYSTEM_PROMPT, model=model)


def revisit_prompt(concept: str, video: Video, plan: QuestionPlan) -> str:
    others = "\n".join(
        f"- {q.text} (expected: {q.expected})" for q in plan.questions[:OTHER_QUESTIONS_IN_PROMPT]
    ) or "- (none)"
    return (
        f"age_band: {plan.age_band}\nlanguage: {plan.language}\n"
        f"video the child is watching now: {video.title or video.id}\n"
        f"questions already planned for this video:\n{others}\n\n"
        f"idea to come back to: {concept}\n\n"
        f"Return the RevisitDraft."
    )


def build_question(
    concept: str, replacing: Question, video: Video, plan: QuestionPlan,
    last_seen: str = "", agent: Agent | None = None,
) -> Question | None:
    """One revisit question in the shape of the question it replaces, or None.

    None is a perfectly good outcome and every failure ends here: the model was
    unavailable, or it said this video cannot carry the idea, or what it wrote
    would have told the child they were being retested.
    """
    try:
        draft = structured(agent or revisit_agent(), revisit_prompt(concept, video, plan), RevisitDraft)
    except Exception as e:  # noqa: BLE001 - a session without a revisit is a fine session
        log.warning("revisit question failed for %r: %s", concept, e)
        return None

    text = " ".join(draft.text.split())
    if not text:
        log.info("no honest way to revisit %r in %s", concept, video.id)
        return None
    if len(text) > MAX_QUESTION_CHARS:
        return None
    if (phrase := refers_to_the_past(text)) is not None:
        log.info("revisit question for %r dropped: it says %r", concept, phrase)
        return None

    return replacing.model_copy(update={
        "text": text,
        "expected": " ".join(draft.expected.split()) or replacing.expected,
        "variants": draft.variants,
        "followup": " ".join(draft.followup.split()),
        "model_line": "",
        "options": [],
        "input": "voice",
        "revisit": RevisitTag(concept=concept, last_seen=last_seen),
    })


def seed(
    plan: QuestionPlan, kid: Kid, store: Store, video: Video | None = None,
    session_id: str = "", agent: Agent | None = None,
) -> QuestionPlan:
    """A copy of this plan with at most one revisit in it, for this session only.

    The cached plan is shared by every household, so it is never touched: what
    comes back is a copy, and when there is nothing to revisit it is the plan
    itself, unchanged.
    """
    if len(plan.questions) < 2:
        return plan  # the only question there is would be the first one
    concept = pick(kid, store, session_id)
    if concept is None:
        return plan
    video = video or store.get_video(plan.video_id) or Video(id=plan.video_id)
    replacing = plan.questions[-1]  # anything but the first
    question = build_question(concept.concept, replacing, video, plan, concept.last_seen, agent)
    if question is None:
        return plan
    questions = [*plan.questions[:-1], question]
    log.info("session %s revisits %r for kid %s", session_id or "?", concept.concept, kid.id)
    return plan.model_copy(update={"questions": questions})


def record_asked(kid: Kid, store: Store, tag: RevisitTag, session_id: str) -> RevisitRecord:
    """Count a revisit that actually went out to the child.

    Recorded at the moment it is asked, not when it is planned: a session the
    child left before reaching the question did not use up one of the two
    chances that concept gets.
    """
    key = tag.concept.lower()
    existing = _records(kid, store).get(key)
    record = RevisitRecord(
        kid_id=kid.id,
        concept=tag.concept,
        asked_again=(existing.asked_again if existing else 0) + 1,
        last_asked_at=now_iso(),
        last_session_id=session_id,
    )
    store.put_revisit(kid.household_id, record)
    return record
