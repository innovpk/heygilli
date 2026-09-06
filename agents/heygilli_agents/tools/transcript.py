"""Transcripts (SPEC §9.4).

Order of preference inside one tool, so the Planner never knows which path ran:
  1. Gemini video understanding of the YouTube URL when GOOGLE_API_KEY is set
     (the only fully official path; needs `pip install google-genai`).
  2. Public caption tracks via youtube-transcript-api: English, then Urdu, then
     whatever auto-generated track exists.
  3. No transcript: return an empty list with source="none"; the Planner then
     produces one generic end-of-video question.
"""
from __future__ import annotations

import json
import logging
import os
import re

from strands import tool

from ..store import get_store


class TranscriptsBlocked(Exception):
    """YouTube has stopped serving captions to this machine.

    Not about one video: every fetch after it fails the same way. Callers that
    are working through a list must stop, because carrying on would screen the
    rest on titles alone and call the result a screening.
    """

log = logging.getLogger(__name__)

LANG_PREFERENCE = ["en", "en-US", "en-GB", "ur", "hi"]


def _from_gemini(video_id: str) -> list[dict] | None:
    api_key = os.getenv("GOOGLE_API_KEY")
    if not api_key:
        return None
    try:
        from google import genai  # type: ignore
        from google.genai import types  # type: ignore
    except ImportError:
        log.warning("GOOGLE_API_KEY set but google-genai not installed; using captions")
        return None
    client = genai.Client(api_key=api_key)
    prompt = (
        "Transcribe this video with timestamps. Return ONLY a JSON array of objects "
        '{"start_s": <int seconds>, "text": <spoken words>}. Start a new object at each '
        "sentence or scene change. Include a short [scene: ...] note in text when the "
        "picture changes."
    )
    resp = client.models.generate_content(
        model=os.getenv("HEYGILLI_GEMINI_MODEL", "gemini-2.5-flash"),
        contents=types.Content(
            parts=[
                types.Part(file_data=types.FileData(file_uri=f"https://www.youtube.com/watch?v={video_id}")),
                types.Part(text=prompt),
            ]
        ),
    )
    text = re.sub(r"^```(?:json)?|```$", "", resp.text.strip(), flags=re.MULTILINE).strip()
    rows = json.loads(text)
    return [{"start_s": int(r["start_s"]), "text": str(r["text"])} for r in rows]


def _from_captions(video_id: str) -> tuple[list[dict], str] | None:
    import requests
    from youtube_transcript_api import YouTubeTranscriptApi
    from youtube_transcript_api._errors import (
        CouldNotRetrieveTranscript,
        IpBlocked,
        NoTranscriptFound,
    )

    api = YouTubeTranscriptApi()
    try:
        tl = api.list(video_id)
    except IpBlocked as e:
        # IpBlocked is a CouldNotRetrieveTranscript, so it would otherwise be
        # filed as "this video has no captions" — and every video after it too.
        raise TranscriptsBlocked(str(e)) from e
    except CouldNotRetrieveTranscript as e:  # disabled, unavailable, age-gated, ...
        log.info("no captions for %s: %s", video_id, type(e).__name__)
        return None
    except (requests.RequestException, ValueError) as e:  # network or parsing changes
        log.warning("caption listing failed for %s: %s", video_id, e)
        return None

    chosen = None
    for finder in (tl.find_manually_created_transcript, tl.find_generated_transcript):
        try:
            chosen = finder(LANG_PREFERENCE)
            break
        except NoTranscriptFound:
            continue
    if chosen is None:
        available = list(tl)
        if not available:
            return None
        chosen = available[0]
    try:
        fetched = chosen.fetch()
    except IpBlocked as e:
        # Not this video's problem: YouTube has stopped answering this machine,
        # and every fetch after it will fail the same way. Raised on so the
        # caller can stop rather than screen the rest of the run blind.
        raise TranscriptsBlocked(str(e)) from e
    except Exception as e:  # noqa: BLE001 - third-party errors; no captions is a normal outcome
        log.warning("caption fetch failed for %s: %s", video_id, e)
        return None
    kind = "auto" if chosen.is_generated else "manual"
    rows = [{"start_s": int(s.start), "text": s.text.replace("\n", " ").strip()} for s in fetched]
    return rows, f"captions:{chosen.language_code}:{kind}"


def fetch_transcript(video_id: str) -> dict:
    """{"video_id", "source", "segments": [{"start_s", "text"}]} — cached forever."""
    store = get_store()
    cached = store.cache_get("transcript", video_id)
    if cached and cached.get("source") != "none":
        return cached

    segments: list[dict] = []
    source = "none"
    try:
        gem = _from_gemini(video_id)
    except Exception as e:  # noqa: BLE001 - third-party SDK errors; captions are the fallback
        log.warning("gemini transcript failed for %s: %s", video_id, e)
        gem = None
    if gem:
        segments, source = gem, "gemini"
    else:
        cap = _from_captions(video_id)
        if cap:
            segments, source = cap

    out = {"video_id": video_id, "source": source, "segments": segments}
    store.cache_put("transcript", video_id, out)
    return out


def transcript_text(segments: list[dict], max_chars: int = 12000) -> str:
    """Compact '[m:ss] text' lines for a prompt."""
    lines = []
    for s in segments:
        m, sec = divmod(int(s["start_s"]), 60)
        lines.append(f"[{m}:{sec:02d}] {s['text']}")
    text = "\n".join(lines)
    return text if len(text) <= max_chars else text[:max_chars] + "\n[...truncated]"


@tool
def get_transcript(video_id: str) -> dict:
    """Timestamped transcript of a YouTube video (Gemini if configured, else public captions).

    Args:
        video_id: 11-character YouTube video id

    Returns:
        {"video_id", "source": "gemini"|"captions:<lang>:<manual|auto>"|"none",
         "segments": [{"start_s": int, "text": str}]}
    """
    return fetch_transcript(video_id)
