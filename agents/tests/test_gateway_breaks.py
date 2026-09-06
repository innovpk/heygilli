"""Limits and breaks over the real endpoints and the real session socket.

Offline: the fake model writes the task, the store is a temp directory.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.schemas import Question, QuestionPlan, Session, Video
from heygilli_agents.store import LocalStore

VIDEO = Video(id="vid00000001", channel_id="UCx", title="Why Volcanoes Erupt", duration_s=1800, thumb_url="t")
LONG_VIDEO = Video(id="vid00000002", channel_id="UCx", title="Two Hours of Trains", duration_s=7200)


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Break Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def make_kid(client: TestClient, auth: dict, age: int = 8) -> dict:
    return client.post("/kids", json={"nickname": "Abu", "age": age}, headers=hdr(auth)).json()


def watched(store: LocalStore, hid: str, kid_id: str, minutes: int, ended_min_ago: int = 1) -> Session:
    """A finished session that ended `ended_min_ago` minutes ago."""
    end = datetime.now(UTC) - timedelta(minutes=ended_min_ago)
    start = end - timedelta(minutes=minutes)
    s = Session(
        household_id=hid, kid_id=kid_id, video_id=VIDEO.id, age_band="7_8",
        started_at=start.isoformat(timespec="seconds"), ended_at=end.isoformat(timespec="seconds"),
        watched_sec=minutes * 60, date=start.date().isoformat(),
    )
    store.put_session(s)
    return s


def plan_at(t_sec: int) -> QuestionPlan:
    return QuestionPlan(video_id=VIDEO.id, age_band="7_8", language="en", questions=[
        Question(t_sec=t_sec, type="why", input="voice", text="Why did the lava rise?",
                 expected="pressure", gesture="think"),
    ])


# --- limits -------------------------------------------------------------------------


def test_new_kids_get_the_documented_defaults(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    assert kid["daily_minutes"] == 60 and kid["break_after_minutes"] == 25
    assert kid["break_minutes"] == 5 and kid["max_video_minutes"] == 0


def test_kids_stored_before_this_feature_load_with_defaults(store: LocalStore) -> None:
    """The four limits are optional with defaults, so records written by an
    older build still parse (this is exactly what agents/.data holds)."""
    store.put("hh_old", "kid", "kid_old", {
        "id": "kid_old", "household_id": "hh_old", "nickname": "Abeeha", "age": 6,
        "age_band": "4_6", "languages": ["en"], "avatar": "gilli", "question_freq": "gentle",
        "daily_minutes": 60,
    })
    kid = store.get_kid("hh_old", "kid_old")
    assert kid is not None
    assert (kid.break_after_minutes, kid.break_minutes, kid.max_video_minutes) == (25, 5, 0)


def test_patch_limits_changes_only_what_was_sent(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    r = client.patch(f"/kids/{kid['id']}/limits", json={"daily_minutes": 30, "break_after_minutes": 20},
                     headers=hdr(auth))
    assert r.status_code == 200
    body = r.json()
    assert body["daily_minutes"] == 30 and body["break_after_minutes"] == 20
    assert body["break_minutes"] == 5 and body["nickname"] == "Abu"

    again = client.patch(f"/kids/{kid['id']}/limits", json={"break_minutes": 7}, headers=hdr(auth)).json()
    assert again["daily_minutes"] == 30 and again["break_minutes"] == 7

    assert client.patch("/kids/nope/limits", json={}, headers=hdr(auth)).status_code == 404
    assert client.patch(f"/kids/{kid['id']}/limits", json={"daily_minutes": -5},
                        headers=hdr(auth)).status_code == 422


def test_home_hides_videos_longer_than_the_cap(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    for v in (VIDEO, LONG_VIDEO):
        store.put_video(v)
        store.set_kid_video(auth["_hid"], kid["id"], v.id, "approve", "ok")

    ids = [v["id"] for v in client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()["rows"][0]["videos"]]
    assert set(ids) == {VIDEO.id, LONG_VIDEO.id}

    client.patch(f"/kids/{kid['id']}/limits", json={"max_video_minutes": 45}, headers=hdr(auth))
    ids = [v["id"] for v in client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()["rows"][0]["videos"]]
    assert ids == [VIDEO.id]


# --- state and enforcement ------------------------------------------------------------


def test_state_reports_the_day(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    watched(store, auth["_hid"], kid["id"], minutes=20)
    state = client.get(f"/kids/{kid['id']}/state", headers=hdr(auth)).json()
    assert state["minutes_today"] == 20 and state["minutes_left_today"] == 40
    assert state["continuous_minutes"] == 20 and state["watching_allowed"] is True
    assert state["blocked_reason"] is None and state["active_break"] is None
    assert client.get("/kids/nope/state", headers=hdr(auth)).status_code == 404


def test_a_spent_day_blocks_a_new_session_with_409(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    store.put_video(VIDEO)
    watched(store, auth["_hid"], kid["id"], minutes=61)

    r = client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id}, headers=hdr(auth))
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert detail["error"] == "daily_limit" and detail["state"]["minutes_left_today"] == 0

    home = client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()
    assert home["watching_allowed"] is False and home["blocked_reason"] == "daily_limit"

    # A parent raising the limit un-blocks it immediately.
    client.patch(f"/kids/{kid['id']}/limits", json={"daily_minutes": 120}, headers=hdr(auth))
    assert client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id},
                       headers=hdr(auth)).status_code == 200


def test_no_daily_limit_never_blocks(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    store.put_video(VIDEO)
    watched(store, auth["_hid"], kid["id"], minutes=300)
    client.patch(f"/kids/{kid['id']}/limits", json={"daily_minutes": 0}, headers=hdr(auth))
    state = client.get(f"/kids/{kid['id']}/state", headers=hdr(auth)).json()
    assert state["minutes_left_today"] is None and state["watching_allowed"] is True
    assert client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id},
                       headers=hdr(auth)).status_code == 200


# --- the break firing over the socket --------------------------------------------------


def start_session(client: TestClient, auth: dict, kid_id: str) -> str:
    r = client.post("/sessions", json={"kid_id": kid_id, "video_id": VIDEO.id}, headers=hdr(auth))
    assert r.status_code == 200
    return r.json()["session_id"]


def test_break_fires_at_a_question_pause_and_ends_the_session(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid = make_kid(client, auth)
    store.put_video(VIDEO)
    store.put_plan(plan_at(100))
    watched(store, auth["_hid"], kid["id"], minutes=26)  # 1 minute past the 25-minute limit
    sid = start_session(client, auth, kid["id"])

    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:
        ws.send_json({"t": "hello"})
        assert ws.receive_json()["t"] == "ready"
        ws.send_json({"t": "position", "seconds": 50})  # not a natural moment yet: keep watching
        ws.send_json({"t": "position", "seconds": 101})  # the question pause is the natural moment
        msg = ws.receive_json()
        assert msg["t"] == "break", msg
        brk = msg["break"]
        assert brk["kid_id"] == kid["id"] and brk["seconds_left"] > 0 and brk["acked"] is False
        # The Coach's own task, built from the title, not a built-in fallback.
        # `wire` drops null fields, so a quiet break has no `message` key at all.
        assert brk.get("message") is None, "no parent messages saved, so the break is quiet"
        assert brk["is_firm"] is True
        assert ws.receive_json()["t"] == "end"  # the session ends cleanly, no ask was sent

    # A break blocks the next session, and home says so.
    r = client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id}, headers=hdr(auth))
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert detail["error"] == "break" and detail["state"]["active_break"]["id"] == brk["id"]
    home = client.get(f"/kids/{kid['id']}/home", headers=hdr(auth)).json()
    assert home["watching_allowed"] is False and home["active_break"]["id"] == brk["id"]


def test_break_hard_interrupts_three_minutes_late(client: TestClient, auth: dict, store: LocalStore) -> None:
    """No natural moment arrives, so the break interrupts anyway."""
    kid = make_kid(client, auth)
    store.put_video(VIDEO)
    store.put_plan(plan_at(1700))  # the next question is a long way off
    watched(store, auth["_hid"], kid["id"], minutes=29)  # 4 minutes past the limit
    sid = start_session(client, auth, kid["id"])

    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 30})
        msg = ws.receive_json()
        assert msg["t"] == "break" and msg["break"]["seconds_left"] > 0
        assert ws.receive_json()["t"] == "end"


def test_no_break_before_the_limit(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    store.put_video(VIDEO)
    store.put_plan(plan_at(100))
    watched(store, auth["_hid"], kid["id"], minutes=10)
    sid = start_session(client, auth, kid["id"])

    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 101})
        assert ws.receive_json()["t"] == "pause"
        assert ws.receive_json()["t"] == "ask"  # the question happens as usual
        ws.send_json({"t": "answer", "q": 0, "input": "voice", "transcript": "the pressure pushed it"})
        assert ws.receive_json()["t"] == "reply"
        assert ws.receive_json()["t"] == "resume"
        ws.send_json({"t": "bye"})
        assert ws.receive_json()["t"] == "end"


def test_breaks_switched_off_never_fire(client: TestClient, auth: dict, store: LocalStore) -> None:
    kid = make_kid(client, auth)
    client.patch(f"/kids/{kid['id']}/limits", json={"break_after_minutes": 0}, headers=hdr(auth))
    store.put_video(VIDEO)
    store.put_plan(plan_at(100))
    watched(store, auth["_hid"], kid["id"], minutes=55)
    client.patch(f"/kids/{kid['id']}/limits", json={"daily_minutes": 0}, headers=hdr(auth))
    sid = start_session(client, auth, kid["id"])

    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 101})
        assert ws.receive_json()["t"] == "pause"
        assert ws.receive_json()["t"] == "ask"


# --- ack and override ------------------------------------------------------------------


def running_break(client: TestClient, auth: dict, store: LocalStore, kid: dict) -> dict:
    store.put_video(VIDEO)
    store.put_plan(plan_at(100))
    watched(store, auth["_hid"], kid["id"], minutes=26)
    sid = start_session(client, auth, kid["id"])
    with client.websocket_connect(f"/sessions/{sid}/ws") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 101})
        brk = ws.receive_json()["break"]
        ws.receive_json()
    return brk


def test_ack_records_but_does_not_shorten_the_break(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid = make_kid(client, auth)
    brk = running_break(client, auth, store, kid)

    acked = client.post(f"/kids/{kid['id']}/break/ack", headers=hdr(auth)).json()
    assert acked["acked"] is True and acked["id"] == brk["id"]
    assert acked["ends_at"] == brk["ends_at"]  # the clock is untouched
    assert acked["seconds_left"] > 0

    state = client.get(f"/kids/{kid['id']}/state", headers=hdr(auth)).json()
    assert state["watching_allowed"] is False and state["blocked_reason"] == "break"
    assert state["active_break"]["acked"] is True
    assert client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id},
                       headers=hdr(auth)).status_code == 409


def test_ack_with_no_break_running_is_a_404(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    assert client.post(f"/kids/{kid['id']}/break/ack", headers=hdr(auth)).status_code == 404


def test_override_clears_the_break_behind_the_pin(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid = make_kid(client, auth)
    running_break(client, auth, store, kid)

    assert client.post(f"/kids/{kid['id']}/break/override", json={"pin_ok": False},
                       headers=hdr(auth)).status_code == 403
    r = client.post(f"/kids/{kid['id']}/break/override", json={"pin_ok": True}, headers=hdr(auth))
    assert r.status_code == 200 and r.json() == {"cleared": True}

    state = client.get(f"/kids/{kid['id']}/state", headers=hdr(auth)).json()
    assert state["watching_allowed"] is True and state["active_break"] is None
    assert state["continuous_minutes"] == 0  # the override resets the sitting, like a break sat out
    assert client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id},
                       headers=hdr(auth)).status_code == 200

    second = client.post(f"/kids/{kid['id']}/break/override", json={"pin_ok": True}, headers=hdr(auth))
    assert second.json() == {"cleared": False}  # nothing left to clear


def test_a_break_expires_on_its_own_clock(client: TestClient, auth: dict, store: LocalStore) -> None:
    """Expiry is the clock's job: nothing has to run when a break ends."""
    kid = make_kid(client, auth)
    brk = running_break(client, auth, store, kid)
    stored = store.get_break(auth["_hid"], kid["id"], brk["id"])
    assert stored is not None
    store.put_break(auth["_hid"], stored.model_copy(update={
        "ends_at": (datetime.now(UTC) - timedelta(seconds=1)).isoformat(timespec="seconds")
    }))
    state = client.get(f"/kids/{kid['id']}/state", headers=hdr(auth)).json()
    assert state["watching_allowed"] is True and state["active_break"] is None
    assert client.post("/sessions", json={"kid_id": kid["id"], "video_id": VIDEO.id},
                       headers=hdr(auth)).status_code == 200


