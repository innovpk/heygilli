"""Scripted REST + WebSocket session against gateway.py (docs/PROTOCOL.md), offline."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.schemas import Option, Question, QuestionPlan, Video
from heygilli_agents.store import LocalStore

VIDEO = Video(id="vid00000001", channel_id="UCx", title="Why Ice Melts", duration_s=900, thumb_url="t")


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    r = client.post("/auth/dev", json={"name": "Test Parent"})
    assert r.status_code == 200
    body = r.json()
    assert body["token"].startswith(body["household_id"] + ".")
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def test_auth_required_and_verified(client: TestClient) -> None:
    assert client.get("/kids").status_code == 401
    assert client.get("/kids", headers={"Authorization": "Bearer hh_x.deadbeef"}).status_code == 401
    assert client.get("/healthz").json()["ok"] is True


def test_kids_channels_home(client: TestClient, auth: dict, store: LocalStore, monkeypatch) -> None:
    r = client.post("/kids", json={"nickname": "Zara", "age": 8, "languages": ["en", "ur"]}, headers=hdr(auth))
    assert r.status_code == 200
    kid = r.json()
    assert kid["age_band"] == "7_8" and set(kid) >= {"id", "nickname", "age", "age_band", "languages", "avatar"}
    assert [k["id"] for k in client.get("/kids", headers=hdr(auth)).json()] == [kid["id"]]

    monkeypatch.setattr(gateway, "resolve_channel_url",
                        lambda url: {"channel_id": "UCx", "title": "SciShow Kids", "thumb_url": "th"})
    r = client.post(f"/kids/{kid['id']}/channels", json={"url": "https://www.youtube.com/@SciShowKids"}, headers=hdr(auth))
    assert r.json() == {"id": "UCx", "title": "SciShow Kids", "thumb_url": "th", "approved": True, "last_checked": None}
    assert client.get(f"/kids/{kid['id']}/channels", headers=hdr(auth)).json()[0]["id"] == "UCx"

    monkeypatch.setattr(gateway, "resolve_channel_url", lambda url: (_ for _ in ()).throw(ValueError("nope")))
    assert client.post(f"/kids/{kid['id']}/channels", json={"url": "junk"}, headers=hdr(auth)).status_code == 400

    home = client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()
    assert home == {
        "rows": [{"title": "New for you", "videos": []}],
        # Off unless a parent turned it on for this child.
        "searchable": False,
        # Nothing is being let past a limit this household has not set.
        "unknown_length": 0,
        "watching_allowed": True, "blocked_reason": None, "active_break": None,
    }
    store.put_video(VIDEO)
    store.set_kid_video(auth["_hid"], kid["id"], VIDEO.id, "approve", "ok")
    store.set_kid_video(auth["_hid"], kid["id"], "hiddenvid01", "hide", "no")
    home = client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()
    vids = home["rows"][0]["videos"]
    assert [v["id"] for v in vids] == [VIDEO.id]
    assert vids[0]["plan_ready"] is False and "description" not in vids[0]

    assert client.get("/kids/nope/home", headers=hdr(auth)).status_code == 404


def _plan_7_8() -> QuestionPlan:
    return QuestionPlan(video_id=VIDEO.id, age_band="7_8", language="en", questions=[
        Question(t_sec=100, type="why", input="voice", text="Why did the ice melt?", expected="the sun warmed it",
                 variants=["it got hot"], followup="Ice melts at zero degrees.", gesture="think"),
        Question(t_sec=400, type="predict", input="voice", text="What happens next?", expected="it refreezes"),
    ])


def test_full_session_over_websocket(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8, "languages": ["en"]}, headers=hdr(auth)).json()
    store.put_video(VIDEO)
    store.put_plan(_plan_7_8())

    r = client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id, "device": "tv"}, headers=hdr(auth))
    assert r.status_code == 200
    body = r.json()
    assert body["plan_ready"] is True and body["video"]["id"] == VIDEO.id
    sid = body["session_id"]
    token = auth["Authorization"].split()[1]

    with client.websocket_connect(f"/sessions/{sid}/ws?token={token}") as ws:
        ws.send_json({"t": "hello"})
        ready = ws.receive_json()
        assert ready == {"t": "ready", "plan_questions": 2, "age_band": "7_8", "language": "en"}

        ws.send_json({"t": "position", "seconds": 50})
        ws.send_json({"t": "position", "seconds": 99.5})
        ws.send_json({"t": "position", "seconds": 100.2})
        assert ws.receive_json() == {"t": "pause"}
        ask = ws.receive_json()
        assert ask["t"] == "ask" and ask["q"] == 0 and ask["type"] == "why" and ask["input"] == "voice"
        assert ask["text"] == "Why did the ice melt?" and ask["listen_ms"] == 8000
        assert ask["tts_url"] == "" and ask["gesture"] == "think" and "options" not in ask

        ws.send_json({"t": "position", "seconds": 100.5})  # a stray tick while paused is ignored
        ws.send_json({"t": "answer", "q": 0, "input": "voice", "transcript": "because the sun warmed it up"})
        reply = ws.receive_json()
        assert reply["t"] == "reply" and reply["result"] == "correct" and reply["gesture"] == "cheer"
        assert reply["text"] and reply["tts_url"] == "" and "model_word" not in reply
        assert ws.receive_json() == {"t": "resume"}
        ws.send_json({"t": "resumed"})

        ws.send_json({"t": "position", "seconds": 401})
        assert ws.receive_json() == {"t": "pause"}
        ask2 = ws.receive_json()
        assert ask2["q"] == 1 and ask2["type"] == "predict"
        ws.send_json({"t": "answer", "q": 1, "input": "none"})
        reply2 = ws.receive_json()
        assert reply2["result"] == "silence" and "No worries" in reply2["text"]
        assert ws.receive_json() == {"t": "resume"}

        ws.send_json({"t": "position", "seconds": 890})  # nothing left to ask
        ws.send_json({"t": "bye"})
        end = ws.receive_json()
        assert end["t"] == "end" and end["words_said"] == [] and "summary_tts_url" in end

    answers = store.list_answers(auth["_hid"], sid)
    assert [a.result for a in answers] == ["correct", "silence"]
    assert all("because the sun" not in a.paraphrase or len(a.paraphrase.split()) <= 10 for a in answers)
    session = store.get_session(auth["_hid"], sid)
    assert session.watched_sec == 890 and session.ended_at

    assert client.post(f"/sessions/{sid}/end", headers=hdr(auth)).json() == {"ok": True}
    assert client.post("/sessions/nope/end", headers=hdr(auth)).status_code == 404


def test_prereader_session_pick_flow(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = client.post("/kids", json={"nickname": "Ayaan", "age": 5}, headers=hdr(auth)).json()
    store.put_video(VIDEO)
    store.put_plan(QuestionPlan(video_id=VIDEO.id, age_band="4_6", language="en", questions=[
        Question(t_sec=130, type="pick_it", input="pick", text="Show me the red one.", expected="red",
                 options=[Option(icon_id="icon_red", label="red", correct=True),
                          Option(icon_id="icon_fish", label="fish"), Option(icon_id="icon_car", label="car")]),
    ]))
    sid = client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id}, headers=hdr(auth)).json()["session_id"]
    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:  # no token: dev lookup by session id
        ws.send_json({"t": "hello"})
        assert ws.receive_json()["age_band"] == "4_6"
        ws.send_json({"t": "position", "seconds": 131})
        assert ws.receive_json()["t"] == "pause"
        ask = ws.receive_json()
        assert "text" not in ask  # pre-readers get no text
        assert [o["icon_id"] for o in ask["options"]] == ["icon_red", "icon_fish", "icon_car"]
        assert ask["listen_ms"] == 5000
        ws.send_json({"t": "answer", "q": 0, "input": "pick", "option": 1})
        reply = ws.receive_json()
        assert reply["result"] == "off_topic" and reply["model_word"] == "red" and "text" not in reply
        assert ws.receive_json() == {"t": "resume"}
        ws.send_json({"t": "bye"})
        assert ws.receive_json()["t"] == "end"


def test_unknown_session_and_bad_first_message(client: TestClient) -> None:
    with client.websocket_connect("/sessions/ses_nope/ws") as ws:
        ws.send_json({"t": "hello"})
        assert ws.receive_json() == {"t": "error", "message": "unknown session"}


def test_session_without_plan_schedules_background_planning(client: TestClient, auth: dict, store: LocalStore, monkeypatch) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 10}, headers=hdr(auth)).json()
    store.put_video(VIDEO)
    planned: list[tuple] = []
    monkeypatch.setattr(gateway, "ensure_plan", lambda v, b, lang: planned.append((v.id, b, lang)))
    r = client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id}, headers=hdr(auth)).json()
    assert r["plan_ready"] is False
    assert planned == [(VIDEO.id, "9_11", "en")]  # TestClient runs background tasks inline


def test_digest_and_inbox_endpoints(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    d = client.get(f"/kids/{kid['id']}/digest?date=2026-09-05", headers=hdr(auth)).json()
    assert d["kid_id"] == kid["id"] and d["asked"] == 0 and d["kind"] == "older"
    assert client.get("/parent/inbox", headers=hdr(auth)).json() == []
    assert client.post("/parent/inbox/nope", json={"decision": "hide"}, headers=hdr(auth)).status_code == 404


# --- search, and the line it must never cross ---------------------------------------------------


def test_search_is_off_until_a_parent_turns_it_on(client: TestClient, auth: dict, store) -> None:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    store.put_video(VIDEO)
    store.set_kid_video(auth["_hid"], kid["id"], VIDEO.id, "approve", "ok")

    # A query from a child whose parent has not enabled it changes nothing.
    home = client.get(f"/kids/{kid['id']}/home?q=zzzznotmatching", headers=hdr(auth)).json()
    assert home["searchable"] is False
    assert home["rows"][0]["title"] == "New for you"
    assert [v["id"] for v in home["rows"][0]["videos"]] == [VIDEO.id]


def test_a_parent_can_turn_it_on_and_it_filters_their_own_shelf(
    client: TestClient, auth: dict, store
) -> None:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    store.put_video(VIDEO)
    store.set_kid_video(auth["_hid"], kid["id"], VIDEO.id, "approve", "ok")

    r = client.patch(f"/kids/{kid['id']}/limits", json={"search_enabled": True}, headers=hdr(auth))
    assert r.status_code == 200 and r.json()["search_enabled"] is True

    hit = client.get(f"/kids/{kid['id']}/home?q={VIDEO.title[:6]}", headers=hdr(auth)).json()
    assert hit["searchable"] is True
    assert [v["id"] for v in hit["rows"][0]["videos"]] == [VIDEO.id]

    miss = client.get(f"/kids/{kid['id']}/home?q=dinosaurs-in-space", headers=hdr(auth)).json()
    assert miss["rows"][0]["videos"] == [], "search reached past the approved list"


def test_search_can_only_ever_return_approved_videos(
    client: TestClient, auth: dict, store
) -> None:
    """The whole safety premise. A search box that could return anything would
    undo the allowlist, so the one that exists filters what is already there:
    a video the Curator hid stays hidden however hard a child searches for it.
    """
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    client.patch(f"/kids/{kid['id']}/limits", json={"search_enabled": True}, headers=hdr(auth))
    store.put_video(VIDEO)
    store.set_kid_video(auth["_hid"], kid["id"], VIDEO.id, "hide", "not for this age")

    home = client.get(f"/kids/{kid['id']}/home?q={VIDEO.title}", headers=hdr(auth)).json()
    assert home["rows"][0]["videos"] == []


def test_a_client_line_gets_the_same_voice_as_a_session_line(
    client: TestClient, auth: dict, monkeypatch
) -> None:
    """Screens composed on the device were falling back to on-device TTS, which
    in a browser is the OS robot voice — the first thing anyone notices."""
    seen: dict = {}

    def fake(text: str, language: str = "en", slow: bool = False) -> str:
        seen.update(text=text, language=language, slow=slow)
        return "/tts/abc123.mp3"

    monkeypatch.setattr(gateway, "synthesize", fake)
    r = client.post(
        "/tts", json={"text": "Nothing to watch yet.", "slow": True}, headers=hdr(auth)
    )
    assert r.status_code == 200 and r.json() == {"url": "/tts/abc123.mp3"}
    assert seen == {"text": "Nothing to watch yet.", "language": "en", "slow": True}


def test_no_voice_is_an_empty_url_not_a_failure(
    client: TestClient, auth: dict, monkeypatch
) -> None:
    # Polly being down must never silence a screen: the client speaks it itself.
    monkeypatch.setattr(gateway, "synthesize", lambda *a, **k: "")
    r = client.post("/tts", json={"text": "All done for today."}, headers=hdr(auth))
    assert r.status_code == 200 and r.json() == {"url": ""}


def test_a_wall_of_text_is_refused_before_it_reaches_polly(
    client: TestClient, auth: dict, monkeypatch
) -> None:
    called = []
    monkeypatch.setattr(gateway, "synthesize", lambda *a, **k: called.append(1) or "")
    r = client.post("/tts", json={"text": "x" * 5000}, headers=hdr(auth))
    assert r.status_code == 422
    assert called == [], "a 5000-character request reached Polly"


def test_speech_needs_a_household(client: TestClient) -> None:
    assert client.post("/tts", json={"text": "hello"}).status_code == 401


def test_healthz_reports_which_transcript_sources_exist(client, monkeypatch) -> None:
    """An undeployed build and a deployed one that cannot read a transcript both
    show up as an empty kid home. This is what tells them apart."""
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    monkeypatch.delenv("HEYGILLI_PROXY_URL", raising=False)
    monkeypatch.delenv("WEBSHARE_PROXY_USERNAME", raising=False)
    body = client.get("/healthz").json()
    assert body["ok"] is True
    assert body["transcripts"] == {"gemini": False, "proxy": False}

    monkeypatch.setenv("HEYGILLI_PROXY_URL", "http://user:pass@proxy:8080")
    body = client.get("/healthz").json()
    assert body["transcripts"]["proxy"] is True
    assert "pass" not in str(body), "a proxy password must never leave the server"


def test_healthz_says_which_key_search_would_use(client, monkeypatch) -> None:
    """A missing dedicated key and a rejected one both come back from YouTube
    as the same 401, because the fallback quietly reaches for the Gemini key —
    which cannot search. From outside the server they are indistinguishable."""
    monkeypatch.delenv("HEYGILLI_YOUTUBE_API_KEY", raising=False)
    monkeypatch.delenv("GOOGLE_API_KEY", raising=False)
    assert client.get("/healthz").json()["search_key"] == "none"

    monkeypatch.setenv("GOOGLE_API_KEY", "gemini-secret-value")
    body = client.get("/healthz").json()
    assert body["search_key"] == "google-fallback"

    monkeypatch.setenv("HEYGILLI_YOUTUBE_API_KEY", "youtube-secret-value")
    body = client.get("/healthz").json()
    assert body["search_key"] == "youtube"
    # Names only, never a key.
    assert "secret-value" not in str(body)


def test_adding_one_channel_screens_it_like_an_import_does(client, auth, monkeypatch) -> None:
    """A pasted channel used to be added and then never looked at: only the
    bulk import triggered the Curator, so a parent who added channels one at a
    time was told it worked and got an empty home for ever."""
    curated: list[str] = []
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: curated.append(kid.id))
    monkeypatch.setattr(
        gateway, "resolve_channel_url",
        lambda url: {"channel_id": "UCpasted", "title": "SciShow Kids", "thumb_url": ""},
    )
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()

    r = client.post(f"/kids/{kid['id']}/channels", json={"url": "@SciShowKids"}, headers=hdr(auth))
    assert r.status_code == 200 and r.json()["id"] == "UCpasted"
    assert curated == [kid["id"]], "the channel was added but never screened"


def test_a_household_can_ask_for_screening_again(client, auth, monkeypatch) -> None:
    """Curation ran only on import, so a run that came back with nothing —
    transcripts unreadable, the model briefly down — left the home empty with
    nothing the parent could press."""
    curated: list[str] = []
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: curated.append(kid.id))
    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()

    assert client.post(f"/kids/{kid['id']}/curate", headers=hdr(auth)).json() == {"started": True}
    assert curated == [kid["id"]]
    assert client.post("/kids/kid_nosuch/curate", headers=hdr(auth)).status_code == 404


def test_a_kid_s_age_can_be_corrected_and_the_band_follows(client, auth) -> None:
    """There was no way to change a child's age at all — no endpoint, no
    delete, so one typed wrong was wrong for ever. Age is not cosmetic: it
    picks the band the Curator screens against and decides whether the child
    is read to or shown text."""
    kid = client.post("/kids", json={"nickname": "Abeeha", "age": 5}, headers=hdr(auth)).json()
    assert kid["age_band"] == "4_6"

    r = client.patch(f"/kids/{kid['id']}", json={"age": 9}, headers=hdr(auth))
    assert r.status_code == 200
    assert r.json()["age"] == 9
    assert r.json()["age_band"] == "9_11", "the old band would screen a 9-year-old as a pre-reader"
    assert r.json()["nickname"] == "Abeeha", "an edit is a correction, not a re-registration"

    # Limits and everything else a parent set survive the correction.
    client.patch(f"/kids/{kid['id']}/limits", json={"max_video_minutes": 20}, headers=hdr(auth))
    client.patch(f"/kids/{kid['id']}", json={"nickname": "Abee"}, headers=hdr(auth))
    after = client.get("/kids", headers=hdr(auth)).json()[0]
    assert after["nickname"] == "Abee" and after["max_video_minutes"] == 20
    assert after["age"] == 9, "a name change must not reset the age"

    assert client.patch("/kids/kid_nosuch", json={"age": 7}, headers=hdr(auth)).status_code == 404
    assert client.patch(f"/kids/{kid['id']}", json={"age": 99}, headers=hdr(auth)).status_code == 422


def test_a_length_limit_is_not_passed_by_a_video_of_unknown_length(client, auth, store) -> None:
    """A parent set "longest video: 20 minutes" and was offered thirty.

    Duration used to come only from the YouTube watch page, which is refused to
    datacenter addresses, so in production every video was stored with 0. Zero
    was then compared as a number — 0 > 1200 is false — so an unmeasured video
    passed a limit it had never been measured against.
    """
    kid = client.post("/kids", json={"nickname": "Abeeha", "age": 5}, headers=hdr(auth)).json()
    hid = auth["_hid"]
    for vid, secs in (("shortvideo1", 600), ("longvideo01", 1800), ("unknownvid1", 0)):
        store.put_video(Video(id=vid, title=vid, duration_s=secs))
        store.set_kid_video(hid, kid["id"], vid, "approve", "test")

    # No limit set: length is not a reason to withhold anything.
    ids = {v["id"] for r in client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()["rows"]
           for v in r["videos"]}
    assert ids == {"shortvideo1", "longvideo01", "unknownvid1"}

    client.patch(f"/kids/{kid['id']}/limits", json={"max_video_minutes": 20}, headers=hdr(auth))
    home = client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()
    ids = {v["id"] for r in home["rows"] for v in r["videos"]}
    assert "longvideo01" not in ids, "thirty minutes was offered under a twenty minute limit"

    # An unmeasured video is still offered. Withholding it emptied the shelf
    # entirely: a household with no Google grant cannot learn a single length,
    # so the child was left with nothing — a worse answer to "this might be
    # long" than showing it. It is counted instead, so the parent can be told
    # the limit is not being kept rather than finding out from a blank screen.
    assert "unknownvid1" in ids
    assert home["unknown_length"] == 1
    assert ids == {"shortvideo1", "unknownvid1"}

    # With no limit set nothing is being let past, so there is nothing to warn
    # about: the count is about a promise that cannot be kept, not about
    # missing metadata.
    client.patch(f"/kids/{kid['id']}/limits", json={"max_video_minutes": 0}, headers=hdr(auth))
    assert client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()["unknown_length"] == 0


def test_the_prompt_list_follows_the_child_s_age(client, auth) -> None:
    """The bank is graded, not labelled: correcting a child's age must change
    what they are asked, or the grading is decoration."""
    kid = client.post("/kids", json={"nickname": "Abeeha", "age": 5}, headers=hdr(auth)).json()

    young = client.get(f"/kids/{kid['id']}/prompts", headers=hdr(auth)).json()
    assert young["age_band"] == "4_6"
    assert all(p["enabled"] for p in young["prompts"]), "on by default, or setup is a chore"
    assert all(p["input"] in ("voice", "copy") for p in young["prompts"])

    client.patch(f"/kids/{kid['id']}", json={"age": 10}, headers=hdr(auth))
    older = client.get(f"/kids/{kid['id']}/prompts", headers=hdr(auth)).json()
    assert older["age_band"] == "9_11"
    assert {p["id"] for p in older["prompts"]}.isdisjoint({p["id"] for p in young["prompts"]})


def test_a_parent_turning_a_prompt_off_is_remembered(client, auth) -> None:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()

    r = client.put(f"/kids/{kid['id']}/prompts", json={"disabled": ["p46_clap"]}, headers=hdr(auth))
    assert r.status_code == 200
    off = {p["id"] for p in r.json()["prompts"] if not p["enabled"]}
    assert off == {"p46_clap"}

    # It survives a reread, and an unknown id is kept rather than rejected:
    # a household outlives any one release of the bank.
    client.put(f"/kids/{kid['id']}/prompts",
               json={"disabled": ["p46_clap", "p46_from_a_future_release"]}, headers=hdr(auth))
    again = client.get(f"/kids/{kid['id']}/prompts", headers=hdr(auth)).json()
    assert {p["id"] for p in again["prompts"] if not p["enabled"]} == {"p46_clap"}

    # Turning everything back on is a real instruction, not an empty request.
    client.put(f"/kids/{kid['id']}/prompts", json={"disabled": []}, headers=hdr(auth))
    assert all(p["enabled"] for p in client.get(f"/kids/{kid['id']}/prompts", headers=hdr(auth)).json()["prompts"])


def test_a_child_may_wear_only_a_face_the_server_knows(client, auth) -> None:
    """The avatar is rendered as an asset path, and this is the one field a
    *child* chooses rather than the parent, so it is checked against the list
    rather than taken as given."""
    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()
    assert kid["avatar"] in ("", "gilli")

    ok = client.patch(f"/kids/{kid['id']}", json={"avatar": "frog"}, headers=hdr(auth))
    assert ok.status_code == 200 and ok.json()["avatar"] == "frog"

    bad = client.patch(f"/kids/{kid['id']}", json={"avatar": "../../etc/passwd"}, headers=hdr(auth))
    assert bad.status_code == 422
    assert client.get("/kids", headers=hdr(auth)).json()[0]["avatar"] == "frog", "the rejected value must not have landed"

    # Every offered face is one the server will actually accept.
    for name in client.get("/avatars").json()["avatars"]:
        assert client.patch(f"/kids/{kid['id']}", json={"avatar": name},
                            headers=hdr(auth)).status_code == 200

    # And going back to their initial is allowed.
    assert client.patch(f"/kids/{kid['id']}", json={"avatar": ""},
                        headers=hdr(auth)).status_code == 200


def test_the_inbox_names_the_channel_each_video_came_from(client, auth, store) -> None:
    """A parent working through the inbox is mostly deciding about a channel,
    not about videos one at a time: several borderline uploads in a row are
    usually the same channel and get the same answer. The video carries a
    channel id and nothing a person can read."""
    from heygilli_agents.schemas import Channel, ParentPrompt

    hid = auth["_hid"]
    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()
    store.put_channel(hid, kid["id"], Channel(id="UCnamed", title="SciShow Kids", approved=True))
    store.put_channel(hid, kid["id"], Channel(id="UCnameless", title="", approved=True))

    for vid, channel in (("v_named___", "UCnamed"), ("v_nameless_", "UCnameless")):
        store.put_video(Video(id=vid, title=vid, channel_id=channel, duration_s=600))
        store.put_parent_prompt(ParentPrompt(
            household_id=hid, kid_id=kid["id"],
            video=store.get_video(vid), reason="borderline",
        ))

    by_video = {p["video"]["id"]: p["channel_title"]
                for p in client.get("/parent/inbox", headers=hdr(auth)).json()}
    assert by_video["v_named___"] == "SciShow Kids"
    # An unnamed group is still a group, so it falls back to the id rather
    # than to an empty heading everything unrelated would pile into.
    assert by_video["v_nameless_"] == "UCnameless"


def test_starter_channels_are_offered_but_never_approved(client, auth) -> None:
    """A parent with no Google account and no Takeout export had an empty app.
    These are somewhere to start — and nothing more: being on the list buys a
    channel nothing, and approving is still the parent's own act."""
    r = client.get("/starter-channels?band=4_6&topics=songs")
    assert r.status_code == 200
    body = r.json()
    assert body["channels"], "a household with nothing has nothing to start from"
    assert {t["id"] for t in body["topics"]}, "the parent needs the topic list to choose from"

    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()
    # Merely asking for suggestions approves nothing.
    assert client.get(f"/kids/{kid['id']}/channels", headers=hdr(auth)).json() == []

    assert client.get("/starter-channels?band=nonsense").status_code == 422


