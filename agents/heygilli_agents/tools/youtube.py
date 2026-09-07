"""YouTube metadata without an API key: page HTML, the public RSS feed, and oEmbed.

Everything is cached in the store so the Curator can run every few hours
without re-fetching. If YOUTUBE_API_KEY ever exists this is the one module to
swap for the Data API (SPEC §9.4).
"""
from __future__ import annotations

import contextlib
import html
import logging
import os
import re
import xml.etree.ElementTree as ET

import httpx
from strands import tool

from ..store import get_store

log = logging.getLogger(__name__)

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/124 Safari/537.36"
# SOCS=CAI skips the EU cookie-consent interstitial that otherwise replaces every page.
_HEADERS = {
    "User-Agent": UA,
    "Accept-Language": "en-US,en;q=0.9",
    "Cookie": "SOCS=CAI; CONSENT=PENDING+987",
}
_VIDEO_ID = re.compile(r"(?:v=|/shorts/|/embed/|youtu\.be/)([A-Za-z0-9_-]{11})")
_CHANNEL_ID = re.compile(r"/channel/(UC[A-Za-z0-9_-]{22})")


def _get(url: str, timeout: float = 15.0) -> str:
    with httpx.Client(headers=_HEADERS, follow_redirects=True, timeout=timeout) as c:
        r = c.get(url)
        r.raise_for_status()
        return r.text


def _find(pattern: str, text: str) -> str:
    m = re.search(pattern, text)
    return html.unescape(m.group(1)) if m else ""


def video_id_from_url(url: str) -> str | None:
    m = _VIDEO_ID.search(url)
    return m.group(1) if m else None


def resolve_channel_url(url: str) -> dict:
    """Return {"channel_id", "title", "thumb_url"} for a channel/handle/video URL."""
    url = url.strip()
    if url.startswith("UC") and len(url) == 24:
        url = f"https://www.youtube.com/channel/{url}"
    elif url.startswith("@"):
        url = f"https://www.youtube.com/{url}"
    elif not url.startswith("http"):
        url = f"https://{url}"

    cached = get_store().cache_get("channel_url", url)
    if cached:
        return cached

    vid: str | None = None
    if m := _CHANNEL_ID.search(url):
        channel_id = m.group(1)
        page = _get(url)
    elif vid := video_id_from_url(url):
        page = _get(f"https://www.youtube.com/watch?v={vid}")
        channel_id = _find(r'"channelId":"(UC[A-Za-z0-9_-]{22})"', page)
    else:
        page = _get(url)
        channel_id = _find(r'"externalId":"(UC[A-Za-z0-9_-]{22})"', page) or _find(
            r'"channelId":"(UC[A-Za-z0-9_-]{22})"', page
        )
    if not channel_id:
        raise ValueError(f"could not find a channel id in {url}")

    title = _find(r'"ownerChannelName":"([^"]+)"', page) or _find(
        r'<meta property="og:title" content="([^"]+)"', page
    )
    if vid:  # a video page: og:title is the video, prefer the channel's own page
        try:
            cpage = _get(f"https://www.youtube.com/channel/{channel_id}")
            title = _find(r'<meta property="og:title" content="([^"]+)"', cpage) or title
            page = cpage
        except httpx.HTTPError:
            pass
    thumb = _find(r'"avatar":\{"thumbnails":\[\{"url":"([^"]+)"', page) or _find(
        r'<meta property="og:image" content="([^"]+)"', page
    )
    out = {"channel_id": channel_id, "title": title or channel_id, "thumb_url": thumb}
    get_store().cache_put("channel_url", url, out)
    return out