# --- break messages: the parent's own words ---------------------------------
#
# These endpoints are the only route from a keyboard to a child's ear, so what
# they must not do matters more than what they do: no line the parent did not
# save, and no identity the client got to choose.


def test_saving_lines_gives_each_one_an_id(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    r = client.put(
        f"/kids/{kid['id']}/break-messages",
        json={"messages": [{"id": "", "text": "Break time. Have a stretch."}]},
        headers=hdr(auth),
    )
    assert r.status_code == 200
    saved = r.json()["break_messages"]
    # The client sent a blank id, as a freshly typed line has none. Identity is
    # the server's to hand out: without it every save looks like a new line and
    # the rotation starts over.
    assert saved[0]["id"]
    assert saved[0]["text"] == "Break time. Have a stretch."


def test_an_id_the_parent_already_has_survives_an_edit(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    first = client.put(f"/kids/{kid['id']}/break-messages",
                       json={"messages": [{"text": "Break time."}]},
                       headers=hdr(auth)).json()["break_messages"][0]

    edited = client.put(
        f"/kids/{kid['id']}/break-messages",
        json={"messages": [{"id": first["id"], "text": "Break time. Drink some water."}]},
        headers=hdr(auth),
    ).json()["break_messages"][0]
    assert edited["id"] == first["id"]
    assert edited["text"] == "Break time. Drink some water."


def test_an_empty_list_is_a_quiet_break_not_a_no_op(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    client.put(f"/kids/{kid['id']}/break-messages",
               json={"messages": [{"text": "Break time."}]}, headers=hdr(auth))

    cleared = client.put(f"/kids/{kid['id']}/break-messages", json={"messages": []},
                         headers=hdr(auth)).json()
    # A parent who deletes every line means silence. Keeping the old ones
    # "because the list was empty" would put back words they just removed.
    assert cleared["break_messages"] == []


def test_a_break_reads_a_saved_line_and_no_other(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid = make_kid(client, auth)
    client.put(f"/kids/{kid['id']}/break-messages",
               json={"messages": [{"text": "Break time. Go and say salaam to Nano."}]},
               headers=hdr(auth))

    brk = running_break(client, auth, store, kid)
    assert brk["message"]["text"] == "Break time. Go and say salaam to Nano."


def test_a_parent_who_saved_nothing_gets_a_quiet_break(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    # No fallback line, no generated one. Gilli stops the video and says only
    # that it is break time, which the client words for itself.
    kid = make_kid(client, auth)
    brk = running_break(client, auth, store, kid)
    # The socket drops nulls, so a quiet break arrives with no message key at
    # all. Absent and null mean the same thing here, and the client reads both
    # as "say only that it is break time".
    assert brk.get("message") is None


def test_suggestions_are_drafts_and_reach_no_child(client: TestClient, auth: dict) -> None:
    kid = make_kid(client, auth)
    body = client.post(f"/kids/{kid['id']}/break-messages/suggest", headers=hdr(auth)).json()
    assert body["suggestions"], "the parent was offered nothing at all"
    # Asking changed nothing about what this child will hear.
    after = client.get("/kids", headers=hdr(auth)).json()[0]
    assert after["break_messages"] == []


def test_every_suggestion_is_something_gilli_can_say(client: TestClient, auth: dict) -> None:
    # Band 4_6 sees no text, so a draft with nothing to speak would become a
    # break where a pre-reader is told nothing at all.
    kid = make_kid(client, auth, age=5)
    body = client.post(f"/kids/{kid['id']}/break-messages/suggest", headers=hdr(auth)).json()
    for s in body["suggestions"]:
        assert (s["spoken"] or s["text"]).strip()
