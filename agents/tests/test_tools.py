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
        def __init__(self, proxy_config=None):
            assert proxy_config is None, "the free, direct path must not go through a paid proxy"

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


# --- the three transcript sources, and the order they are tried in -----------------
#
# The chain exists because the cheap path fails in exactly one place: YouTube
# refuses captions to datacenter addresses, which is where this runs in
# production. These pin that the expensive paths stay asleep until they are
# needed, and that a run is never quietly left with nothing.


@pytest.fixture(autouse=True)
def _fresh_transcript_state(monkeypatch):
    """Both switches are process-wide by design; a test must not inherit them."""
    monkeypatch.setattr(transcript, "_captions_blocked", False)
    monkeypatch.setattr(transcript, "_gemini_until", 0.0)
    monkeypatch.delenv("HEYGILLI_PROXY_URL", raising=False)
    monkeypatch.delenv("WEBSHARE_PROXY_USERNAME", raising=False)


def _blocked(*_args, **_kwargs):
    raise transcript.TranscriptsBlocked("IpBlocked")


def test_captions_win_and_gemini_is_never_called(monkeypatch) -> None:
    """Gemini costs quota; captions cost nothing. Asking Gemini anyway would
    spend a free tier on words YouTube was already giving us."""
    monkeypatch.setattr(transcript, "_from_captions",
                        lambda vid, proxy=None: ([{"start_s": 0, "text": "hi"}], "captions:en:auto"))
    monkeypatch.setattr(transcript, "_from_gemini",
                        lambda vid: pytest.fail("Gemini asked while captions were working"))
    assert transcript.fetch_transcript("vid_caps_ok")["source"] == "captions:en:auto"


def test_gemini_takes_over_when_youtube_blocks_captions(monkeypatch) -> None:
    monkeypatch.setattr(transcript, "_from_captions", _blocked)
    monkeypatch.setattr(transcript, "_from_gemini", lambda vid: [{"start_s": 0, "text": "from gemini"}])
    out = transcript.fetch_transcript("vid_blocked")
    assert out["source"] == "gemini"
    assert out["segments"] == [{"start_s": 0, "text": "from gemini"}]


def test_a_block_stops_us_asking_youtube_again(monkeypatch) -> None:
    """The refusal is about this machine, not this video. Asking once per video
    would spend the whole run collecting the same refusal."""
    asked = []

    def counting(vid, proxy=None):
        asked.append(vid)
        raise transcript.TranscriptsBlocked("IpBlocked")

    monkeypatch.setattr(transcript, "_from_captions", counting)
    monkeypatch.setattr(transcript, "_from_gemini", lambda vid: [{"start_s": 0, "text": "g"}])
    transcript.fetch_transcript("vid_one")
    transcript.fetch_transcript("vid_two")
    assert asked == ["vid_one"], "YouTube was asked again after it had already refused"


def test_proxy_runs_only_after_gemini_is_out_of_quota(monkeypatch) -> None:
    """The proxy is the one path that costs money per request, so it must not
    run while a free one is still answering."""
    used_proxy = []

    def captions(vid, proxy=None):
        if proxy is None:
            raise transcript.TranscriptsBlocked("IpBlocked")
        used_proxy.append(proxy)
        return [{"start_s": 0, "text": "via proxy"}], "captions:en:auto"

    monkeypatch.setenv("HEYGILLI_PROXY_URL", "http://user:pass@proxy:8080")
    monkeypatch.setattr(transcript, "_from_captions", captions)

    monkeypatch.setattr(transcript, "_from_gemini", lambda vid: [{"start_s": 0, "text": "g"}])
    assert transcript.fetch_transcript("vid_gemini_ok")["source"] == "gemini"
    assert used_proxy == [], "paid for a proxy while Gemini still had quota"

    def out_of_quota(vid):
        raise RuntimeError("429 RESOURCE_EXHAUSTED: quota")

    monkeypatch.setattr(transcript, "_from_gemini", out_of_quota)
    assert transcript.fetch_transcript("vid_quota_gone")["source"] == "captions:en:auto"
    assert len(used_proxy) == 1


def test_quota_refusal_stands_gemini_down_but_a_bad_video_does_not(monkeypatch) -> None:
    monkeypatch.setattr(transcript, "_from_captions", _blocked)

    monkeypatch.setattr(transcript, "_from_gemini",
                        lambda vid: (_ for _ in ()).throw(RuntimeError("400 INVALID_ARGUMENT")))
    with pytest.raises(transcript.TranscriptsBlocked):
        transcript.fetch_transcript("vid_bad")
    assert transcript._gemini_ready(), "one unreadable video must not stand Gemini down"

    monkeypatch.setattr(transcript, "_from_gemini",
                        lambda vid: (_ for _ in ()).throw(RuntimeError("429 RESOURCE_EXHAUSTED")))
    with pytest.raises(transcript.TranscriptsBlocked):
        transcript.fetch_transcript("vid_quota")
    assert not transcript._gemini_ready(), "quota was reached and Gemini was asked again anyway"


