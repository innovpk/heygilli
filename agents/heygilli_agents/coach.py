"""Break-message suggestions, written for the parent to approve.

PROTOCOL.md "Time limits and break periods". A parent decides what a child
should do when watching pauses, because a parent knows the house, the hour and
the child; a model does not. So the model's only job here is to help with the
blank page: it proposes a few short lines, drawn from what this child actually
watches, and the parent edits, keeps or discards them in the parent app.

Nothing in this module can reach a child. A suggestion becomes something Gilli
says only after the parent saves it. That is why there is no model call
anywhere in the child-facing break path.
"""

from __future__ import annotations

import logging
from collections.abc import Sequence

from strands import Agent

from . import breaks
from .llm import make_agent, structured
from .schemas import AgeBand, BreakMessage, Kid, SuggestedMessages

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


def coach_agent(model=None) -> Agent:
    return make_agent("coach", SUGGEST_SYSTEM_PROMPT, model=model)


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
