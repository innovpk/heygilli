"""Deleting a child, and deleting a household.

Both are irreversible and neither is undoable anywhere, so what matters is
that they are complete: a half-deleted child leaves a parent believing their
data is gone when a session, a digest or an answer is still sitting there.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.schemas import (
    Answer,
    BreakPeriod,
    Channel,
    Digest,
    ParentPrompt,
    Policy,
    PolicyAnswer,
    QuestionPlan,
    Session,
    Video,
    WordSeed,
)
from heygilli_agents.store import GLOBAL, LocalStore


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Test Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def fill(store: LocalStore, hid: str, kid_id: str, tag: str) -> None:
    """Something of every per-child kind, so "everything" can be checked."""
    store.put_policy(hid, Policy(kid_id=kid_id, answers=[
        PolicyAnswer(id="unboxing", question="Unboxing?", choice="rather_not"),
    ]))
    store.put_channel(hid, kid_id, Channel(id=f"UC{tag}", title=tag, approved=True))
    store.put_video(Video(id=f"vid{tag}", title=tag, duration_s=600))
    store.set_kid_video(hid, kid_id, f"vid{tag}", "approve", "ok")
    store.put_word_seed(hid, WordSeed(kid_id=kid_id, term=tag, language="en"))
    store.put_break(hid, BreakPeriod(kid_id=kid_id, ends_at="2026-09-08T10:05:00Z"))
    store.put_digest(hid, Digest(kid_id=kid_id, date="2026-09-08"))
    store.put_analytics_note(hid, f"{kid_id}#2026-09-08", {"note": tag})
    s = Session(household_id=hid, kid_id=kid_id, video_id=f"vid{tag}",
                age_band="7_8", date="2026-09-08")
    store.put_session(s)
    store.put_answer(hid, Answer(session_id=s.id, question_idx=0,
                                 input_used="voice", result="correct"))
    store.put_parent_prompt(ParentPrompt(
        household_id=hid, kid_id=kid_id, video=store.get_video(f"vid{tag}"),
        reason="borderline",
    ))


def rows_mentioning(
    store: LocalStore, hid: str, kid_id: str, sessions: tuple[str, ...] = ()
) -> list[str]:
    """Anything still stored under this household that belongs to the child.

    `sessions` matters more than it looks: an answer is stored under
    `answer@<session id>` and carries no kid id at all, so nothing about the
    row itself says whose it is. Walking only what names the child left every
    answer they ever gave sitting in the store, and a test that did not know
    to look reported the deletion as complete.
    """
    found = []
    owned = {f"answer@{sid}" for sid in sessions}
    for entity in store.entities(hid):
        if entity.endswith(f"@{kid_id}") or entity in owned:
            found += [f"{entity}/{i['_id']}" for i in store.list(hid, entity)]
            continue
        for item in store.list(hid, entity):
            blob = f"{item.get('_id', '')} {item.get('kid_id', '')}"
            if kid_id in blob:
                found.append(f"{entity}/{item.get('_id')}")
    return found


def everything(store: LocalStore, hid: str) -> set[str]:
    """Every row in the household, as entity/id — for "did this change?"."""
    return {
        f"{entity}/{item['_id']}"
        for entity in store.entities(hid)
        for item in store.list(hid, entity)
    }


def test_deleting_a_child_leaves_nothing_of_theirs_behind(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    hid = auth["_hid"]
    gone = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    stays = client.post("/kids", json={"nickname": "Zara", "age": 5}, headers=hdr(auth)).json()
    fill(store, hid, gone["id"], "gone")
    fill(store, hid, stays["id"], "stays")
    doomed = tuple(s.id for s in store.list_sessions(hid, gone["id"]))
    assert doomed, "the fixture wrote no sessions, so answers cannot be checked"
    assert rows_mentioning(store, hid, gone["id"], doomed), "the fixture wrote nothing"
    # Exactly what the sibling owns, before anything is deleted.
    before = everything(store, hid)
    theirs = {row for row in before
              if row not in set(rows_mentioning(store, hid, gone["id"], doomed))}

    r = client.delete(f"/kids/{gone['id']}?confirm=Abu", headers=hdr(auth))
    assert r.status_code == 200

    left = rows_mentioning(store, hid, gone["id"], doomed)
    assert left == [], f"still stored after deletion: {left}"
    # And the sibling keeps every single row, not merely some of them: taking
    # one child must not quietly cost the other their channels.
    assert everything(store, hid) == theirs
    assert [k["id"] for k in client.get("/kids", headers=hdr(auth)).json()] == [stays["id"]]


def test_deleting_a_child_keeps_what_belongs_to_everyone(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """Video metadata, question plans and channel reviews are keyed by video
    or channel and shared by every household. Taking them with one child would
    cost another family their screening."""
    hid = auth["_hid"]
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    fill(store, hid, kid["id"], "gone")
    store.put_plan(QuestionPlan(video_id="vidgone", age_band="7_8", language="en"))
    store.put_channel_review("UCgone", {"verdict": "fine"})

    client.delete(f"/kids/{kid['id']}?confirm=Abu", headers=hdr(auth))

    assert store.get_video("vidgone") is not None
    assert store.get_plan("vidgone", "7_8", "en") is not None
    assert store.get_channel_review("UCgone") is not None


def test_a_child_is_not_deleted_without_naming_them(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """A stray DELETE, a retry, or a mis-tapped row must not take a child's
    history with it."""
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    for query in ("", "?confirm=", "?confirm=Zara", "?confirm=yes"):
        assert client.delete(f"/kids/{kid['id']}{query}", headers=hdr(auth)).status_code == 400
    assert len(client.get("/kids", headers=hdr(auth)).json()) == 1

    # The name is what they typed, not how they capitalised it.
    assert client.delete(f"/kids/{kid['id']}?confirm=abu", headers=hdr(auth)).status_code == 200


def test_deleting_the_household_takes_everything_and_only_this_household(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    hid = auth["_hid"]
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    fill(store, hid, kid["id"], "mine")
    # Another family, mid-sentence, who must not notice any of this.
    store.put_kid(gateway.Kid(household_id="hh_someone_else", nickname="Ali", age=6))
    fill(store, "hh_someone_else", store.list_kids("hh_someone_else")[0].id, "theirs")
    store.put_plan(QuestionPlan(video_id="vidmine", age_band="7_8", language="en"))

    r = client.delete("/me?confirm=DELETE", headers=hdr(auth))
    assert r.status_code == 200 and r.json()["kids"] == 1

    assert store.entities(hid) == [], "the household still has rows"
    assert client.get("/kids", headers=hdr(auth)).json() == []
    # Untouched: the other household, and everything shared.
    assert len(store.list_kids("hh_someone_else")) == 1
    assert store.get_plan("vidmine", "7_8", "en") is not None
    assert store.get_video("vidmine") is not None


@pytest.mark.parametrize("query", ["", "?confirm=", "?confirm=delete", "?confirm=yes"])
def test_a_household_is_not_deleted_by_a_mistyped_url(
    client: TestClient, auth: dict, query: str
) -> None:
    client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth))
    assert client.delete(f"/me{query}", headers=hdr(auth)).status_code == 400
    assert len(client.get("/kids", headers=hdr(auth)).json()) == 1


def test_deleting_needs_a_household_token(client: TestClient) -> None:
    assert client.delete("/me?confirm=DELETE").status_code == 401
    assert client.delete("/kids/kid_x?confirm=x").status_code == 401


def test_the_global_area_is_never_a_household(store: LocalStore) -> None:
    """`delete_household` walks a partition, and GLOBAL is one. Nothing should
    ever call it with that, but the caches every household depends on are one
    typo away, so this pins that they are a different kind of thing."""
    store.put_video(Video(id="vidshared", title="Shared", duration_s=600))
    assert store.get(GLOBAL, "video", "vidshared") is not None
