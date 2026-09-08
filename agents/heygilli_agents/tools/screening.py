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
    """The rules that run before the model, each saying why in the parent's terms.

    These reasons are read by somebody deciding whether to overrule them, so
    every one of them has to answer the question they are actually asking: not
    "which rule fired" but "was there anything wrong with this video". Two of
    them used to answer the first. "Too short to hold a question" reads as a
    verdict on the video, and a parent seeing it beside a perfectly ordinary
    clip has no way to tell that nothing was found wrong with it at all — the
    only thing wrong was that Gilli would have had nothing to ask about.
    """
    text = f"{video.title} {video.description}"
    if hits := _hits(text, BLOCK_WORDS):
        return ScreenResult(
            verdict="hide",
            reason=f"The title or description mentions {', '.join(hits)}, which is on the "
                   f"list of things kept from every child whatever their household said.",
        )
    if looks_live(video.title):
        return ScreenResult(
            verdict="hide",
            reason="This is a live stream. What it will show has not happened yet, so there "
                   "is nothing to read against your answers and no way to say whether it "
                   "will suit them.",
        )
    if video.duration_s > MAX_DURATION_S:
        return ScreenResult(
            verdict="ask_parent",
            reason=f"This runs {video.duration_s // 60} minutes, which is longer than "
                   f"{MAX_DURATION_S // 60}. Nothing was found wrong with it — it is the "
                   f"length alone, and whether that suits them is yours to say.",
        )
    if 0 < video.duration_s < MIN_DURATION_S:
        return ScreenResult(
            verdict="hide",
            reason=f"This is {video.duration_s} seconds long. Nothing was found wrong with "
                   f"it; it is too short for Gilli to watch along and ask anything about, "
                   f"which is the whole of what Gilli is for. Allow it if you want it there.",
        )
    if hits := _hits(text, ASK_WORDS):
        return ScreenResult(
            verdict="ask_parent",
            reason=f"The title or description mentions {', '.join(hits)}. That is a "
                   f"judgement call rather than a rule, so it comes to you rather than "
                   f"being decided for you.",
        )
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
