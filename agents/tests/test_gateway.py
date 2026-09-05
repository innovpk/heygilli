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
    assert home == {"rows": [{"title": "New for you", "videos": []}]}
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