def fetch_channel_feed(channel_id: str, limit: int = 15) -> dict:
    """The channel's public RSS feed: `{"channel_id", "title", "uploads"}`.

    One request, no API key, no quota. The feed carries the channel's own title,
    so the Reviewer gets a name and recent uploads together (`fetch_uploads`
    below is the same call when only the uploads are wanted).
    """
    xml = _get(f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}")
    ns = {
        "a": "http://www.w3.org/2005/Atom",
        "yt": "http://www.youtube.com/xml/schemas/2015",
        "media": "http://search.yahoo.com/mrss/",
    }
    root = ET.fromstring(xml)
    author = root.find("a:author/a:name", ns)
    title = (author.text if author is not None else "") or root.findtext(
        "a:title", default="", namespaces=ns
    )
    out: list[dict] = []
    for e in root.findall("a:entry", ns)[:limit]:
        vid = e.findtext("yt:videoId", default="", namespaces=ns)
        group = e.find("media:group", ns)
        thumb = ""
        desc = ""
        if group is not None:
            t = group.find("media:thumbnail", ns)
            thumb = t.get("url", "") if t is not None else ""
            desc = group.findtext("media:description", default="", namespaces=ns)
        out.append(
            {
                "id": vid,
                "channel_id": channel_id,
                "title": e.findtext("a:title", default="", namespaces=ns),
                "published_at": e.findtext("a:published", default="", namespaces=ns),
                "thumb_url": thumb,
                "description": desc[:1000],
            }
        )
    return {"channel_id": channel_id, "title": (title or "").strip(), "uploads": out}


def fetch_uploads(channel_id: str, limit: int = 10) -> list[dict]:
    """Newest uploads from the public RSS feed (no key, ~15 most recent)."""
    return fetch_channel_feed(channel_id, limit)["uploads"]


def fetch_video_meta(video_id: str) -> dict:
    """oEmbed title/thumb plus duration from the watch page when it is cheap."""
    cached = get_store().cache_get("video_meta", video_id)
    if cached:
        return cached
    url = f"https://www.youtube.com/watch?v={video_id}"
    meta = {"id": video_id, "title": "", "thumb_url": "", "channel_id": "", "duration_s": 0}
    try:
        with httpx.Client(headers=_HEADERS, timeout=15.0) as c:
            r = c.get("https://www.youtube.com/oembed", params={"url": url, "format": "json"})
            if r.status_code == 200:
                j = r.json()
                meta["title"] = j.get("title", "")
                meta["thumb_url"] = j.get("thumbnail_url", "")
    except httpx.HTTPError as e:
        log.warning("oembed failed for %s: %s", video_id, e)
    try:
        page = _get(url)
        meta["duration_s"] = int(_find(r'"lengthSeconds":"(\d+)"', page) or 0)
        meta["channel_id"] = _find(r'"channelId":"(UC[A-Za-z0-9_-]{22})"', page)
        meta["title"] = meta["title"] or _find(r'<meta name="title" content="([^"]+)"', page)
    except (httpx.HTTPError, ValueError) as e:
        log.warning("watch page failed for %s: %s", video_id, e)
    if meta["title"]:
        get_store().cache_put("video_meta", video_id, meta)
    return meta


# --- Searching YouTube, for the parent only ---------------------------------------------
#
# The one place HeyGilli asks YouTube a question rather than reading a feed,
# and it is deliberately narrow. A *child* can never search: their home filters
# the videos already approved for them, because searching would hand back the
# open internet and undo the allowlist the product rests on. A parent searching
# for a channel to approve is the opposite — the result is a suggestion they
# then approve, and every upload from it is still screened.
#
# Channels, not videos: HeyGilli approves a channel and screens what it
# publishes from then on, so a channel is the thing a parent is looking for.

SEARCH_URL = "https://www.googleapis.com/youtube/v3/search"
#: `search.list` costs 100 quota units a call against a default 10,000 a day,
#: so this is a hundred searches a day for every household put together — by
#: far the most expensive call in here, and the reason it is not used anywhere
#: automatic.
SEARCH_COST_UNITS = 100


class SearchUnavailable(Exception):
    """YouTube search is not usable, and why — a message a parent can act on."""


