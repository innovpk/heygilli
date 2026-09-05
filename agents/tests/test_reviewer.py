"""Channel reviews (PROTOCOL.md "Channel reviews"), offline with the fake model."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, reviewer
from heygilli_agents.fake_model import FakeModel, default_canned
from heygilli_agents.reviewer import MIN_UPLOADS, review_channel, reviewer_agent
from heygilli_agents.schemas import Channel
from heygilli_agents.store import LocalStore

CHANNEL = "UCsciencesciencescienceXX"[:24]
TITLES = [
    "Why Do Leaves Change Colour?",
    "How Does A Seed Become A Tree?",
    "What Is Inside A Volcano?",
    "Where Does Rain Come From?",
]


def feed(titles: list[str], title: str = "Sprout Science") -> dict:
    return {
        "channel_id": CHANNEL,
        "title": title,
        "uploads": [
            {"id": f"vid{i:08d}", "channel_id": CHANNEL, "title": t,
             "published_at": "2026-09-01T10:00:00+00:00", "thumb_url": "", "description": f"About {t}"}
            for i, t in enumerate(titles)
        ],
    }


@pytest.fixture
def fake_feed(monkeypatch: pytest.MonkeyPatch):
    """`fetch_channel_feed` stubbed; returns the call log so tests can count fetches."""
    calls: list[str] = []
    box = {"titles": TITLES}

    def fake(channel_id: str, limit: int = 15) -> dict:
        calls.append(channel_id)
        return feed(box["titles"])

    monkeypatch.setattr(reviewer, "fetch_channel_feed", fake)
    return {"calls": calls, "box": box}


def counting_agent() -> tuple[object, FakeModel]:
    model = FakeModel()
    return reviewer_agent(model=model), model


# --- the agent --------------------------------------------------------------


def test_review_uses_the_evidence_and_reports_the_model(store: LocalStore, fake_feed) -> None:
    agent, model = counting_agent()
    review = review_channel(CHANNEL, store, agent=agent)

    assert review.channel_id == CHANNEL and review.title == "Sprout Science"
    assert review.verdict == "good" and review.summary
    assert review.good_for == ["4_6", "7_8"] and review.flags == []
    assert review.reviewed_at and review.model == "fake"
    # sample_titles is exactly what was put in front of the model.
    assert review.sample_titles == TITLES
    sent = model.calls[-1]["prompt"]
    assert all(t in sent for t in review.sample_titles)


def test_sample_titles_track_the_evidence_not_the_model(store: LocalStore, fake_feed) -> None:
    """A model that names other videos cannot get them into `sample_titles`."""
    lying = FakeModel(canned=lambda name, text: (
        {"verdict": "concern", "summary": "Mostly unboxing.",
         "flags": [{"kind": "consumerism", "note": "toy hauls"}], "good_for": []}
        if name == "ChannelReviewDraft" else default_canned(name, text)
    ))
    review = review_channel(CHANNEL, store, agent=reviewer_agent(model=lying))
    assert review.verdict == "concern" and review.flags[0].kind == "consumerism"
    assert review.sample_titles == TITLES


@pytest.mark.parametrize("count", [0, 1, MIN_UPLOADS - 1])
def test_thin_evidence_is_unknown_and_never_reaches_the_model(
    store: LocalStore, fake_feed, count: int
) -> None:
    fake_feed["box"]["titles"] = TITLES[:count]
    agent, model = counting_agent()
    review = review_channel(CHANNEL, store, agent=agent)

    assert review.verdict == "unknown"
    assert review.flags and review.flags[0].kind == "unclear"
    assert str(count) in review.summary and "too little" in review.summary
    assert review.sample_titles == TITLES[:count]
    assert model.calls == [], "a guess was made from too little evidence"


def test_an_unreachable_channel_is_unknown_not_good(store: LocalStore, monkeypatch) -> None:
    def boom(channel_id: str, limit: int = 15) -> dict:
        raise RuntimeError("404")

    monkeypatch.setattr(reviewer, "fetch_channel_feed", boom)
    agent, model = counting_agent()
    review = review_channel(CHANNEL, store, agent=agent, title_hint="Gone", thumb_url="t")
    assert review.verdict == "unknown" and review.sample_titles == []
    assert review.title == "Gone" and review.thumb_url == "t"
    assert model.calls == []


def test_a_model_failure_is_unknown_not_good(store: LocalStore, fake_feed) -> None:
    empty = FakeModel(canned=lambda name, text: {})  # no structured output at all
    review = review_channel(CHANNEL, store, agent=reviewer_agent(model=empty))
    assert review.verdict == "unknown" and review.sample_titles == TITLES


# --- caching ----------------------------------------------------------------


def test_cache_hit_avoids_a_second_model_call_and_a_second_fetch(
    store: LocalStore, fake_feed
) -> None:
    agent, model = counting_agent()
    first = review_channel(CHANNEL, store, agent=agent)
    assert len(model.calls) == 1 and fake_feed["calls"] == [CHANNEL]

    second = review_channel(CHANNEL, store, agent=agent)
    assert len(model.calls) == 1, "the cached review was re-reviewed"
    assert fake_feed["calls"] == [CHANNEL]
    assert second.reviewed_at == first.reviewed_at

    third = review_channel(CHANNEL, store, agent=agent, refresh=True)
    assert len(model.calls) == 2 and len(fake_feed["calls"]) == 2
    assert third.verdict == first.verdict


def test_the_cache_is_global_not_per_kid(store: LocalStore, fake_feed) -> None:
    review_channel(CHANNEL, store, agent=counting_agent()[0])
    assert store.get_channel_review(CHANNEL)["channel_id"] == CHANNEL
    assert store.get("_global", "cache@channel_review", CHANNEL) is not None


# --- the endpoints ----------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Review Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def test_bulk_returns_cached_now_and_the_rest_pending(
    client: TestClient, auth: dict, store: LocalStore, fake_feed
) -> None:
    other = "UCotherotherotherotherX"[:24]
    store.put_channel_review(CHANNEL, {"channel_id": CHANNEL, "title": "Cached",
                                       "verdict": "good", "summary": "s", "model": "fake"})

    r = client.post("/channels/reviews", json={"channel_ids": [CHANNEL, other, other, " "]},
                    headers=hdr(auth))
    assert r.status_code == 200
    body = r.json()
    assert [x["channel_id"] for x in body["reviews"]] == [CHANNEL]
    assert body["reviews"][0]["title"] == "Cached"
    assert body["pending"] == [other]  # deduped, blanks dropped
    assert set(body["reviews"][0]) == {
        "channel_id", "title", "thumb_url", "verdict", "summary", "flags",
        "good_for", "sample_titles", "reviewed_at", "model",
    }

    # TestClient runs background tasks inline, so the next poll finds it done.
    again = client.post("/channels/reviews", json={"channel_ids": [CHANNEL, other]},
                        headers=hdr(auth)).json()
    assert again["pending"] == []
    assert {x["channel_id"] for x in again["reviews"]} == {CHANNEL, other}


def test_single_review_endpoint_and_refresh(
    client: TestClient, auth: dict, store: LocalStore, fake_feed
) -> None:
    first = client.get(f"/channels/{CHANNEL}/review", headers=hdr(auth)).json()
    assert first["verdict"] == "good" and first["sample_titles"] == TITLES
    assert len(fake_feed["calls"]) == 1

    cached = client.get(f"/channels/{CHANNEL}/review", headers=hdr(auth)).json()
    assert len(fake_feed["calls"]) == 1 and cached["reviewed_at"] == first["reviewed_at"]

    client.get(f"/channels/{CHANNEL}/review?refresh=true", headers=hdr(auth))
    assert len(fake_feed["calls"]) == 2

    assert client.get(f"/channels/{CHANNEL}/review").status_code == 401


def test_a_known_channels_avatar_is_carried_into_the_review(
    client: TestClient, auth: dict, store: LocalStore, fake_feed
) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    store.put_channel(auth["_hid"], kid["id"], Channel(id=CHANNEL, title="Sprout", thumb_url="http://a.jpg"))
    review = client.get(f"/channels/{CHANNEL}/review", headers=hdr(auth)).json()
    assert review["thumb_url"] == "http://a.jpg"


def test_delete_removes_a_channel_from_one_kid_only(
    client: TestClient, auth: dict, store: LocalStore, fake_feed
) -> None:
    hid = auth["_hid"]
    a = client.post("/kids", json={"nickname": "Ayaan", "age": 5}, headers=hdr(auth)).json()
    b = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    for kid in (a, b):
        store.put_channel(hid, kid["id"], Channel(id=CHANNEL, title="Sprout"))
        store.put_channel(hid, kid["id"], Channel(id="UCkeepkeepkeepkeepkeepXX"[:24], title="Keep"))
    review = client.get(f"/channels/{CHANNEL}/review", headers=hdr(auth)).json()

    r = client.delete(f"/kids/{a['id']}/channels/{CHANNEL}", headers=hdr(auth))
    assert r.status_code == 200 and r.json() == {"removed": True}

    assert [c["id"] for c in client.get(f"/kids/{a['id']}/channels", headers=hdr(auth)).json()] == [
        "UCkeepkeepkeepkeepkeepXX"[:24]
    ]
    assert CHANNEL in [c["id"] for c in client.get(f"/kids/{b['id']}/channels", headers=hdr(auth)).json()]
    # The review is a property of the channel, so it survives the removal.
    assert store.get_channel_review(CHANNEL)["reviewed_at"] == review["reviewed_at"]

    assert client.delete(f"/kids/{a['id']}/channels/{CHANNEL}", headers=hdr(auth)).json() == {"removed": True}
    assert client.delete(f"/kids/nope/channels/{CHANNEL}", headers=hdr(auth)).status_code == 404
