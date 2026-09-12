"""Transcripts (SPEC §9.4).

Order of preference inside one tool, so the Planner never knows which path ran.
Cheapest first, because the three cost very different things:
  1. Public caption tracks via youtube-transcript-api: English, then Urdu, then
     whatever auto-generated track exists. Free, instant, and the only path
     that tells us the spoken language. YouTube refuses these to datacenter
     addresses, so in production this usually fails once and is then skipped.
  2. Gemini video understanding of the YouTube URL when GOOGLE_API_KEY is set.
     Reads the video from inside Google, so the block above does not apply
     (needs `pip install google-genai`). A free key has a quota; when it runs
     out this path stands down for a while instead of collecting 429s.
  3. The same caption tracks through a proxy, when one is configured
     (HEYGILLI_PROXY_URL, or WEBSHARE_PROXY_USERNAME/PASSWORD). Last because it
     is the only one that costs money per request.
  4. No transcript: return an empty list with source="none"; the Planner then
     produces one generic end-of-video question. When captions were *refused*
     rather than absent, `TranscriptsBlocked` is raised instead, so a caller
     working through a list can stop rather than screen the rest on titles.
"""
from __future__ import annotations

import json
import logging
import os
import random
import re
import threading
import time

from strands import tool

from ..store import get_store

#: Seconds to leave between two caption requests. YouTube rate-limits a machine
#: that pulls many in a row, and it took about thirty to trip: a 148-channel
#: household hits that every time. Overridable so tests do not sleep and so a
#: recording day can slow it down further.
CAPTION_INTERVAL_S = float(os.getenv("HEYGILLI_CAPTION_INTERVAL_S", "1.5"))

_last_caption_at = 0.0
_caption_lock = threading.Lock()


def _wait_turn() -> None:
    """Space caption requests out, one caller at a time.

    Deliberately a real sleep on a real lock rather than a token bucket: the
    Curator is the only caller, it runs in a background thread, and nothing is
    waiting on it. Being slow here costs a parent nothing and is the difference
    between screening a household and getting cut off a third of the way in.

    The jitter matters as much as the delay. Requests spaced exactly evenly
    look more like a script than requests that are merely slow.
    """
    global _last_caption_at
    if CAPTION_INTERVAL_S <= 0:
        return
    with _caption_lock:
        gap = time.monotonic() - _last_caption_at
        wait = CAPTION_INTERVAL_S + random.uniform(0, CAPTION_INTERVAL_S / 2) - gap
        if wait > 0:
            time.sleep(wait)
        _last_caption_at = time.monotonic()


class TranscriptsBlocked(Exception):
    """YouTube has stopped serving captions to this machine.

    Not about one video: every fetch after it fails the same way. Callers that
    are working through a list must stop, because carrying on would screen the
    rest on titles alone and call the result a screening.
    """

log = logging.getLogger(__name__)

LANG_PREFERENCE = ["en", "en-US", "en-GB", "ur", "hi"]


#: How long to leave Gemini alone after it says the quota is gone. The free
#: tier limits both requests-per-minute and requests-per-day, and we cannot
#: tell which one tripped from the error, so this is short enough that a
#: per-minute limit costs one pause and long enough that a per-day one does not
#: turn the run into a wall of 429s.
GEMINI_COOLDOWN_S = float(os.getenv("HEYGILLI_GEMINI_COOLDOWN_S", "900"))

#: YouTube has refused captions to this process. Not per video: once it starts
#: refusing it refuses everything, so the first refusal stops us asking again.
_captions_blocked = False

#: Monotonic time before which Gemini is out of quota and must not be called.
_gemini_until = 0.0

#: Why Gemini last turned us down. Carried into the `TranscriptsBlocked` message
#: so that "nothing was screened" arrives with its cause attached: a bad key, a
#: disabled API and an exhausted quota are three different jobs for whoever
#: reads it, and they are indistinguishable from an empty home.
_gemini_last_error = ""


def _note_captions_blocked(e: Exception) -> None:
    global _captions_blocked
    if not _captions_blocked:
        log.warning("YouTube refused captions to this machine; not asking again: %s", e)
    _captions_blocked = True


def _gemini_ready() -> bool:
    return time.monotonic() >= _gemini_until


