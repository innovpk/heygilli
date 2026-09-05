"""Network tools with the network mocked out: YouTube pages/RSS/oEmbed and captions."""
from __future__ import annotations

import pytest

from heygilli_agents.schemas import Video
from heygilli_agents.tools import screening, transcript, youtube
from heygilli_agents.tools.tts import synthesize

CHANNEL_ID = "UCRFIPG2u1DxKLNuE3y2SjHA"
WATCH_PAGE = (
    f'<html><meta property="og:title" content="Giraffes!"><meta property="og:image" content="http://img/t.jpg">'
    f'"channelId":"{CHANNEL_ID}" "ownerChannelName":"SciShow Kids" "lengthSeconds":"612"</html>'
)
CHANNEL_PAGE = (
    f'<html><meta property="og:title" content="SciShow Kids"> "externalId":"{CHANNEL_ID}"'
    f' "avatar":{{"thumbnails":[{{"url":"http://img/a.jpg"}}]}}</html>'
)
RSS = """<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015"
      xmlns:media="http://search.yahoo.com/mrss/">
  <entry><yt:videoId>abcdefghijk</yt:videoId><title>Why Do Giraffes Have Long Necks?</title>
    <published>2026-09-01T10:00:00+00:00</published>
    <media:group><media:thumbnail url="http://img/1.jpg"/><media:description>Learn about giraffes.</media:description></media:group>
  </entry>
  <entry><yt:videoId>lmnopqrstuv</yt:videoId><title>Scary 3AM Prank</title><published>2026-09-02T10:00:00+00:00</published>
    <media:group><media:thumbnail url="http://img/2.jpg"/><media:description>boo</media:description></media:group>
  </entry>
</feed>"""


@pytest.fixture
def fake_pages(monkeypatch: pytest.MonkeyPatch) -> dict[str, str]:
    pages = {
        "https://www.youtube.com/@SciShowKids": CHANNEL_PAGE,
        f"https://www.youtube.com/channel/{CHANNEL_ID}": CHANNEL_PAGE,
        "https://www.youtube.com/watch?v=abcdefghijk": WATCH_PAGE,
        f"https://www.youtube.com/feeds/videos.xml?channel_id={CHANNEL_ID}": RSS,
    }
    calls: list[str] = []

    def _get(url: str, timeout: float = 15.0) -> str:
        calls.append(url)
        return pages[url]

    monkeypatch.setattr(youtube, "_get", _get)
    pages["_calls"] = calls  # type: ignore[assignment]
    return pages


def test_video_id_from_url() -> None:
    assert youtube.video_id_from_url("https://youtu.be/abcdefghijk?t=3") == "abcdefghijk"
    assert youtube.video_id_from_url("https://www.youtube.com/watch?v=abcdefghijk") == "abcdefghijk"
    assert youtube.video_id_from_url("https://www.youtube.com/@SciShowKids") is None


def test_resolve_channel_url_variants_and_cache(fake_pages) -> None:
    out = youtube.resolve_channel_url("@SciShowKids")
    assert out == {"channel_id": CHANNEL_ID, "title": "SciShow Kids", "thumb_url": "http://img/a.jpg"}
    assert youtube.resolve_channel_url(CHANNEL_ID)["channel_id"] == CHANNEL_ID
    via_video = youtube.resolve_channel_url("https://www.youtube.com/watch?v=abcdefghijk")
    assert via_video["channel_id"] == CHANNEL_ID and via_video["title"] == "SciShow Kids"
    n = len(fake_pages["_calls"])
    youtube.resolve_channel_url("@SciShowKids")  # cached: no new fetch
    assert len(fake_pages["_calls"]) == n


def test_fetch_uploads_parses_rss(fake_pages) -> None:
    ups = youtube.fetch_uploads(CHANNEL_ID, limit=5)
    assert [u["id"] for u in ups] == ["abcdefghijk", "lmnopqrstuv"]
    assert ups[0]["title"].startswith("Why Do Giraffes") and ups[0]["thumb_url"] == "http://img/1.jpg"
    assert youtube.channel_uploads(CHANNEL_ID, 1)[0]["id"] == "abcdefghijk"