def test_nothing_left_to_try_raises_rather_than_returning_empty(monkeypatch) -> None:
    """`source: none` means "this video has no captions" and the Curator screens
    on the title. A refusal means "no video will have any", and reporting it as
    the former would screen a whole household on titles and call it a screening."""
    monkeypatch.setattr(transcript, "_from_captions", _blocked)
    monkeypatch.setattr(transcript, "_from_gemini", lambda vid: None)
    with pytest.raises(transcript.TranscriptsBlocked):
        transcript.fetch_transcript("vid_nothing")


def test_a_video_with_no_captions_is_still_just_none(monkeypatch) -> None:
    """Absent is not refused: this one video has no track, the next may."""
    monkeypatch.setattr(transcript, "_from_captions", lambda vid, proxy=None: None)
    monkeypatch.setattr(transcript, "_from_gemini", lambda vid: None)
    assert transcript.fetch_transcript("vid_silent")["source"] == "none"


def test_gemini_retries_a_busy_server_but_not_a_bad_model(monkeypatch) -> None:
    """503 "high demand" is the free tier's normal weather and cost whole runs
    when one was enough to give up. A 404 is not weather and must not be sat on."""
    monkeypatch.setattr(transcript, "GEMINI_ATTEMPTS", 3)
    monkeypatch.setattr(transcript.time, "sleep", lambda s: None)

    calls = []

    def busy_then_fine():
        calls.append(1)
        if len(calls) < 3:
            raise RuntimeError("503 UNAVAILABLE: high demand")
        return "ok"

    assert transcript._with_retries(busy_then_fine, "vid") == "ok"
    assert len(calls) == 3

    tried = []

    def wrong_model():
        tried.append(1)
        raise RuntimeError("404 NOT_FOUND: model is no longer available")

    with pytest.raises(RuntimeError):
        transcript._with_retries(wrong_model, "vid")
    assert tried == [1], "retried a failure that will fail identically every time"

    spent = []

    def out_of_quota():
        spent.append(1)
        raise RuntimeError("429 RESOURCE_EXHAUSTED")

    with pytest.raises(RuntimeError):
        transcript._with_retries(out_of_quota, "vid")
    assert spent == [1], "retrying a quota refusal only spends the cooldown early"


def test_a_live_stream_is_hidden_rather_than_put_to_the_parent() -> None:
    """There is no honest way to screen a stream. The promise is that every
    upload is read against the household's answers before the child sees it,
    and a stream's content has not happened yet — there is nothing to read.

    The Curator handled them the only way it could, by asking, so one channel
    running a 24/7 loop put five identical cards in an inbox and kept adding.
    """
    live = Video(id="a", title="🔴 LIVE! Ben and Holly's Little Kingdom 🔴", duration_s=0)
    out = screening.prescreen(live)
    assert out.verdict == "hide"
    assert "live stream" in out.reason
    # Said plainly enough that a parent reading it knows nothing was judged.
    assert "has not happened yet" in out.reason


def test_live_detection_reads_a_badge_not_the_english_word() -> None:
    """A bare lower-case "live" is ordinary English. Hiding "Where Do Penguins
    Live?" would take a real video off a child's shelf and tell the parent it
    was a stream."""
    for title in (
        "🔴 LIVE! Peppa Pig Full Episodes 🔴",
        "LIVE! Nursery Rhymes 24/7",
        "Bluey live stream",
        "Streaming Now: Number Songs",
        "🟢 LIVE Puppy Cam",
    ):
        assert screening.looks_live(title), title

    for title in (
        "Why Do Giraffes Have Long Necks?",
        "Where Do Penguins Live?",
        "Olive the Other Reindeer",
        "Our lively little puppy",
        "The Alive Song for Kids",
        "Live Action LEGO Adventure",   # a real phrase, and not a stream
        # And shouted, which is how half of YouTube writes a title — this is
        # the case the "live action" guard actually exists for.
        "LIVE ACTION LEGO ADVENTURE",
        "BEST LIVE-ACTION MOMENTS",
        "Deliver the parcel!",
    ):
        assert not screening.looks_live(title), title


def test_a_hidden_stream_never_reaches_the_inbox_or_the_child() -> None:
    """prescreen runs before the model, so a stream costs no model call and
    lands as `hide` — not in the parent's queue, not on the shelf."""
    out = screening.prescreen(Video(id="b", title="LIVE! Kids Cartoons", duration_s=600))
    assert out.verdict == "hide"
    # A normal upload from the same channel is untouched.
    assert screening.prescreen(
        Video(id="c", title="Ben and Holly: The Lost Egg", duration_s=600)
    ).verdict == "pass"