def _is_quota_error(e: Exception) -> bool:
    """Whether Gemini turned us down for quota rather than for this video.

    Matched on the message because google-genai raises one `ClientError` for
    every 4xx and the distinction we need — "come back later" versus "this
    video cannot be read" — lives only in its text.
    """
    text = f"{type(e).__name__} {e}".upper()
    return "RESOURCE_EXHAUSTED" in text or "429" in text or "QUOTA" in text


def _note_gemini_failure(video_id: str, e: Exception) -> None:
    global _gemini_until, _gemini_last_error
    _gemini_last_error = f"{type(e).__name__}: {e}"[:200]
    if _is_quota_error(e):
        _gemini_until = time.monotonic() + GEMINI_COOLDOWN_S
        log.warning("gemini quota reached; standing down for %ds", int(GEMINI_COOLDOWN_S))
    else:
        log.warning("gemini transcript failed for %s: %s", video_id, e)


#: How every blocked message starts. Named so one can be recognised when it
#: arrives as the cause of another.
_BLOCKED_PREFIX = "no transcript source answered — "


def clear_cooldowns() -> None:
    """Forget that Gemini or captions turned us down, for the debug endpoint.

    Standing down is what stops a run being spent on 429s, and it also means
    that by the time anybody asks why a transcript failed, the answer on hand
    is "we did not try" — which is not the answer they need.
    """
    global _gemini_until, _captions_blocked
    _gemini_until = 0.0
    _captions_blocked = False


def _why_blocked(captions_error: Exception | None = None) -> str:
    """One line naming every source that could have answered and did not.

    Whoever reads this is trying to work out why a household has nothing to
    watch, and "captions were refused" alone has sent that person to check the
    wrong thing more than once.
    """
    # A cached captions failure is itself a TranscriptsBlocked whose text is
    # already a whole _why_blocked() line. Embedding it produced a message that
    # said everything twice, which is how it read the first time anyone needed
    # it: "no transcript source answered - captions: no transcript source
    # answered - captions: refused to this machine; gemini: ...; gemini: ...".
    why = str(captions_error) if captions_error else "refused to this machine"
    if why.startswith(_BLOCKED_PREFIX):
        why = "refused to this machine"
    parts = [f"captions: {why}"]
    if not os.getenv("GOOGLE_API_KEY"):
        parts.append("gemini: no GOOGLE_API_KEY")
    elif not _gemini_ready():
        parts.append(
            f"gemini: standing down for {int(_gemini_until - time.monotonic())}s after "
            f"{_gemini_last_error or 'a quota refusal'}"
        )
    else:
        parts.append(f"gemini: {_gemini_last_error or 'no transcript returned'}")
    parts.append("proxy: configured" if _proxy_config() else "proxy: not configured")
    return _BLOCKED_PREFIX + "; ".join(parts)


def _proxy_config():
    """The proxy for caption requests, or None when none is configured.

    Two shapes because the two ways people buy this differ: Webshare hands out
    a rotating pool behind one username, everyone else hands out a URL.
    """
    from youtube_transcript_api.proxies import GenericProxyConfig, WebshareProxyConfig

    username = os.getenv("WEBSHARE_PROXY_USERNAME", "").strip()
    if username:
        return WebshareProxyConfig(
            proxy_username=username,
            proxy_password=os.getenv("WEBSHARE_PROXY_PASSWORD", "").strip(),
        )
    url = os.getenv("HEYGILLI_PROXY_URL", "").strip()
    return GenericProxyConfig(http_url=url, https_url=url) if url else None


#: Attempts for one video before giving up on Gemini for it. The free tier
#: answers 503 "high demand" often enough that a single try lost whole runs,
#: and the retry costs a pause where the alternative costs the screening.
GEMINI_ATTEMPTS = int(os.getenv("HEYGILLI_GEMINI_ATTEMPTS", "6"))

#: First backoff, doubled each attempt. Six attempts from two seconds waits
#: about a minute in total. That is a long time to sit still, and it is spent
#: inside a background curation run where nobody is waiting on the response —
#: whereas giving up buys a video screened on its title for as long as it
#: exists, because a successful transcript is cached forever and a failed one
#: is not retried until the next run.
GEMINI_BACKOFF_S = float(os.getenv("HEYGILLI_GEMINI_BACKOFF_S", "2"))


