"""YouTube metadata without an API key: page HTML, the public RSS feed, and oEmbed.

Everything is cached in the store so the Curator can run every few hours
without re-fetching. If YOUTUBE_API_KEY ever exists this is the one module to
swap for the Data API (SPEC §9.4).
"""
from __future__ import annotations

import html
import logging
import re
import xml.etree.ElementTree as ET
from collections.abc import Sequence

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


# --- Data API v3: the parent's own subscriptions (needs an OAuth access token) -------------
#
# The only part of this module that talks to the official API. It runs on the
# parent's `youtube.readonly` grant (see google_auth.py), not on an API key.

SUBSCRIPTIONS_URL = "https://www.googleapis.com/youtube/v3/subscriptions"
SUBSCRIPTIONS_PAGE_SIZE = 50  # the API maximum, and 1 quota unit per page
MAX_SUBSCRIPTION_PAGES = 10  # 500 channels is far past any real parent; 10 units worst case


def _api_get(url: str, params: dict[str, str | int], access_token: str, timeout: float = 20.0) -> dict:
    """One authenticated Data API call. The token travels in the header, never
    in the query string, and is never logged."""
    with httpx.Client(timeout=timeout) as c:
        r = c.get(url, params=params, headers={"Authorization": f"Bearer {access_token}"})
    r.raise_for_status()
    body = r.json()
    return body if isinstance(body, dict) else {}


def _best_thumb(snippet: dict) -> str:
    thumbs = snippet.get("thumbnails") or {}
    for size in ("medium", "high", "default"):
        url = (thumbs.get(size) or {}).get("url")
        if url:
            return str(url)
    return ""


def list_subscriptions(access_token: str, max_pages: int = MAX_SUBSCRIPTION_PAGES) -> list[dict]:
    """Every channel the signed-in Google account subscribes to.

    `subscriptions.list(part=snippet, mine=true)`, 50 per page, following
    `nextPageToken` up to `max_pages`. Returns
    `[{"channel_id", "title", "thumb_url"}]`, deduped and alphabetical.

    The channel id is `snippet.resourceId.channelId` — the channel subscribed
    *to*. `snippet.channelId` is the *subscriber's* own channel and is the same
    value on every row; reading that one is the classic bug here, so
    `tests/test_google_auth.py` pins it.
    """
    out: list[dict] = []
    seen: set[str] = set()
    page_token: str | None = None

    for _ in range(max(1, max_pages)):
        params: dict[str, str | int] = {
            "part": "snippet",
            "mine": "true",
            "maxResults": SUBSCRIPTIONS_PAGE_SIZE,
            "order": "alphabetical",
        }
        if page_token:
            params["pageToken"] = page_token
        body = _api_get(SUBSCRIPTIONS_URL, params, access_token)

        for item in body.get("items") or []:
            snippet = item.get("snippet") or {}
            channel_id = str((snippet.get("resourceId") or {}).get("channelId") or "").strip()
            if not channel_id or channel_id in seen:
                continue
            seen.add(channel_id)
            out.append(
                {
                    "channel_id": channel_id,
                    "title": str(snippet.get("title") or "").strip(),
                    "thumb_url": _best_thumb(snippet),
                }
            )

        page_token = body.get("nextPageToken")
        if not page_token:
            break
    else:
        log.warning("subscription list truncated at %d pages", max_pages)

    out.sort(key=lambda s: (s["title"].casefold(), s["channel_id"]))
    return out


VIDEOS_URL = "https://www.googleapis.com/youtube/v3/videos"
DURATION_BATCH = 50  # the API's cap on ids per call, and 1 quota unit per call


def _iso8601_seconds(text: str) -> int:
    """"PT1H2M3S" -> 3723. 0 for anything unparseable, which means "unknown"."""
    m = re.fullmatch(r"P(?:\d+D)?T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?", text or "")
    if not m:
        return 0
    h, mi, sec = (int(g) if g else 0 for g in m.groups())
    return h * 3600 + mi * 60 + sec


def fetch_durations(video_ids: Sequence[str], access_token: str) -> dict[str, int]:
    """`{video_id: seconds}` for as many as the API answered for.

    The watch page carries this too and is where it used to come from, but
    YouTube serves that page only to addresses it likes and refuses it from
    every datacenter — so in production every video had duration 0. That is not
    a cosmetic gap: a parent's "longest video" limit is applied by comparing
    against it, so the limit silently allowed everything, and an end-of-video
    question is scheduled at `duration - 3`, which became "the moment it
    starts".

    `videos.list(part=contentDetails)` is inside the youtube.readonly grant the
    parent has already given, is one quota unit per 50 ids, and answers from
    anywhere. A household with no Google link has no token and gets `{}`; the
    caller must treat a missing id as unknown, not as zero-length.
    """
    ids = [v for v in dict.fromkeys(video_ids) if v]
    out: dict[str, int] = {}
    for i in range(0, len(ids), DURATION_BATCH):
        batch = ids[i:i + DURATION_BATCH]
        try:
            body = _api_get(
                VIDEOS_URL,
                {"part": "contentDetails", "id": ",".join(batch)},
                access_token,
            )
        except Exception as e:  # noqa: BLE001 - unknown duration is a supported state
            log.warning("duration lookup failed for %d ids: %s", len(batch), e)
            continue
        for item in body.get("items") or []:
            seconds = _iso8601_seconds((item.get("contentDetails") or {}).get("duration") or "")
            if seconds:
                out[str(item.get("id") or "")] = seconds
    return out


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
