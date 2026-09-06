"""Watch history: parsed to counts on the way in, then thrown away.

PROTOCOL.md "Watch history: opt-in, aggregate, discarded". A parent who wants to
know what their child has actually been watching — as opposed to what they
subscribed to years ago — can opt in for one import. The terms are narrow, and
they are enforced here rather than promised in a comment:

- Only `watch-history.html` inside a child profile folder is ever opened, and
  only when the parent ticked the box for that import (`takeout.py`).
- The file is reduced to counts by `parse_watch_history` while it is being read.
  The only thing this module ever extracts from an entry is the **channel** it
  came from and **when** it was watched. There is no code path here that reads a
  video's title or its id: the entry regex matches `/channel/` anchors only, so
  the title sitting a few characters away in the same block is never captured.
- What comes out is a `HistoryAggregate`, which has nowhere to put a title. That
  is what makes "no video title is ever persisted" checkable, and
  `tests/test_history.py` checks it by watching every write the store makes.
- The summary model is given channel names and numbers. It never sees a title
  because none exists by the time it is called.

`unsubscribed_share` is the number the whole feature is for: a child whose
watching is mostly from channels nobody chose is being fed by the recommender,
not by their own subscriptions.
"""
from __future__ import annotations

import html as html_mod
import logging
import re
from collections import defaultdict

from pydantic import BaseModel, Field
from strands import Agent

from .llm import make_agent, structured
from .planner import SAFETY_RULES
from .schemas import (
    HistoryAggregate,
    HistoryChannel,
    HistoryChannelCount,
    HistoryInsight,
    Kid,
    now_iso,
)

log = logging.getLogger(__name__)

TOP_CHANNELS = 20  # PROTOCOL.md: at most 20
MAX_ENTRIES = 200_000  # a decade of heavy watching; a bigger file is truncated, not refused
MAX_CHANNEL_TITLE = 120
CHANNELS_IN_PROMPT = 12

# One Takeout entry is one "outer-cell" div. Splitting on that marker is enough
# structure for counting and needs no HTML parser (and therefore no dependency).
_ENTRY = re.compile(r"outer-cell")
# Deliberately narrow: only the channel anchor. The video's own anchor
# (`watch?v=…`), which is what carries the title, has no expression here that
# could match it.
_CHANNEL = re.compile(
    r'<a[^>]+href="[^"]*youtube\.com/channel/(UC[A-Za-z0-9_-]{22})"[^>]*>([^<]*)</a>',
    re.IGNORECASE,
)
# Takeout separates the time from AM/PM with a narrow no-break space, which
# arrives as a character in some exports and as an HTML entity in others; both
# count as a gap here so a real export's dates are not silently dropped.
_GAP = r"(?:\s|&(?:nbsp|#160|#8239|#x202[fF]);)"
_WHEN = re.compile(
    rf"([A-Z][a-z]{{2}}){_GAP}+(\d{{1,2}}),{_GAP}*(\d{{4}}),?{_GAP}*"
    rf"(\d{{1,2}}):(\d{{2}}):(\d{{2}}){_GAP}*([AP]M)?",
    re.IGNORECASE,
)
_MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), start=1
)}


def _channel_title(raw: str) -> str:
    return html_mod.unescape(" ".join(raw.split()))[:MAX_CHANNEL_TITLE]


def _when(block: str) -> tuple[str, int] | None:
    """`(YYYY-MM-DD, hour)` from an entry, or None when the date is not English.

    Google localises the timestamp, so a non-English export contributes its
    counts without a date rather than a guessed one. Half the truth beats a
    plausible invention on a screen a parent is going to make a decision from.
    """
    m = _WHEN.search(block)
    if m is None:
        return None
    month = _MONTHS.get(m.group(1).lower())
    if month is None:
        return None
    day, year = int(m.group(2)), int(m.group(3))
    hour = int(m.group(4)) % 24
    ampm = (m.group(7) or "").upper()
    if ampm == "PM" and hour < 12:
        hour += 12
    elif ampm == "AM" and hour == 12:
        hour = 0
    if not (1 <= month <= 12 and 1 <= day <= 31):
        return None
    return f"{year:04d}-{month:02d}-{day:02d}", hour


