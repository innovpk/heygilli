"""The admin overview: read-only, and only for the service's own admins."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import admin, gateway
from heygilli_agents.schemas import GoogleLink


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


def _sign_in(client: TestClient, name: str) -> tuple[dict, str]:
    body = client.post("/auth/dev", json={"name": name}).json()
    return {"Authorization": f"Bearer {body['token']}"}, body["household_id"]


@pytest.fixture
def owner(client: TestClient, store, monkeypatch) -> tuple[dict, str]:
    monkeypatch.setenv("HEYGILLI_ADMIN_EMAILS", "owner@example.com")
    hdr, hid = _sign_in(client, "Owner")
    store.put_google_link(
        hid, GoogleLink(email="owner@example.com", refresh_token="secret-refresh")
    )
    return hdr, hid


def test_a_parent_who_is_not_an_admin_gets_nothing(client: TestClient, store) -> None:
    hdr, hid = _sign_in(client, "Someone")
    store.put_google_link(hid, GoogleLink(email="someone@example.com"))
    assert client.get("/admin/me", headers=hdr).json() == {"admin": False}
    # A 404, not a 403: the route does not advertise itself.
    assert client.get("/admin/overview", headers=hdr).status_code == 404


def test_signing_in_without_google_is_never_an_admin(client: TestClient, monkeypatch) -> None:
    monkeypatch.setenv("HEYGILLI_ADMIN_EMAILS", "owner@example.com")
    hdr, _ = _sign_in(client, "owner@example.com")
    assert client.get("/admin/overview", headers=hdr).status_code == 404


def test_no_token_no_overview(client: TestClient) -> None:
    assert client.get("/admin/overview").status_code == 401


def test_the_admin_sees_every_household_and_how_far_it_got(
    client: TestClient, store, owner
) -> None:
    hdr, owner_hid = owner
    assert client.get("/admin/me", headers=hdr).json() == {"admin": True}

    fam_hdr, fam = _sign_in(client, "A family")
    kid = client.post("/kids", json={"nickname": "Nalain", "age": 5}, headers=fam_hdr).json()
    store.put(
        fam,
        "session",
        "ses_1",
        {
            "id": "ses_1",
            "kid_id": kid["id"],
            "date": "2026-09-07",
            "started_at": "2026-09-07T12:15:00+00:00",
            "watched_sec": 300,
        },
    )
    tst_hdr, tst = _sign_in(client, "a probe")
    client.post("/kids", json={"nickname": "Ver", "age": 6}, headers=tst_hdr)

    r = client.get("/admin/overview", headers=hdr)
    assert r.status_code == 200
    body = r.json()
    rows = {h["id"]: h for h in body["households"]}
    assert rows[fam]["kids"] == [{"nickname": "Nalain", "age": 5}]
    assert rows[fam]["sessions"] == 1 and rows[fam]["minutes_watched"] == 5
    assert rows[fam]["likely_test"] is False
    assert rows[tst]["likely_test"] is True
    assert rows[owner_hid]["you"] is True and rows[owner_hid]["google"] is True
    assert body["totals"]["households"] == 3
    assert body["totals"]["real"] == 1 and body["totals"]["real_watched"] == 1
    assert body["sessions_per_day"] == [{"date": "2026-09-07", "sessions": 1}]


def test_the_overview_never_carries_an_email_or_a_token(client: TestClient, owner) -> None:
    hdr, _ = owner
    text = client.get("/admin/overview", headers=hdr).text
    assert "owner@example.com" not in text
    assert "secret-refresh" not in text


def test_the_allowed_list_holds_hashes_not_addresses() -> None:
    assert admin.ADMIN_EMAIL_SHA256
    assert all(len(h) == 64 for h in admin.ADMIN_EMAIL_SHA256)
    assert admin.is_admin_email("") is False