def test_channel_search_needs_a_key_and_says_which_problem_it_hit(monkeypatch) -> None:
    """A setup problem and an empty result look identical to a parent, who
    would retype their query for ever. They are told apart here."""
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("HEYGILLI_YOUTUBE_API_KEY", raising=False)
    with pytest.raises(youtube.SearchUnavailable, match="not set up"):
        youtube.search_channels("peppa pig")

    # An empty query costs no quota: search.list is 100 units a call, and a
    # parent who has typed nothing is not searching yet.
    assert youtube.search_channels("   ") == []


def test_channel_search_reads_channels_out_of_the_response(monkeypatch) -> None:
    # Its own key, preferred over the Gemini one: an AI Studio key is bound to
    # a service account and the YouTube Data API refuses that shape entirely.
    monkeypatch.setenv("GOOGLE_API_KEY", "gemini-key")
    monkeypatch.setenv("HEYGILLI_YOUTUBE_API_KEY", "yt-key")
    seen = {}

    class _Resp:
        status_code = 200

        @staticmethod
        def json():
            return {"items": [
                {"id": {"channelId": "UCabc"},
                 "snippet": {"title": "SciShow &amp; Kids", "description": "science",
                             "thumbnails": {"medium": {"url": "http://img/m.jpg"}}}},
                # A video result has no channelId of its own here; skipped
                # rather than added under an empty id.
                {"id": {"kind": "youtube#video"}, "snippet": {"title": "nope"}},
            ]}

    class _Client:
        def __init__(self, *a, **k): ...
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get(self, url, params=None):
            seen["url"], seen["params"] = url, params
            return _Resp()

    monkeypatch.setattr(youtube.httpx, "Client", _Client)
    out = youtube.search_channels("scishow")

    assert out == [{"channel_id": "UCabc", "title": "SciShow & Kids",
                    "blurb": "science", "thumb_url": "http://img/m.jpg"}]
    assert seen["params"]["type"] == "channel", "videos are not what a parent approves"
    assert seen["params"]["key"] == "yt-key", "the Gemini key cannot search"


def test_a_refused_search_is_raised_not_returned_empty(monkeypatch) -> None:
    monkeypatch.setenv("GOOGLE_API_KEY", "test-key")

    class _Resp:
        status_code = 403

        @staticmethod
        def json():
            return {"error": {"message": "YouTube Data API has not been used..."}}

    class _Client:
        def __init__(self, *a, **k): ...
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get(self, url, params=None): return _Resp()

    monkeypatch.setattr(youtube.httpx, "Client", _Client)
    with pytest.raises(youtube.SearchUnavailable) as e:
        youtube.search_channels("peppa")
    # Google's own words, not just the number: a 401 and a 403 need different
    # things changed by whoever runs the server, and reporting only the status
    # made them look like the same shrug.
    assert "403" in str(e.value)
    assert "daily search limit" in str(e.value)
    assert "YouTube Data API has not been used" in str(e.value)


def test_an_unaccepted_key_is_named_as_such(monkeypatch) -> None:
    monkeypatch.setenv("GOOGLE_API_KEY", "test-key")

    class _Resp:
        status_code = 401

        @staticmethod
        def json():
            return {"error": {"message": "API key not valid."}}

    class _Client:
        def __init__(self, *a, **k): ...
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def get(self, url, params=None): return _Resp()

    monkeypatch.setattr(youtube.httpx, "Client", _Client)
    with pytest.raises(youtube.SearchUnavailable) as e:
        youtube.search_channels("peppa")
    assert "not accepted" in str(e.value) and "API key not valid" in str(e.value)


# --- Why a transcript could not be read ---------------------------------------------------------
#
# This message is the whole account of why a household's videos were screened
# on their titles. It is read by somebody who already knows something is wrong
# and needs to know which of three things to go and fix.


def test_the_reason_names_each_source_once(monkeypatch):
    """A cached captions failure must not be pasted back into its own successor.

    `_why_blocked` takes the captions error and builds a line naming every
    source. The cached error handed to it on later videos is a
    `TranscriptsBlocked` whose text is *already* one of those lines, so the
    result said everything twice — "no transcript source answered — captions:
    no transcript source answered — captions: refused to this machine; gemini:
    ...; proxy: ...; gemini: ...; proxy: ..." — which is what came back the
    first time anyone asked the live gateway.
    """
    from heygilli_agents.tools import transcript as t

    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("HEYGILLI_PROXY_URL", raising=False)
    monkeypatch.delenv("WEBSHARE_PROXY_USERNAME", raising=False)

    first = t.TranscriptsBlocked(t._why_blocked())
    second = t._why_blocked(first)

    assert second.count("captions:") == 1
    assert second.count("gemini:") == 1
    assert second.count("proxy:") == 1


