"""Setting a child up in one sitting.

Approving a new child's first videos used to happen in the inbox: a different
part of the app, visited later, holding only the videos the Curator could not
settle on its own — so the list never said what it had *not* asked about, and
a parent who had just picked channels was sent away to finish somewhere else.

This is the whole screening in one place, decided in bulk, at the moment the
channels are chosen. The inbox goes back to being where later uploads arrive.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.schemas import Channel, ParentPrompt, Video
from heygilli_agents.store import LocalStore


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Review Parent"}).json()
    return {"hdr": {"Authorization": f"Bearer {body['token']}"}, "hid": body["household_id"]}


@pytest.fixture
def kid_id(client: TestClient, auth: dict) -> str:
    return client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]


def screened(
    store: LocalStore, hid: str, kid_id: str, video_id: str, status: str, reason: str,
    transcript_source: str = "gemini",
) -> Video:
    """A video the Curator has already made its mind up about."""
    video = Video(
        id=video_id, channel_id="UCx", title=f"Video {video_id}", duration_s=600,
        thumb_url="t", transcript_source=transcript_source,
    )
    store.put_video(video)
    store.set_kid_video(hid, kid_id, video_id, status, reason)
    return video


def test_the_whole_screening_is_shown_not_only_the_questions(
    client, auth, kid_id, store
):
    """Approved, hidden and asked-about together, each carrying its reason."""
    screened(store, auth["hid"], kid_id, "v_yes", "approve", "matches what you said")
    screened(store, auth["hid"], kid_id, "v_no", "hide", "a live stream")
    screened(store, auth["hid"], kid_id, "v_ask", "ask_parent", "you said rather not to unboxing")

    body = client.get(f"/kids/{kid_id}/review", headers=auth["hdr"]).json()

    assert {i["video"]["id"]: i["status"] for i in body["items"]} == {
        "v_yes": "approve",
        "v_no": "hide",
        "v_ask": "ask_parent",
    }
    assert {i["reason"] for i in body["items"]} == {
        "matches what you said",
        "a live stream",
        "you said rather not to unboxing",
    }


def test_each_video_says_what_it_was_judged_on(client, auth, kid_id, store):
    """A video read on its title alone is a different opinion, not a weaker one,
    and the person deciding is the one who should be told which they have."""
    screened(store, auth["hid"], kid_id, "v_watched", "approve", "fine")
    screened(store, auth["hid"], kid_id, "v_title", "approve", "fine", transcript_source="none")

    body = client.get(f"/kids/{kid_id}/review", headers=auth["hdr"]).json()
    read = {i["video"]["id"]: i["read"] for i in body["items"]}

    assert read == {"v_watched": "watched", "v_title": "title only"}


def test_it_says_how_far_along_the_screening_is(client, auth, kid_id, store):
    """A run takes minutes. An empty list with no count reads as broken, which
    is exactly what a parent who has just picked channels sees."""
    store.put_channel(auth["hid"], kid_id, Channel(id="UCa", title="Danny Go!", approved=True))
    store.put_channel(auth["hid"], kid_id, Channel(id="UCb", title="Bluey", approved=True))
    screened(store, auth["hid"], kid_id, "v_one", "approve", "fine")

    body = client.get(f"/kids/{kid_id}/review", headers=auth["hdr"]).json()

    assert body["screened"] == 1
    assert body["channels"] == 2
    assert body["expected"] > body["screened"]


def test_deciding_here_clears_the_inbox_copy(client, auth, kid_id, store):
    """The same video asked about twice is a parent wondering whether their
    first answer took."""
    video = screened(store, auth["hid"], kid_id, "v_ask", "ask_parent", "borderline")
    store.put_parent_prompt(
        ParentPrompt(household_id=auth["hid"], kid_id=kid_id, video=video, reason="borderline")
    )
    assert len(client.get("/parent/inbox", headers=auth["hdr"]).json()) == 1

    r = client.post(f"/kids/{kid_id}/review", json={"approve": ["v_ask"]}, headers=auth["hdr"])

    assert r.json()["approved"] == 1
    assert client.get("/parent/inbox", headers=auth["hdr"]).json() == []
    home = client.get(f"/kids/{kid_id}/home", headers=auth["hdr"]).json()
    assert [v["id"] for row in home["rows"] for v in row["videos"]] == ["v_ask"]


def test_rejecting_takes_it_off_the_shelf(client, auth, kid_id, store):
    screened(store, auth["hid"], kid_id, "v_yes", "approve", "fine")

    client.post(f"/kids/{kid_id}/review", json={"hide": ["v_yes"]}, headers=auth["hdr"])

    home = client.get(f"/kids/{kid_id}/home", headers=auth["hdr"]).json()
    assert [v["id"] for row in home["rows"] for v in row["videos"]] == []


def test_a_contradiction_is_read_the_restrictive_way(client, auth, kid_id, store):
    """An id in both lists is a client bug, and a child's shelf is not the
    place to resolve one optimistically."""
    screened(store, auth["hid"], kid_id, "v_both", "ask_parent", "borderline")

    r = client.post(
        f"/kids/{kid_id}/review",
        json={"approve": ["v_both"], "hide": ["v_both"]},
        headers=auth["hdr"],
    )

    # Not "hidden because the hide loop happened to run second": the approval
    # is dropped before anything acts on it, so nothing is written, no plan is
    # built, and the count the parent is shown says one video, not two.
    assert r.json() == {"approved": 0, "hidden": 1}
    home = client.get(f"/kids/{kid_id}/home", headers=auth["hdr"]).json()
    assert [v["id"] for row in home["rows"] for v in row["videos"]] == []


# --- Deleting a child, as the parent sees it ----------------------------------------------------


def test_deleting_a_child_empties_their_inbox(client, auth, kid_id, store):
    """The inbox is the one place a deleted child could keep speaking.

    Every other trace is on a screen you reach through the child, so it goes
    when they do whether or not anything deleted it. The inbox is reached past
    them, and a card asking "is this all right for Abu?" about a child who no
    longer exists is both a question with no answer and a name the parent asked
    to be rid of.
    """
    video = screened(store, auth["hid"], kid_id, "v_ask", "ask_parent", "borderline")
    store.put_parent_prompt(
        ParentPrompt(household_id=auth["hid"], kid_id=kid_id, video=video, reason="borderline")
    )
    assert len(client.get("/parent/inbox", headers=auth["hdr"]).json()) == 1

    r = client.delete(f"/kids/{kid_id}?confirm=Abu", headers=auth["hdr"])

    assert r.status_code == 200
    assert client.get("/parent/inbox", headers=auth["hdr"]).json() == []


def test_a_sibling_keeps_their_inbox(client, auth, kid_id, store):
    """Two children share one inbox, so deleting by household would empty it."""
    sibling = client.post(
        "/kids", json={"nickname": "Zara", "age": 6}, headers=auth["hdr"]
    ).json()["id"]
    for kid, vid in ((kid_id, "v_abu"), (sibling, "v_zara")):
        video = screened(store, auth["hid"], kid, vid, "ask_parent", "borderline")
        store.put_parent_prompt(
            ParentPrompt(household_id=auth["hid"], kid_id=kid, video=video, reason="borderline")
        )
    assert len(client.get("/parent/inbox", headers=auth["hdr"]).json()) == 2

    client.delete(f"/kids/{kid_id}?confirm=Abu", headers=auth["hdr"])

    left = client.get("/parent/inbox", headers=auth["hdr"]).json()
    assert [i["kid_id"] for i in left] == [sibling]
