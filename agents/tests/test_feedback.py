"""Feedback: any parent can send it, only the service's admins can read it."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import feedback, gateway
from heygilli_agents.schemas import GoogleLink


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


def _sign_in(client: TestClient, name: str) -> tuple[dict, str]:
    body = client.post("/auth/dev", json={"name": name}).json()
    return {"Authorization": f"Bearer {body['token']}"}, body["household_id"]


@pytest.fixture
def owner(client: TestClient, store, monkeypatch) -> dict:
    monkeypatch.setenv("HEYGILLI_ADMIN_EMAILS", "owner@example.com")
    hdr, hid = _sign_in(client, "Owner")
    store.put_google_link(hid, GoogleLink(email="owner@example.com"))
    return hdr


def test_a_parent_sends_feedback_and_the_admin_reads_it(client: TestClient, owner) -> None:
    parent, hid = _sign_in(client, "A parent")
    r = client.post(
        "/feedback",
        json={"text": "  Loved the questions.  ", "contact": "me@example.org", "where": "rail"},
        headers=parent,
    )
    assert r.status_code == 200

    rows = client.get("/admin/feedback", headers=owner).json()
    assert len(rows) == 1
    assert rows[0]["text"] == "Loved the questions."
    assert rows[0]["contact"] == "me@example.org"
    assert rows[0]["household"] == hid and rows[0]["done"] is False

    overview = client.get("/admin/overview", headers=owner).json()
    assert overview["totals"]["feedback_open"] == 1


def test_the_admin_can_tick_one_off(client: TestClient, owner) -> None:
    parent, hid = _sign_in(client, "A parent")
    fid = client.post("/feedback", json={"text": "More songs"}, headers=parent).json()["id"]

    r = client.patch(f"/admin/feedback/{hid}/{fid}", json={"done": True}, headers=owner)
    assert r.status_code == 200
    assert client.get("/admin/feedback", headers=owner).json()[0]["done"] is True
    assert client.get("/admin/overview", headers=owner).json()["totals"]["feedback_open"] == 0


def test_nobody_else_can_read_or_tick_it(client: TestClient) -> None:
    parent, hid = _sign_in(client, "A parent")
    fid = client.post("/feedback", json={"text": "Hello"}, headers=parent).json()["id"]
    assert client.get("/admin/feedback", headers=parent).status_code == 404
    r = client.patch(f"/admin/feedback/{hid}/{fid}", json={"done": True}, headers=parent)
    assert r.status_code == 404


def test_empty_feedback_is_refused(client: TestClient) -> None:
    parent, _ = _sign_in(client, "A parent")
    assert client.post("/feedback", json={"text": ""}, headers=parent).status_code == 422
    assert client.post("/feedback", json={"text": "   "}, headers=parent).status_code == 422


def test_no_token_no_feedback(client: TestClient) -> None:
    assert client.post("/feedback", json={"text": "hi"}).status_code == 401


def test_a_script_cannot_fill_the_table(client: TestClient) -> None:
    parent, _ = _sign_in(client, "A parent")
    for _ in range(feedback.PER_DAY):
        assert client.post("/feedback", json={"text": "again"}, headers=parent).status_code == 200
    assert client.post("/feedback", json={"text": "again"}, headers=parent).status_code == 429


def test_an_odd_id_is_just_not_found(client: TestClient, owner) -> None:
    r = client.patch("/admin/feedback/..%2F..%2Fx/fb_1", json={"done": True}, headers=owner)
    assert r.status_code == 404


def test_feedback_goes_when_the_household_does(client: TestClient, store, owner) -> None:
    parent, hid = _sign_in(client, "A parent")
    client.post("/feedback", json={"text": "Bye"}, headers=parent)
    store.delete_household(hid)
    assert client.get("/admin/feedback", headers=owner).json() == []
