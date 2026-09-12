"""Digest agent: a kid's day -> one parent-readable Digest (SPEC §6.5, §10).

Counts are computed in code from sessions and answers; the model writes the
words (what was understood, what was shaky, a dinner-table prompt) and decides
whether anything is worth a notification at all.
"""
from __future__ import annotations

import logging

from strands import Agent

from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES
from .schemas import Answer, Digest, DigestNarrative, Kid, Session
from .store import Store
from .tools.notify import notify_parent

log = logging.getLogger(__name__)

DIGEST_SYSTEM_PROMPT = f"""You write the end-of-day note a parent reads about their child's
co-watching sessions with Gilli. You see, per question: the question, the expected answer, the
result (correct | partial | off_topic | unclear | silence) and a <=10-word paraphrase. You never see
the child's actual words and must not invent any.

For ages 7 to 11: list ideas the child clearly understood and ideas that were shaky (as short
phrases a parent can bring up), and write ONE dinner-table conversation starter about the day's
videos. For ages 5 to 6: list the words the child heard Gilli model (from the expected answers),
and make the dinner prompt a simple real-world activity ("find something red in the kitchen").
Warm, specific, two sentences at most per field. Never judge the child; never use "wrong".

Set notify=true ONLY if a parent genuinely needs to hear today: e.g. the child seemed distressed
(many silences AND off-topic answers across every video) or a video's questions were all
unanswered. A normal day is notify=false.

{SAFETY_RULES}
""".strip()


def digest_agent(model=None) -> Agent:
    return make_agent("digest", DIGEST_SYSTEM_PROMPT, model=model)


def _rows(store: Store, household: str, sessions: list[Session]) -> tuple[list[str], list[Answer], set[str]]:
    lines: list[str] = []
    answers: list[Answer] = []
    words_heard: set[str] = set()
    for s in sessions:
        video = store.get_video(s.video_id)
        title = video.title if video else s.video_id
        plan = store.get_plan(s.video_id, s.age_band, s.language)
        lines.append(f"Video: {title}")
        for a in store.list_answers(household, s.id):
            answers.append(a)
            q = plan.questions[a.question_idx] if plan and a.question_idx < len(plan.questions) else None
            qtext, expected = (q.text, q.expected) if q else ("?", "?")
            if q and s.age_band == "4_6" and q.type != "copy_it" and not q.is_opinion:
                words_heard.add(q.expected)
            lines.append(f"  Q: {qtext} | expected: {expected} | result: {a.result} | said: {a.paraphrase}")
    return lines, answers, words_heard


def run_digest(kid: Kid, date: str, store: Store, agent: Agent | None = None) -> Digest:
    household = kid.household_id
    sessions = store.list_sessions(household, kid.id, date)
    kind = "prereader" if kid.age_band == "4_6" else "older"
    lines, answers, words_heard = _rows(store, household, sessions)

    digest = Digest(
        kid_id=kid.id,
        date=date,
        kind=kind,
        videos=len({s.video_id for s in sessions}),
        minutes=round(sum(s.watched_sec for s in sessions) / 60),
        asked=len(answers),
        answered=sum(1 for a in answers if a.result not in ("silence", "unclear")),
        words_said=sorted({a.word_said for a in answers if a.word_said}),
        words_heard=sorted(words_heard),
    )
    if not answers:
        digest.dinner_prompt = ""
        store.put_digest(household, digest)
        return digest

    prompt = (
        f"age_band: {kid.age_band}\nnickname: {kid.nickname}\ndate: {date}\n"
        f"sessions: {len(sessions)}, questions asked: {digest.asked}, answered: {digest.answered}\n\n"
        + "\n".join(lines)
        + "\n\nReturn the DigestNarrative."
    )
    try:
        narrative = structured(
            agent or digest_agent(), prompt, DigestNarrative,
            # What the questions actually used, so a digest cannot claim a
            # child heard a word none of them asked.
            context={"words": sorted(words_heard | set(digest.words_said))},
        )
    except LLMError as e:
        log.warning("digest model failed for %s: %s", kid.id, e)
        narrative = DigestNarrative(dinner_prompt="Ask what they watched today.")

    if kind == "older":
        digest.understood, digest.shaky = narrative.understood, narrative.shaky
    else:
        digest.words_heard = sorted(set(digest.words_heard) | set(narrative.words_heard))
    digest.dinner_prompt = narrative.dinner_prompt
    digest.notify = narrative.notify

    if narrative.notify and sessions:
        video = store.get_video(sessions[-1].video_id)
        if video:
            notify_parent(household, kid.id, video, narrative.notify_reason or "Worth a look today.")
    store.put_digest(household, digest)
    return digest
