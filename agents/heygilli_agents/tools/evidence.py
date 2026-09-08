"""Tools the Explainer uses to answer a parent's question about one video.

The excerpt in the prompt is the opening of the video, because that is what
fits. A parent's question is very often about something else — the end, the
sponsor read in the middle, the one bit they heard about — and an agent that
can only see the opening has to either guess or shrug.

So it gets to go and look. `search_transcript` reaches the whole transcript
rather than the excerpt, which is the difference between "the words don't
mention a dog being hurt" and "the words don't mention it in the first six
minutes, which is all I was given".
"""
from __future__ import annotations

import logging

from strands import tool

from ..store import get_store
from .transcript import TranscriptsBlocked, fetch_transcript

log = logging.getLogger(__name__)

MAX_HITS = 12
CONTEXT_CHARS = 220


def _stamp(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 60}:{total % 60:02d}"


@tool
def search_transcript(video_id: str, phrase: str) -> dict:
    """Find where a word or phrase is said in a video, anywhere in it.

    Searches the whole transcript, not just the part quoted in the prompt. Use
    it to check a specific worry — a word, a name, a product, a kind of event —
    before saying whether the video contains it.

    Args:
        video_id: YouTube video id
        phrase: word or phrase to look for; matched case-insensitively

    Returns:
        {"found": bool, "hits": [{"at": "3:12", "text": str}], "source": str,
         "searched_whole_video": bool}
        `searched_whole_video` is TRUE when every word anyone has of this video
        was searched — a phrase that did not turn up is not said in it, and may
        be reported as simply absent. It is FALSE only when there is no
        transcript at all, in which case "not found" means nothing was read
        rather than that the phrase is absent.
    """
    needle = (phrase or "").strip().lower()
    if not needle:
        return {"found": False, "hits": [], "source": "none", "searched_whole_video": False}
    try:
        tr = fetch_transcript(video_id)
    except TranscriptsBlocked as e:
        log.info("no transcript to search for %s: %s", video_id, e)
        return {"found": False, "hits": [], "source": "none", "searched_whole_video": False}

    segments = tr.get("segments") or []
    hits = [
        {"at": _stamp(seg.get("start_s", 0)), "text": str(seg.get("text", ""))[:CONTEXT_CHARS]}
        for seg in segments
        if needle in str(seg.get("text", "")).lower()
    ]
    return {
        "found": bool(hits),
        "hits": hits[:MAX_HITS],
        "source": tr.get("source", "none"),
        # The distinction the whole tool exists for: "it is not in the video"
        # and "nobody read the video" are different answers to a parent.
        "searched_whole_video": bool(segments),
    }


@tool
def channel_reputation(channel_id: str) -> dict:
    """What HeyGilli already worked out about the channel this video came from.

    Only what is cached from an earlier review — this never goes and fetches
    one, because a parent waiting on an answer about a video should not wait on
    a channel being read from scratch.

    Args:
        channel_id: YouTube channel id

    Returns:
        {"known": bool, "verdict": str, "summary": str, "flags": [str]}
    """
    cached = get_store().get_channel_review(channel_id) if channel_id else None
    if not cached:
        return {"known": False, "verdict": "", "summary": "", "flags": []}
    return {
        "known": True,
        "verdict": str(cached.get("verdict", "")),
        "summary": str(cached.get("summary", "")),
        "flags": [str(f.get("note", "")) for f in (cached.get("flags") or [])],
    }
