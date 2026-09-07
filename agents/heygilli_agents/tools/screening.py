"""Rule-based pre-filter the Curator runs before it spends a model call.

Cheap, explainable, and conservative: it can hide or escalate, never approve.
The model still decides on everything that passes.
"""
from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel
from strands import tool

from ..schemas import Video

MAX_DURATION_S = 45 * 60
MIN_DURATION_S = 45

# Anything here is hidden without asking (SPEC §12: no scary content).
BLOCK_WORDS = (
    "horror", "scary", "creepy", "haunted", "gun", "kill", "murder", "blood", "gore", "zombie",
    "18+", "nsfw", "sexy", "prank gone wrong", "3am", "cursed", "death", "suicide", "drugs",
)
# Borderline: the parent gets a yes/no card.
ASK_WORDS = (
    "prank", "challenge", "gross", "fight", "battle", "weapon", "surgery", "hospital", "accident",
    "gambling", "casino", "unboxing", "giveaway", "buy now", "sponsored", "ad ", "haul",
)


#: A title claiming to be a live stream.
#:
#: There is no honest way to screen one. HeyGilli's promise is that every
#: upload is read against what the household said *before* the child sees it,
#: and a stream's content has not happened yet — there is nothing to read. The
#: Curator handled them the only way it could, by asking the parent, so a
#: channel running a 24/7 loop put five identical cards in the inbox and kept
#: adding more.
#:
#: The title is the only signal available. The RSS feed carries no live marker
#: — checked against a channel that streams constantly — and the watch page
#: that would say so is refused to datacenter addresses. So this reads the
#: title, and reads it strictly: a bare lower-case "live" is ordinary English
#: ("live action", "where they live"), while a red circle, LIVE shouted in
#: capitals, or "24/7" is a badge.
LIVE_MARKERS = ("🔴", "🟢", "24/7", "24 / 7")
LIVE_PHRASES = ("live stream", "livestream", "streaming now", "live now")
#: Ordinary English that contains the word and means nothing of the sort.
NOT_LIVE = ("live action", "live-action")


def looks_live(title: str) -> bool:
    """Whether this title is announcing a stream rather than a video."""
    t = title.lower()
    if any(phrase in t for phrase in NOT_LIVE):
        return False
    if any(marker in title for marker in LIVE_MARKERS):
        return True
    if any(phrase in t for phrase in LIVE_PHRASES):
        return True
    # Shouted, and a word of its own: "LIVE!" is a badge, "Olive" is not.
    return bool(re.search(r"(?<![A-Za-z])LIVE(?![a-z])", title))


class ScreenResult(BaseModel):
    verdict: Literal["pass", "hide", "ask_parent"]
    reason: str


def _hits(text: str, words: tuple[str, ...]) -> list[str]:
    t = f" {text.lower()} "
    return [w for w in words if re.search(rf"(?<![a-z]){re.escape(w)}(?![a-z])", t)]


def prescreen(video: Video) -> ScreenResult:
    text = f"{video.title} {video.description}"
    if hits := _hits(text, BLOCK_WORDS):
        return ScreenResult(verdict="hide", reason=f"title/description mentions: {', '.join(hits)}")
    if looks_live(video.title):
        return ScreenResult(
            verdict="hide",
            reason="a live stream, so what it will show has not happened yet and "
                   "cannot be read against your answers",
        )
    if video.duration_s > MAX_DURATION_S:
        return ScreenResult(verdict="ask_parent", reason="longer than 45 minutes")
    if 0 < video.duration_s < MIN_DURATION_S:
        return ScreenResult(verdict="hide", reason="too short to hold a question")
    if hits := _hits(text, ASK_WORDS):
        return ScreenResult(verdict="ask_parent", reason=f"borderline topic: {', '.join(hits)}")
    return ScreenResult(verdict="pass", reason="no rule triggered")


@tool
def screen_video(title: str, description: str = "", duration_s: int = 0) -> dict:
    """Rule-based safety pre-check for a YouTube video before the model reviews it.

    Args:
        title: video title
        description: video description (may be empty)
        duration_s: length in seconds, 0 if unknown

    Returns:
        {"verdict": "pass"|"hide"|"ask_parent", "reason": str}
    """
    return prescreen(
        Video(id="_", title=title, description=description, duration_s=duration_s)
    ).model_dump()
