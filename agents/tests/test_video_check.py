"""Checking a video or channel the parent found, before allowing anything.

Offline: the fetchers and the Curator's model call are stubbed, the store is a
temp directory.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import curator, gateway
from heygilli_agents.schemas import CuratorDecision

VIDEO_URL = "https://www.youtube.com/watch?v=abcdefghijk"
CHANNEL_URL = "https://www.youtube.com/@VolcanoKids"


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Check Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}"}


@pytest.fixture
def kid(client: TestClient, auth: dict) -> dict:
    return client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=auth).json()


@pytest.fixture(autouse=True)
def offline(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    read: list[str] = []

    def decide(video, band, agent, excerpt, policy=None, **_):
        read.append(video.id)
        return CuratorDecision(decision="approve", reason="Explains volcanoes.", topics=["Volcanoes"])

    monkeypatch.setattr(curator, "curator_agent", lambda: None)
    monkeypatch.setattr(curator, "decide", decide)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {
        "id": vid, "title": f"Video {vid}", "thumb_url": "t", "channel_id": "UCvolcano", "duration_s": 300,
    })
    monkeypatch.setattr(curator, "fetch_durations", lambda ids: {})
    monkeypatch.setattr(curator, "fetch_transcript", lambda vid: {
        "video_id": vid, "source": "captions:en:auto", "segments": [{"text": "lava", "start_s": 0, "dur_s": 2}],
    })
    monkeypatch.setattr(gateway, "resolve_channel_url", lambda url: {
        "channel_id": "UCvolcano", "title": "Volcano Kids", "thumb_url": "c",
    })
    monkeypatch.setattr(gateway, "fetch_uploads", lambda cid, limit: [
        {"id": f"up{n:09d}", "channel_id": cid, "title": f"Upload {n}", "thumb_url": "t"} for n in range(5)
    ][:limit])
    monkeypatch.setattr(gateway, "ensure_plan", lambda *a, **k: None)
    return read


def check(client: TestClient, auth: dict, kid: dict, url: str):
    return client.post(f"/kids/{kid['id']}/check", json={"url": url}, headers=auth)


def test_a_video_is_read_against_the_family_and_nothing_reaches_the_child(
    client: TestClient, auth: dict, kid: dict
) -> None:
    body = check(client, auth, kid, VIDEO_URL).json()
    assert body["kind"] == "video"
    item = body["items"][0]
    assert item["video"]["id"] == "abcdefghijk"
    assert item["status"] == "approve" and item["topics"] == ["Volcanoes"]
    assert item["on_shelf"] is False
    assert body["checks_left"] == gateway.CHECKS_PER_DAY - 1
    # A check decides nothing: the shelf is as it was.
    home = client.get(f"/kids/{kid['id']}/home", headers=auth).json()
    assert all(not row["videos"] for row in home["rows"])


def test_looking_again_at_a_checked_video_is_free(
    client: TestClient, auth: dict, kid: dict, offline: list[str]
) -> None:
    check(client, auth, kid, VIDEO_URL)
    again = check(client, auth, kid, VIDEO_URL).json()
    assert again["checks_left"] == gateway.CHECKS_PER_DAY - 1
    assert offline == ["abcdefghijk"], "the same video was read twice"


def test_a_channel_reads_only_as_many_uploads_as_today_allows(
    client: TestClient, auth: dict, kid: dict
) -> None:
    check(client, auth, kid, VIDEO_URL)  # one of today's checks spent
    body = check(client, auth, kid, CHANNEL_URL).json()
    assert body["kind"] == "channel" and body["channel"]["title"] == "Volcano Kids"
    assert len(body["items"]) == gateway.CHECKS_PER_DAY - 1
    assert body["not_read"] == 1
    assert body["checks_left"] == 0


def test_the_daily_allowance_runs_out_and_says_so(
    client: TestClient, auth: dict, kid: dict
) -> None:
    for n in range(gateway.CHECKS_PER_DAY):
        assert check(client, auth, kid, f"https://youtu.be/vid{n:08d}").status_code == 200
    over = check(client, auth, kid, "https://youtu.be/another1234")
    assert over.status_code == 429
    assert "tomorrow" in over.json()["detail"]


def test_allowing_a_checked_video_puts_just_that_video_on_the_shelf(
    client: TestClient, auth: dict, kid: dict
) -> None:
    check(client, auth, kid, VIDEO_URL)
    client.post(f"/kids/{kid['id']}/review", json={"approve": ["abcdefghijk"]}, headers=auth)
    home = client.get(f"/kids/{kid['id']}/home", headers=auth).json()
    assert [v["id"] for row in home["rows"] for v in row["videos"]] == ["abcdefghijk"]
    # And a second check says it is already there.
    item = check(client, auth, kid, VIDEO_URL).json()["items"][0]
    assert item["on_shelf"] is True
