"""Channel drift: a channel is not what it was (PROTOCOL.md).

A review is a snapshot, and `reviewed_at` is on every one of them for this
reason. Channels change hands, chase trends, and start running gambling ads two
years after a parent approved them.

What is decided in code rather than by a model:

- **Whether anything got worse.** `worse` is a comparison of two reviews: the
  verdict moved toward concern, or a flag appeared that was not there before.
  A model is asked only to describe a difference that has already been
  established, so a drift can never be talked into existence.
- **That `unknown` is not drift.** A channel whose feed could not be read today
  tells us nothing about whether it changed, and the parent keeps the review
  they had. An unreachable channel interrupting a parent would train them to
  ignore the inbox.
- **Once a week per channel, at most.** The rate limit is its own record, so it
  holds whether or not the re-review produced anything usable.

And the rule the whole feature turns on: a drift raises an inbox entry and stops
there. **HeyGilli never removes a channel by itself** — removal is a `DELETE`
the parent makes.
"""
from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

from strands import Agent

from .llm import make_agent, structured
from .schemas import (
    ChannelDrift,
    ChannelReview,
    ChannelSnapshot,
    DriftNote,
    ReviewFlag,
    now_iso,
    parse_iso,
)
from .store import Store

log = logging.getLogger(__name__)

RECHECK_DAYS = 7  # PROTOCOL.md: at most once a week per channel
CHECK_NAMESPACE = "drift_check"  # when a channel was last re-read, whatever came of it
MAX_TITLES_IN_NOTE = 8
MAX_NOTE_CHARS = 240

# How bad a verdict is. `unknown` is deliberately absent: it is not a point on
# this scale, it is the absence of an answer.
_SEVERITY = {"good": 0, "mixed": 1, "concern": 2}


def snapshot(review: ChannelReview) -> ChannelSnapshot:
    return ChannelSnapshot(verdict=review.verdict, flags=review.flags, reviewed_at=review.reviewed_at)


def last_checked(review: ChannelReview | None, store: Store) -> str | None:
    """When this channel was last re-read, from its own record or the review.

    Kept separately from `reviewed_at` so that a re-read which came back
    `unknown` — and therefore left the old review in place — still counts
    against the weekly limit instead of being retried on every poll.
    """
    if review is None:
        return None
    record = store.cache_get(CHECK_NAMESPACE, review.channel_id) or {}
    return record.get("checked_at") or review.reviewed_at


def due_for_recheck(review: ChannelReview | None, store: Store, now: datetime | None = None) -> bool:
    """A channel with no review at all is not due: there is nothing to drift from."""
    if review is None:
        return False
    when = parse_iso(last_checked(review, store))
    if when is None:
        return True  # a review with no readable date is as good as never checked
    return (now or datetime.now(UTC)) - when >= timedelta(days=RECHECK_DAYS)


def mark_checked(channel_id: str, store: Store) -> None:
    store.cache_put(CHECK_NAMESPACE, channel_id, {"checked_at": now_iso()})


def _new_flags(was: ChannelSnapshot, now: ChannelSnapshot) -> list[ReviewFlag]:
    before = {f.kind for f in was.flags}
    return [f for f in now.flags if f.kind not in before]


def got_worse(was: ChannelSnapshot, now: ChannelSnapshot) -> bool:
    """The verdict moved toward concern, or a new flag appeared.

    Either side being `unknown` means there is nothing to compare, so it is
    never worse: a channel that could not be read is a gap in what we know, not
    a change in what it publishes.
    """
    if was.verdict == "unknown" or now.verdict == "unknown":
        return False
    if _SEVERITY[now.verdict] > _SEVERITY[was.verdict]:
        return True
    return bool(_new_flags(was, now))


def describe_change(was: ChannelSnapshot, now: ChannelSnapshot) -> str:
    """The difference, written from the diff alone. No model.

    This is what a parent reads when the model is unavailable, and it is the
    floor the model's sentence has to beat: it names the change and claims
    nothing else.
    """
    parts: list[str] = []
    if was.verdict != now.verdict:
        parts.append(f"The verdict moved from {was.verdict} to {now.verdict}.")
    added = _new_flags(was, now)
    if added:
        named = ", ".join(f.kind.replace("_", " ") for f in added)
        parts.append(f"Newly flagged for {named}.")
    if not parts:
        parts.append("The recent uploads have changed since this channel was reviewed.")
    return " ".join(parts)


def compare(was: ChannelReview, now: ChannelReview) -> ChannelDrift:
    """Two reviews of one channel -> the drift between them. Pure and offline.

    `sample_titles` is the uploads that are new since the old review, because
    those are what actually changed the answer; when nothing is new (the verdict
    moved on the same evidence) it falls back to what the new review read, so
    the parent is never shown an empty list of evidence.
    """
    was_snap, now_snap = snapshot(was), snapshot(now)
    seen = set(was.sample_titles)
    fresh = [t for t in now.sample_titles if t not in seen]
    return ChannelDrift(
        channel_id=now.channel_id,
        title=now.title or was.title,
        was=was_snap,
        now=now_snap,
        worse=got_worse(was_snap, now_snap),
        what_changed=describe_change(was_snap, now_snap),
        sample_titles=(fresh or now.sample_titles)[:MAX_TITLES_IN_NOTE],
    )


# --- the sentence (one model call, only for drifts a parent will see) ---------

DRIFT_SYSTEM_PROMPT = """You are told how one YouTube channel's review changed between two dates,
and the recent upload titles that changed it. Write ONE sentence naming the difference.

Rules:
- Name the difference, do not restate the review. "It has started running betting sponsorships" is
  a difference; "this channel posts gaming videos with sponsorships" is a description.
- Only what the two reviews and the titles actually say. Never guess a cause, never speculate about
  the creator's motives, never say a channel was "taken over" or "sold" unless you were told so.
- Plain and calm. A parent is deciding whether to look, not being warned of danger.
- One sentence. No preamble.""".strip()


def drift_agent(model=None) -> Agent:
    return make_agent("reviewer", DRIFT_SYSTEM_PROMPT, model=model)


def note_prompt(drift: ChannelDrift) -> str:
    def flags(snap: ChannelSnapshot) -> str:
        return ", ".join(f"{f.kind}: {f.note}" for f in snap.flags) or "none"

    titles = "\n".join(f"- {t}" for t in drift.sample_titles) or "- (no new titles)"
    return (
        f"channel: {drift.title or drift.channel_id}\n"
        f"was ({drift.was.reviewed_at}): verdict {drift.was.verdict}; flags {flags(drift.was)}\n"
        f"now ({drift.now.reviewed_at}): verdict {drift.now.verdict}; flags {flags(drift.now)}\n"
        f"uploads since the old review:\n{titles}\n\n"
        f"Return the DriftNote."
    )


def write_note(drift: ChannelDrift, agent: Agent | None = None) -> str:
    """The model's sentence, or the one built from the diff.

    The deterministic sentence is already in `drift.what_changed` by the time
    this is called, so every failure path here simply leaves it standing.
    """
    try:
        text = structured(agent or drift_agent(), note_prompt(drift), DriftNote).what_changed
    except Exception as e:  # noqa: BLE001 - any provider error: the diff already said enough
        log.warning("drift note failed for %s: %s", drift.channel_id, e)
        return drift.what_changed
    text = " ".join(text.split())
    if not text or len(text) > MAX_NOTE_CHARS:
        return drift.what_changed
    return text