def test_suggestions_follow_the_band_and_the_topics(client) -> None:
    young = client.get("/starter-channels?band=4_6").json()["channels"]
    older = client.get("/starter-channels?band=9_11").json()["channels"]
    assert {c["channel_id"] for c in young} != {c["channel_id"] for c in older}

    # No topics is "no preference", not "nothing".
    songs = client.get("/starter-channels?band=4_6&topics=songs").json()["channels"]
    assert 0 < len(songs) <= len(young)
    assert all("songs" in c["topics"] for c in songs)


def test_a_parent_can_search_youtube_for_channels(client, auth, monkeypatch, store) -> None:
    """A parent searching is not a child searching. The result is a suggestion
    they then approve, and every upload from an approved channel is still read
    against their answers — the allowlist is untouched. A child's own home has
    no path to YouTube at all."""
    from heygilli_agents.schemas import Channel

    kid = client.post("/kids", json={"nickname": "Abu", "age": 5}, headers=hdr(auth)).json()
    store.put_channel(auth["_hid"], kid["id"], Channel(id="UChave", title="Had It", approved=True))

    monkeypatch.setattr(gateway, "search_youtube_channels", lambda q, **k: [
        {"channel_id": "UCnew", "title": "SciShow Kids", "blurb": "science", "thumb_url": "t"},
        {"channel_id": "UChave", "title": "Had It", "blurb": "already", "thumb_url": "t"},
    ])

    body = client.get("/channels/search?q=science", headers=hdr(auth)).json()
    assert body["query"] == "science"
    by_id = {c["channel_id"]: c for c in body["channels"]}
    assert by_id["UCnew"]["approved_for"] == []
    # Says which children already have it, so a parent is not offered a
    # channel they approved months ago as though it were new.
    assert by_id["UChave"]["approved_for"] == [kid["id"]]

    # Searching approves nothing by itself.
    assert {c["id"] for c in client.get(f"/kids/{kid['id']}/channels",
                                        headers=hdr(auth)).json()} == {"UChave"}


def test_search_that_cannot_run_says_so_rather_than_finding_nothing(
    client, auth, monkeypatch
) -> None:
    """The daily allowance is a hundred searches for every household put
    together, and a key not permitted to search answers the same way. Both look
    like "no results" to a parent, who would retype their query for ever."""
    from heygilli_agents.tools.youtube import SearchUnavailable

    def refused(q, **k):
        raise SearchUnavailable("YouTube turned the search down.")

    monkeypatch.setattr(gateway, "search_youtube_channels", refused)
    r = client.get("/channels/search?q=peppa", headers=hdr(auth))
    assert r.status_code == 503
    assert "turned the search down" in r.json()["detail"]


def test_searching_needs_a_household(client) -> None:
    """It spends a shared allowance, so it is not open to anyone who finds it."""
    assert client.get("/channels/search?q=peppa").status_code == 401