def test_fetch_video_meta(fake_pages, monkeypatch) -> None:
    class FakeResp:
        status_code = 200

        @staticmethod
        def json() -> dict:
            return {"title": "Giraffes!", "thumbnail_url": "http://img/t.jpg"}

    class FakeClient:
        def __init__(self, *a, **k): ...
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get(self, url, params=None): return FakeResp()

    monkeypatch.setattr(youtube.httpx, "Client", FakeClient)
    meta = youtube.fetch_video_meta("abcdefghijk")
    assert meta == {"id": "abcdefghijk", "title": "Giraffes!", "thumb_url": "http://img/t.jpg",
                    "channel_id": CHANNEL_ID, "duration_s": 612}
    assert youtube.video_meta("abcdefghijk") == meta  # cached


def test_prescreen_rules() -> None:
    assert screening.prescreen(Video(id="a", title="Scary 3AM Prank", duration_s=300)).verdict == "hide"
    assert screening.prescreen(Video(id="b", title="Slime challenge", duration_s=300)).verdict == "ask_parent"
    assert screening.prescreen(Video(id="c", title="Giraffes", duration_s=50 * 60)).verdict == "ask_parent"
    assert screening.prescreen(Video(id="d", title="Giraffes", duration_s=20)).verdict == "hide"
    assert screening.prescreen(Video(id="e", title="Giraffes", duration_s=600)).verdict == "pass"
    assert screening.prescreen(Video(id="f", title="Addition for kids", duration_s=600)).verdict == "pass"  # "ad " needs a boundary
    assert screening.screen_video("Horror night")["verdict"] == "hide"


class _Seg:
    def __init__(self, start: float, text: str) -> None:
        self.start, self.text = start, text


class _Track:
    language_code = "en"
    is_generated = False

    def fetch(self):
        return [_Seg(0.5, "Hello giraffes"), _Seg(31.2, "They eat\nleaves")]


class _List(list):
    def find_manually_created_transcript(self, langs):
        return _Track()

    def find_generated_transcript(self, langs):
        raise AssertionError("manual track should win")


def test_transcript_from_captions_and_cache(monkeypatch, store) -> None:
    import youtube_transcript_api

    class FakeApi:
        def list(self, video_id):
            return _List()

    monkeypatch.setattr(youtube_transcript_api, "YouTubeTranscriptApi", FakeApi)
    out = transcript.fetch_transcript("abcdefghijk")
    assert out["source"] == "captions:en:manual"
    assert out["segments"] == [{"start_s": 0, "text": "Hello giraffes"}, {"start_s": 31, "text": "They eat leaves"}]
    monkeypatch.setattr(transcript, "_from_captions", lambda vid: (_ for _ in ()).throw(AssertionError("cached")))
    assert transcript.get_transcript("abcdefghijk") == out
    assert "[0:31] They eat leaves" in transcript.transcript_text(out["segments"])
    assert transcript.transcript_text(out["segments"], max_chars=10).endswith("[...truncated]")


def test_transcript_none_is_not_cached_forever(monkeypatch) -> None:
    monkeypatch.setattr(transcript, "_from_captions", lambda vid: None)
    assert transcript.fetch_transcript("zzzzzzzzzzz")["source"] == "none"
    monkeypatch.setattr(transcript, "_from_captions", lambda vid: ([{"start_s": 1, "text": "hi"}], "captions:en:auto"))
    assert transcript.fetch_transcript("zzzzzzzzzzz")["source"] == "captions:en:auto"  # retried


def test_tts_off_and_urdu_return_empty_url() -> None:
    assert synthesize("Hello", "en") == ""  # HEYGILLI_TTS=off in tests
    assert synthesize("سلام", "ur") == ""
    assert synthesize("   ", "en") == ""
