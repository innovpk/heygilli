"""What the Coach proposes to a parent: break messages, and policy questions.

PROTOCOL.md "Time limits and break periods" and "Household policy". Both halves
of this module write FOR THE PARENT. A parent decides what a child should do
when watching pauses, and a parent decides what this family is comfortable
watching, because a parent knows the house, the hour and the child; a model does
not. The model's only job here is to help with the blank page.

Nothing in this module can reach a child. A break line becomes something Gilli
says only after the parent saves it, and a policy question is never shown to
anyone but the parent. That is why there is no model call anywhere in the
child-facing break path.
"""

from __future__ import annotations

import hashlib
import logging
from collections.abc import Sequence

from strands import Agent

from . import breaks
from .llm import make_agent, structured
from .schemas import (
    AgeBand,
    BreakMessage,
    Kid,
    PolicyQuestion,
    SuggestedMessages,
    SuggestedPolicyQuestions,
)

log = logging.getLogger(__name__)

MAX_TITLES = 6  # a handful of titles is plenty; the prompt stays small and cheap
WANTED = 4  # how many lines the parent gets to choose from

SUGGEST_SYSTEM_PROMPT = """You help a parent decide what their child should do when the screen
pauses for a break. You are writing FOR THE PARENT to approve, not for the child to obey.

Write short lines a parent could have their buddy character say out loud. Draw on what the child
has been watching so the break feels connected to their day, not like a punishment for watching.

Rules:
- One sentence each. Plain, warm, and specific.
- Something a child can do indoors at home, on their own, in a few minutes.
- Never anything needing equipment to fetch, water, stairs, a kitchen, going outside, climbing, or
  standing on furniture. A parent may add such things themselves; you may not propose them.
- Never scold, never mention screen time, never imply the child has done something wrong.
- For age band 4_6 write one simple spoken instruction a child who cannot read would follow.
- These are suggestions a parent will edit. Ordinary and useful beats clever."""


POLICY_SYSTEM_PROMPT = """You help a parent set up what their family is comfortable with their
child watching. You are given the channels this child is already subscribed to and some titles
they have watched. From those, write the questions worth asking THIS parent.

A household with forty gaming channels should be asked about gaming, not about make-up tutorials.
Ask about what is actually in front of this child.

Rules:
- One question each, answerable with "fine", "sometimes" or "rather not". Never open-ended.
- Ask about a kind of content, never about a specific channel being good or bad, and never about
  the child ("is your child sensitive?"). The parent is describing their household, not defending it.
- `why` names the channels or titles that prompted the question, in a few plain words, so the parent
  can see it was drawn from their own list rather than guessed.
- Neutral wording. Both answers must sound equally reasonable; nothing that implies a right answer
  or that a parent has been careless.
- No question about religion, politics, money, health or family circumstances.
- Ordinary and specific beats clever. "Are unboxing videos all right?" is a good question."""

WANTED_QUESTIONS = 5  # a parent will answer five; they will not answer twenty
MIN_CHANNELS = 2  # below this there is nothing household-specific to draw on
MAX_CHANNELS_IN_PROMPT = 30
MAX_QUESTION_CHARS = 160


def coach_agent(model=None) -> Agent:
    return make_agent("coach", SUGGEST_SYSTEM_PROMPT, model=model)


def policy_agent(model=None) -> Agent:
    return make_agent("coach", POLICY_SYSTEM_PROMPT, model=model)


def suggest_prompt(band: AgeBand, nickname: str, titles: Sequence[str]) -> str:
    watched = "\n".join(f"- {t}" for t in list(titles)[:MAX_TITLES]) or "- (nothing recent)"
    return (
        f"Child's nickname: {nickname}\n"
        f"Age band: {band}\n"
        f"Recently watched:\n{watched}\n\n"
        f"Write {WANTED} short lines the parent could have Gilli say when watching pauses."
    )


def suggest_messages(
    kid: Kid,
    titles: Sequence[str] = (),
    agent: Agent | None = None,
) -> tuple[list[BreakMessage], list[str]]:
    """`(suggestions, rejections)` for the parent's screen.

    Suggestions still pass the safety gate, so a parent is never handed
    something careless to approve in a single tap. A provider failure returns
    the built-ins rather than an empty screen.
    """
    band: AgeBand = kid.age_band or "7_8"
    try:
        agent = agent or coach_agent()
        drafts = structured(
            agent, suggest_prompt(band, kid.nickname, titles), SuggestedMessages
        ).messages
    except Exception as e:  # noqa: BLE001 - a provider error must not empty the parent's screen
        log.warning("break-message suggestions failed for %s: %s", kid.id, e)
        return builtin_suggestions(band), [f"generation failed: {type(e).__name__}"]

    kept: list[BreakMessage] = []
    rejections: list[str] = []
    for draft in drafts:
        # A pre-reader needs a line Gilli can say, but a draft that only filled
        # in `text` is a formatting slip, not a safety problem: use the text.
        # Rejecting these threw away every personalised line for band 4_6.
        if not draft.spoken.strip():
            draft = draft.model_copy(update={"spoken": draft.text})
        reason = breaks.validate_message(draft, band)
        if reason is None:
            kept.append(draft)
        else:
            rejections.append(f"{draft.text!r}: {reason}")
            log.info("suggestion rejected for %s: %s", kid.id, reason)

    # Never hand back an empty screen: top up from the built-ins.
    for extra in builtin_suggestions(band):
        if len(kept) >= WANTED:
            break
        if all(extra.text != k.text for k in kept):
            kept.append(extra)
    return kept[:WANTED], rejections