def search_channels(query: str, limit: int = 10) -> list[dict]:
    """Channels matching what the parent typed.

    Needs `GOOGLE_API_KEY` to be allowed to call the YouTube Data API. A key
    restricted to another API answers 403, which is a setup problem rather than
    a bad search, so it is raised as one instead of coming back as "no
    results" — a parent retyping their query would never fix it.
    """
    q = query.strip()
    if not q:
        return []
    # Its own variable, and not GOOGLE_API_KEY, because the two are different
    # kinds of credential. An AI Studio key is bound to a service account, and
    # the YouTube Data API refuses that shape outright — "API keys are not
    # supported by this API" — however its restrictions are set. Searching
    # needs a plain API key, so it gets its own; GOOGLE_API_KEY falls back
    # only for a deployment where one plain key does both.
    key = (
        os.getenv("HEYGILLI_YOUTUBE_API_KEY", "").strip()
        or os.getenv("GOOGLE_API_KEY", "").strip()
    )
    if not key:
        raise SearchUnavailable(
            "Searching YouTube is not set up on this server: it needs a plain "
            "YouTube Data API key in HEYGILLI_YOUTUBE_API_KEY."
        )
    params = {
        "part": "snippet",
        "type": "channel",
        "q": q,
        "maxResults": max(1, min(limit, 25)),
        "key": key,
    }
    try:
        with httpx.Client(timeout=20.0) as c:
            r = c.get(SEARCH_URL, params=params)
    except httpx.HTTPError as e:
        raise SearchUnavailable(f"Could not reach YouTube: {type(e).__name__}") from e

    if r.status_code != 200:
        # Google's own words, whatever the status. Reporting only the number
        # made a 401 ("the key is not accepted") and a 403 ("this key may not
        # call this API") look like the same shrug, and neither is something a
        # parent's query can fix — the difference is entirely in what the
        # person running the server has to go and change.
        detail = ""
        with contextlib.suppress(Exception):
            detail = str((r.json().get("error") or {}).get("message") or "")
        hint = {
            401: "the API key was not accepted",
            403: "the key may not call this API, or the daily search limit is spent",
        }.get(r.status_code, "")
        raise SearchUnavailable(
            " ".join(
                part for part in (
                    f"YouTube answered {r.status_code} to the search.",
                    f"({hint})" if hint else "",
                    detail,
                ) if part
            )
        )

    out: list[dict] = []
    for item in (r.json().get("items") or []):
        channel_id = str((item.get("id") or {}).get("channelId") or "").strip()
        snippet = item.get("snippet") or {}
        if not channel_id:
            continue
        out.append({
            "channel_id": channel_id,
            "title": html.unescape(str(snippet.get("title") or "")).strip(),
            "blurb": html.unescape(str(snippet.get("description") or "")).strip(),
            "thumb_url": _best_thumb(snippet),
        })
    return out


def _best_thumb(snippet: dict) -> str:
    thumbs = snippet.get("thumbnails") or {}
    for size in ("medium", "high", "default"):
        url = (thumbs.get(size) or {}).get("url")
        if url:
            return str(url)
    return ""


# --- Strands tools -----------------------------------------------------------------------


@tool
def resolve_channel(url: str) -> dict:
    """Resolve any YouTube channel, @handle, or video URL to its channel id and title.

    Args:
        url: e.g. https://www.youtube.com/@SciShowKids or a watch?v= link

    Returns:
        {"channel_id": str, "title": str, "thumb_url": str}
    """
    return resolve_channel_url(url)


@tool
def channel_uploads(channel_id: str, limit: int = 10) -> list[dict]:
    """Newest uploads of a channel from its public RSS feed.

    Args:
        channel_id: YouTube channel id starting with UC
        limit: how many of the most recent videos to return (max 15)

    Returns:
        list of {"id", "channel_id", "title", "published_at", "thumb_url", "description"}
    """
    return fetch_uploads(channel_id, min(limit, 15))


@tool
def video_meta(video_id: str) -> dict:
    """Title, thumbnail, channel and duration (seconds, 0 if unknown) for a video.

    Args:
        video_id: 11-character YouTube video id
    """
    return fetch_video_meta(video_id)