def parse_watch_history(raw: str | bytes, max_entries: int = MAX_ENTRIES) -> HistoryAggregate:
    """One `watch-history.html` -> counts. Nothing else survives this function."""
    text = raw.decode("utf-8", errors="replace") if isinstance(raw, bytes) else raw
    videos = 0
    attributed = 0
    by_hour = [0] * 24
    counts: dict[str, int] = defaultdict(int)
    titles: dict[str, str] = {}
    first: str | None = None
    last: str | None = None

    for block in _ENTRY.split(text)[1:]:  # [0] is the page header, not an entry
        if videos >= max_entries:
            log.warning("watch history truncated at %d entries", max_entries)
            break
        channel = _CHANNEL.search(block)
        when = _when(block)
        if channel is None and when is None:
            continue  # a layout div, not a watched video
        videos += 1
        if channel is not None:
            channel_id = channel.group(1)
            counts[channel_id] += 1
            titles.setdefault(channel_id, _channel_title(channel.group(2)) or channel_id)
            attributed += 1
        if when is not None:
            day, hour = when
            by_hour[hour] += 1
            first = day if first is None else min(first, day)
            last = day if last is None else max(last, day)

    channels = [
        HistoryChannelCount(channel_id=cid, title=titles.get(cid, cid), videos=n)
        for cid, n in sorted(counts.items(), key=lambda kv: (-kv[1], titles.get(kv[0], kv[0])))
    ]
    return HistoryAggregate(
        videos=videos, attributed=attributed, first_watched=first, last_watched=last,
        by_hour=by_hour, channels=channels,
    )


# --- aggregate -> what the parent reads ---------------------------------------


def peak_hours(by_hour: list[int]) -> tuple[int, int] | None:
    """The three-hour stretch most watching falls in, or None when it is flat."""
    total = sum(by_hour)
    if total < 3:
        return None
    # Ties break toward a window that starts on a busy hour, so a quiet hour
    # before the real stretch does not get reported as part of it.
    best = max(range(24), key=lambda h: (sum(by_hour[(h + i) % 24] for i in range(3)), by_hour[h]))
    window = sum(by_hour[(best + i) % 24] for i in range(3))
    if window * 4 < total:  # nothing stands out; do not claim a pattern
        return None
    return best, (best + 3) % 24


def _clock(hour: int) -> str:
    suffix = "am" if hour < 12 else "pm"
    twelve = hour % 12 or 12
    return f"{twelve}{suffix}"


def plain_summary(insight: HistoryInsight) -> str:
    """The summary built from the numbers alone, with no model involved.

    This is what a parent sees when the model is unavailable, and it is also the
    honesty floor for the model's version: it says what the counts show and
    makes no claim about the child.
    """
    if insight.videos == 0:
        return "No watching could be read from that export."
    span = ""
    if insight.first_watched and insight.last_watched:
        span = f" between {insight.first_watched} and {insight.last_watched}"
    lines = [f"{insight.videos:,} videos{span}, from {len(insight.top_channels)} channels or more."]
    share = round(insight.unsubscribed_share * 100)
    if insight.unsubscribed_share:
        lines.append(
            f"{share}% of it came from channels this child does not follow."
        )
    window = peak_hours(insight.by_hour)
    if window:
        lines.append(f"Most of the watching happens between {_clock(window[0])} and {_clock(window[1])}.")
    return " ".join(lines)


