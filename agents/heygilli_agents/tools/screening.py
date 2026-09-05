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