def _is_transient(e: Exception) -> bool:
    """A "come back in a moment", as opposed to a wrong model or a dead key.

    Matched on the message for the same reason as `_is_quota_error`: one
    exception type covers every server-side refusal.
    """
    text = f"{type(e).__name__} {e}".upper()
    return "503" in text or "UNAVAILABLE" in text or "500" in text or "INTERNAL" in text


def _with_retries(call, video_id: str):
    """Run `call`, retrying only what is worth retrying.

    `_is_transient` is the only thing that decides. A quota refusal is not in
    it on purpose: the caller stands the whole path down for one, and trying
    again immediately would spend that cooldown early for nothing.
    """
    for attempt in range(1, GEMINI_ATTEMPTS + 1):
        try:
            return call()
        except Exception as e:
            if attempt == GEMINI_ATTEMPTS or not _is_transient(e):
                raise
            wait = GEMINI_BACKOFF_S * (2 ** (attempt - 1))
            log.info("gemini busy for %s (attempt %d), retrying in %.0fs", video_id, attempt, wait)
            time.sleep(wait)
    return None  # unreachable: the loop returns or raises


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
        "Transcribe this video with timestamps. Return ONLY a JSON object "
        '{"duration_s": <int, the total length of the video in seconds>, '
        '"segments": [{"start_s": <int seconds>, "text": <spoken words>}, ...]}. '
        "Start a new segment at each sentence or scene change. Include a short "
        "[scene: ...] note in text when the picture changes."
    )
    def call():
        return client.models.generate_content(
            # A lite model, and not for cost: free-tier quota is counted per
            # model name, and gemini-3.6-flash's is spent. Asking the live
            # gateway for the same video on each name separated them — the
            # flash answered 429 RESOURCE_EXHAUSTED on every attempt, while
            # the lite answered 503 "high demand", which is a queue rather
            # than a wall, and returned a full transcript once it got a turn.
            #
            # Overridable because this name will retire, and because the next
            # thing to check when transcripts stop is whether another one has
            # quota left.
            model=os.getenv("HEYGILLI_GEMINI_MODEL", "gemini-3.5-flash-lite"),
            contents=types.Content(
                parts=[
                    types.Part(file_data=types.FileData(file_uri=f"https://www.youtube.com/watch?v={video_id}")),
                    types.Part(text=prompt),
                ]
            ),
        )

    resp = _with_retries(call, video_id)
    return parse_gemini(resp.text)


def parse_gemini(raw: str) -> tuple[list[dict], int]:
    """Segments and the video's length from Gemini's answer.

    The length is asked for because it is the one fact about a video the
    deployed gateway had no other way to get: the watch page is refused to
    datacenter addresses, and `videos.list` needs a Google grant the household
    may not have. Gemini has just watched the whole thing, so it knows.

    Two shapes are accepted — the object asked for, and the bare array the
    prompt used to ask for — so a model that ignores the new instruction still
    yields a transcript, with the length left at 0 for "unknown".
    """
    text = re.sub(r"^```(?:json)?|```$", "", raw.strip(), flags=re.MULTILINE).strip()
    data = json.loads(text)
    duration = 0
    rows = data
    if isinstance(data, dict):
        rows = data.get("segments") or []
        try:
            duration = max(int(data.get("duration_s") or 0), 0)
        except (TypeError, ValueError):
            duration = 0
    segments = [{"start_s": int(r["start_s"]), "text": str(r["text"])} for r in rows]
    return segments, duration


def _from_captions(video_id: str, proxy=None) -> tuple[list[dict], str] | None:
    """YouTube's own caption track, optionally through a proxy.

    `proxy` is a `ProxyConfig` from `_proxy_config`. Passing one changes only
    the address the request leaves from; every outcome below means the same
    thing either way.
    """
    import requests
    from youtube_transcript_api import YouTubeTranscriptApi
    from youtube_transcript_api._errors import (
        CouldNotRetrieveTranscript,
        IpBlocked,
        NoTranscriptFound,
    )

    _wait_turn()
    api = YouTubeTranscriptApi(proxy_config=proxy)
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
    _wait_turn()
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
    # The last cue's end is very nearly the video's length — captions stop at
    # the last spoken word, so it is a floor, never an overestimate, and a
    # question scheduled against it still lands inside the video.
    snippets = list(fetched)
    duration = (
        int(snippets[-1].start + (getattr(snippets[-1], "duration", 0) or 0)) if snippets else 0
    )
    return rows, f"captions:{chosen.language_code}:{kind}", duration