def test_standing_down_says_what_it_stood_down_from(monkeypatch):
    """"Out of quota" was a claim with nothing behind it.

    While the cooldown is running, the reason given for Gemini was the cooldown
    itself, so the provider's own words — the one thing that says whether this
    is really quota, a dead key or a retired model — were dropped exactly when
    somebody was reading the message to find out.
    """
    from heygilli_agents.tools import transcript as t

    monkeypatch.setenv("GOOGLE_API_KEY", "k")
    monkeypatch.setattr(t, "_gemini_until", t.time.monotonic() + 600)
    monkeypatch.setattr(t, "_gemini_last_error", "ClientError: 429 RESOURCE_EXHAUSTED")

    why = t._why_blocked()

    assert "429 RESOURCE_EXHAUSTED" in why


def test_clearing_cooldowns_lets_the_next_call_actually_try(monkeypatch):
    """The debug endpoint's reset, without which it reports the standing-down."""
    from heygilli_agents.tools import transcript as t

    monkeypatch.setattr(t, "_gemini_until", t.time.monotonic() + 600)
    monkeypatch.setattr(t, "_captions_blocked", True)

    t.clear_cooldowns()

    assert t._gemini_ready()
    assert not t._captions_blocked


def test_a_busy_model_is_waited_out_not_given_up_on(monkeypatch):
    """503 "high demand" is a queue, not a wall.

    The free tier answers it often, and the old policy — three attempts, two
    then four seconds — gave up after six seconds inside a background run where
    nobody is waiting on the response. What that bought was a video screened on
    its title, permanently: a successful transcript is cached forever, a failed
    one is simply not retried until the next run.
    """
    from heygilli_agents.tools import transcript as t

    slept: list[float] = []
    monkeypatch.setattr(t.time, "sleep", slept.append)
    calls = {"n": 0}

    def busy_until_the_fifth():
        calls["n"] += 1
        if calls["n"] < 5:
            raise RuntimeError("ServerError: 503 UNAVAILABLE. high demand")
        return "transcript"

    assert t._with_retries(busy_until_the_fifth, "vid") == "transcript"
    assert calls["n"] == 5
    # Backing off, rather than hammering a model that just said it is busy.
    assert slept == [2.0, 4.0, 8.0, 16.0]


def test_a_quota_refusal_is_not_waited_out(monkeypatch):
    """Retrying a 429 spends the cooldown early and gains nothing."""
    from heygilli_agents.tools import transcript as t

    slept: list[float] = []
    monkeypatch.setattr(t.time, "sleep", slept.append)
    calls = {"n": 0}

    def out_of_quota():
        calls["n"] += 1
        raise RuntimeError("ClientError: 429 RESOURCE_EXHAUSTED")

    with pytest.raises(RuntimeError):
        t._with_retries(out_of_quota, "vid")
    assert calls["n"] == 1
    assert slept == []


# --- Reasons a parent is meant to act on --------------------------------------------------------


def test_a_short_video_says_nothing_was_wrong_with_it(monkeypatch):
    """"Too short to hold a question" reads as a verdict on the video.

    A parent seeing it beside an ordinary clip has no way to tell that nothing
    was found wrong with it at all — the only thing wrong was that Gilli would
    have had nothing to ask about afterwards.
    """
    from heygilli_agents.schemas import Video
    from heygilli_agents.tools.screening import prescreen

    result = prescreen(Video(id="v", channel_id="UCx", title="A Short Clip", duration_s=20))

    assert result.verdict == "hide"
    assert "Nothing was found wrong with it" in result.reason
    # And what to do about it, since the parent can overrule this one.
    assert "Allow it" in result.reason


def test_a_long_video_says_it_is_the_length_alone(monkeypatch):
    from heygilli_agents.schemas import Video
    from heygilli_agents.tools.screening import prescreen

    result = prescreen(Video(id="v", channel_id="UCx", title="A Long One", duration_s=4000))

    assert result.verdict == "ask_parent"
    assert "66 minutes" in result.reason
    assert "Nothing was found wrong with it" in result.reason


def test_a_blocked_word_says_whose_rule_it_is(monkeypatch):
    """The household's answers did not cause this one, and saying so matters:
    a parent who reads it as their own setting goes looking for the setting."""
    from heygilli_agents.schemas import Video
    from heygilli_agents.tools.screening import BLOCK_WORDS, prescreen

    result = prescreen(
        Video(id="v", channel_id="UCx", title=f"A {BLOCK_WORDS[0]} video", duration_s=600)
    )

    assert result.verdict == "hide"
    assert "whatever their household said" in result.reason