def builtin_suggestions(band: AgeBand) -> list[BreakMessage]:
    """Plain starting points, so a parent facing an empty box has something to
    edit rather than a blank page. Deliberately dull and safe."""
    if band == "4_6":
        lines = [
            ("Go and find a grown-up for a cuddle.", "Break time! Go and find a grown-up for a cuddle."),
            ("Tidy away five toys.", "Break time! Can you tidy away five toys?"),
            ("Show someone your favourite toy.", "Break time! Go and show someone your favourite toy."),
            ("Have a stretch, as tall as you can.", "Break time! Have a big stretch, as tall as you can."),
        ]
    else:
        lines = [
            ("Stretch your legs for a few minutes.", "Break time. Stretch your legs for a few minutes."),
            ("Tidy one thing in your room.", "Break time. Go and tidy one thing in your room."),
            ("Go and tell someone what you just watched.",
             "Break time. Go and tell someone what you just watched."),
            ("Read a page of a book.", "Break time. Go and read a page of a book."),
        ]
    return [BreakMessage(text=t, spoken=s) for t, s in lines]


# --- household policy questions (PROTOCOL.md "Household policy") ---------------


def question_id(question: str) -> str:
    """A stable id for a question, derived from its own text.

    The id is what an answer is filed under, so it must survive the question
    being asked again next month: deriving it from the text means a re-ask lands
    on the answer the parent already gave instead of asking twice.
    """
    key = " ".join(question.lower().split()).strip(" ?.!")
    return f"pq_{hashlib.sha1(key.encode()).hexdigest()[:10]}"


def policy_prompt(nickname: str, band: AgeBand, channels: Sequence[str], titles: Sequence[str]) -> str:
    watched = "\n".join(f"- {t}" for t in list(titles)[:MAX_TITLES]) or "- (nothing recent)"
    subscribed = "\n".join(f"- {c}" for c in list(channels)[:MAX_CHANNELS_IN_PROMPT])
    return (
        f"Child's nickname: {nickname}\n"
        f"Age band: {band}\n"
        f"Channels this child is subscribed to ({len(channels)}):\n{subscribed}\n"
        f"Recently watched:\n{watched}\n\n"
        f"Return at most {WANTED_QUESTIONS} questions worth asking this parent."
    )


def suggest_policy_questions(
    kid: Kid,
    channels: Sequence[str] = (),
    titles: Sequence[str] = (),
    agent: Agent | None = None,
) -> list[PolicyQuestion]:
    """Questions for the parent's policy screen. Parent-facing only.

    Two things are decided in code rather than in the prompt, for the same
    reason the Reviewer decides them in code: with too few channels there is
    nothing household-specific to draw on, so the model is not called at all and
    cannot invent a household; and when it is called but returns nothing usable,
    the parent gets the built-ins rather than an empty screen.
    """
    channels = [c.strip() for c in channels if c.strip()]
    if len(channels) < MIN_CHANNELS:
        return builtin_policy_questions()

    try:
        agent = agent or policy_agent()
        drafts = structured(
            agent,
            policy_prompt(kid.nickname, kid.age_band or "7_8", channels, titles),
            SuggestedPolicyQuestions,
        ).questions
    except Exception as e:  # noqa: BLE001 - a provider error must not empty the parent's screen
        log.warning("policy questions failed for %s: %s", kid.id, e)
        return builtin_policy_questions()

    kept: list[PolicyQuestion] = []
    seen: set[str] = set()
    for draft in drafts:
        text = " ".join(draft.question.split())
        if not text or len(text) > MAX_QUESTION_CHARS:
            continue  # an essay is not a question a parent will answer
        qid = question_id(text)
        if qid in seen:
            continue
        seen.add(qid)
        kept.append(PolicyQuestion(id=qid, question=text, why=" ".join(draft.why.split())))
        if len(kept) >= WANTED_QUESTIONS:
            break
    return kept or builtin_policy_questions()


def builtin_policy_questions() -> list[PolicyQuestion]:
    """The questions worth asking any household, used when there is not enough
    to go on. Their `why` says plainly that they were not drawn from this
    family's own channels, because claiming otherwise would be a lie the parent
    could not check."""
    generic = "Asked of every family: this is one of the commonest things a child's feed fills with."
    pairs = [
        ("Are unboxing and toy-haul videos all right?", generic),
        ("Are challenge and prank videos all right?", generic),
        ("Is cartoon peril — chases, monsters, mild scares — all right?", generic),
        ("Are videos that push merchandise or a sponsor all right?", generic),
        ("Is rude humour — toilet jokes, name-calling — all right?", generic),
    ]
    return [PolicyQuestion(id=question_id(q), question=q, why=why) for q, why in pairs]