def fetch_transcript(video_id: str) -> dict:
    """{"video_id", "source", "segments": [{"start_s", "text"}], "duration_s"} — cached forever.

    `duration_s` is the video's length as the transcript source saw it, 0 for
    unknown. It rides along because the sources that read the words are the
    only ones that answer from a datacenter (see `parse_gemini`).

    Three places the words can come from, cheapest first, because they cost
    very different things and only the first is free everywhere:

      1. YouTube's own captions, fetched directly. Free and instant, and the
         only path that reports the spoken language. From a home connection it
         answers every time; from a datacenter YouTube refuses, and once it has
         refused it refuses for the rest of the process, so the attempt is made
         once and then skipped rather than 95 times.
      2. Gemini, which reads the video from inside Google and so is not subject
         to that block. A free key has a quota; when it runs out we stand down
         for `GEMINI_COOLDOWN_S` rather than spending the run on 429s.
      3. The same captions through a proxy. Last because it is the only one
         that costs money per request.

    `TranscriptsBlocked` is raised only when captions were refused *and*
    nothing else could stand in. That is the caller's signal that the words are
    unavailable for this machine, not for this video, so it can stop rather
    than screen a whole run on titles and call it a screening.
    """
    store = get_store()
    cached = store.cache_get("transcript", video_id)
    if cached and cached.get("source") != "none":
        return cached

    segments: list[dict] = []
    source = "none"
    duration = 0
    blocked: TranscriptsBlocked | None = None

    if _captions_blocked:
        # Already refused earlier in this process. Not asking again, but the
        # refusal still stands and must still be reported if nothing else
        # answers — a skipped attempt is not the same as an absent caption
        # track, and returning "none" here would tell the Curator to screen
        # every remaining video on its title as though that were normal.
        blocked = TranscriptsBlocked(_why_blocked())
    else:
        try:
            cap = _from_captions(video_id)
        except TranscriptsBlocked as e:
            _note_captions_blocked(e)
            blocked = e
        else:
            if cap:
                segments, source, duration = _unpack_captions(cap)

    if source == "none" and _gemini_ready():
        try:
            gem = _from_gemini(video_id)
        except Exception as e:  # noqa: BLE001 - third-party SDK errors; the proxy is the fallback
            _note_gemini_failure(video_id, e)
            gem = None
        if gem:
            segments, duration = gem if isinstance(gem, tuple) else (gem, 0)
            source = "gemini"

    if source == "none":
        proxy = _proxy_config()
        if proxy is not None:
            try:
                cap = _from_captions(video_id, proxy)
            except TranscriptsBlocked as e:
                # The proxy's address is refused too. Nothing is left to try.
                log.warning("captions blocked through the proxy for %s: %s", video_id, e)
                blocked = e
            else:
                if cap:
                    segments, source, duration = _unpack_captions(cap)
                    blocked = None

    if source == "none" and blocked is not None:
        raise TranscriptsBlocked(_why_blocked(blocked))

    out = {"video_id": video_id, "source": source, "segments": segments, "duration_s": duration}
    store.cache_put("transcript", video_id, out)
    return out


def _unpack_captions(cap: tuple) -> tuple[list[dict], str, int]:
    """`(rows, source)` or `(rows, source, duration_s)`; the two-tuple is the
    older shape, still produced by tests and fakes, and means length unknown."""
    rows, source = cap[0], cap[1]
    duration = int(cap[2]) if len(cap) > 2 else 0
    return rows, source, duration


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


def gemini_available() -> bool:
    """Whether the Gemini path could run: a key is set and the SDK is installed.

    Reported by /healthz. It answers "is this deployment able to read a
    transcript at all", which is otherwise indistinguishable from "the deploy
    has not landed yet" — both look like an empty home.
    """
    if not os.getenv("GOOGLE_API_KEY"):
        return False
    try:
        from google import genai  # type: ignore # noqa: F401
    except ImportError:
        return False
    return True


def proxy_configured() -> bool:
    """Whether a caption proxy is set. The address itself is never reported."""
    return _proxy_config() is not None