def build_insight(
    kid_id: str, agg: HistoryAggregate, subscribed: set[str] | None = None
) -> HistoryInsight:
    """The aggregate plus what this kid actually follows. No model call.

    `unsubscribed_share` is computed over every channel, not just the twenty
    shown: a long tail of channels nobody chose is exactly the thing the number
    is meant to catch.
    """
    subscribed = subscribed or set()
    unsubscribed = sum(c.videos for c in agg.channels if c.channel_id not in subscribed)
    insight = HistoryInsight(
        kid_id=kid_id,
        generated_at=now_iso(),
        videos=agg.videos,
        first_watched=agg.first_watched,
        last_watched=agg.last_watched,
        top_channels=[
            HistoryChannel(title=c.title, videos=c.videos, subscribed=c.channel_id in subscribed)
            for c in agg.channels[:TOP_CHANNELS]
        ],
        unsubscribed_share=round(unsubscribed / agg.attributed, 2) if agg.attributed else 0.0,
        by_hour=list(agg.by_hour),
    )
    insight.summary = plain_summary(insight)
    return insight


# --- the summary (one model call, channel names only) -------------------------

SUMMARY_SYSTEM_PROMPT = f"""You write two or three plain sentences for a parent who has just
imported their child's YouTube watch history. You are given counts only: how many videos, over what
dates, the channel names they came from with a count each, which of those the child follows, and
when in the day watching happens.

You have not seen a single video title and there are none to see. Do not imply otherwise.

Hard rules:
- Say what the numbers show and nothing else. No claim about the child's character, interests,
  intelligence, mood or attention span. "Most of it came from channels they do not follow" is a
  fact; "they seem drawn to fast, loud videos" is an invention.
- Never shame the parent or the child. No "only", no "too much", no "should".
- Do not recommend removing anything. The parent decides what to do with this.
- If the share from channels the child does not follow is high, say so plainly and say what it
  means: that a recommender, rather than the family's own list, chose most of this watching.

{SAFETY_RULES}
""".strip()

MAX_SUMMARY_CHARS = 600


class HistorySummary(BaseModel):
    summary: str = Field(description="Two or three plain sentences about the counts above")


def summary_agent(model=None) -> Agent:
    return make_agent("digest", SUMMARY_SYSTEM_PROMPT, model=model)


def summary_prompt(insight: HistoryInsight, kid: Kid) -> str:
    """Channel names and numbers. There is no video title anywhere in here."""
    channels = "\n".join(
        f"- {c.title}: {c.videos} videos" + ("" if c.subscribed else " (not subscribed)")
        for c in insight.top_channels[:CHANNELS_IN_PROMPT]
    ) or "- (no channel could be read)"
    window = peak_hours(insight.by_hour)
    return (
        f"nickname: {kid.nickname}\n"
        f"age_band: {kid.age_band}\n"
        f"videos watched: {insight.videos}\n"
        f"dates: {insight.first_watched or 'unknown'} to {insight.last_watched or 'unknown'}\n"
        f"share from channels they do not follow: {insight.unsubscribed_share}\n"
        f"busiest stretch of the day: "
        f"{f'{_clock(window[0])} to {_clock(window[1])}' if window else 'no clear pattern'}\n"
        f"most watched channels:\n{channels}\n\n"
        f"Return the HistorySummary."
    )


def write_summary(insight: HistoryInsight, kid: Kid, agent: Agent | None = None) -> str:
    """The model's sentences, or the ones built from the numbers.

    A failure here is not worth an error on the parent's screen: the counts are
    the substance and they are already computed, so the plain summary stands in.
    """
    if insight.videos == 0:
        return plain_summary(insight)
    try:
        text = structured(agent or summary_agent(), summary_prompt(insight, kid), HistorySummary).summary
    except Exception as e:  # noqa: BLE001 - any provider error: the numbers still render
        log.warning("history summary failed for %s: %s", kid.id, e)
        return plain_summary(insight)
    text = " ".join(text.split())
    if not text or len(text) > MAX_SUMMARY_CHARS:
        log.info("history summary for %s was unusable (%d chars)", kid.id, len(text))
        return plain_summary(insight)
    return text
