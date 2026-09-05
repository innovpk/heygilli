"""Parent notifications. Writes a ParentPrompt the phone app reads from /parent/inbox.

Push notifications are out of scope for the hackathon; the prompt is logged.
"""
from __future__ import annotations

import logging

from strands import tool

from ..schemas import ParentPrompt, Video
from ..store import get_store

log = logging.getLogger(__name__)


def notify_parent(household_id: str, kid_id: str, video: Video, reason: str) -> ParentPrompt:
    p = ParentPrompt(household_id=household_id, kid_id=kid_id, video=video, reason=reason)
    get_store().put_parent_prompt(p)
    log.info("parent prompt %s for kid %s: %s (%s)", p.id, kid_id, video.title, reason)
    return p


@tool
def notify_parent_tool(household_id: str, kid_id: str, video_id: str, reason: str) -> dict:
    """Ask the parent a yes/no question about a video (it appears in their inbox).

    Args:
        household_id: the household the kid belongs to
        kid_id: the kid this concerns
        video_id: YouTube video id already known to the store
        reason: one plain line the parent can read

    Returns:
        {"prompt_id": str}
    """
    video = get_store().get_video(video_id) or Video(id=video_id, title=video_id)
    return {"prompt_id": notify_parent(household_id, kid_id, video, reason).id}
