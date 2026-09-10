"""Tags a parent can skim, beside the reason they may not read.

Approving twenty videos at setup meant twenty paragraphs of screening prose.
The Curator already named what each video was about; it now also names what
gave it pause, in a word or three, and both travel with the verdict to the
parent's screen. The reason stays — one tap away rather than in the way.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.curator import MAX_TAGS, clean_tags
from heygilli_agents.schemas import Screening, Video
from heygilli_agents.store import LocalStore


class TestCleaning:
    def test_short_capitalised_and_distinct(self) -> None:
        assert clean_tags(["science", "Science", "  volcanoes "]) == ["Science", "Volcanoes"]

    def test_a_sentence_is_not_a_tag(self) -> None:
        # A model that writes its reason into a tag has written nothing to skim.
        assert clean_tags(["this video gave me some pause about the ending"]) == []

    def test_trailing_punctuation_goes(self) -> None:
        assert clean_tags(["mildly scary."]) == ["Mildly scary"]

    def test_at_most_three(self) -> None:
        assert len(clean_tags(["one", "two", "three", "four"])) == MAX_TAGS

    def test_none_is_none(self) -> None:
        assert clean_tags(None) == [] and clean_tags([]) == []


class TestStored:
    def test_tags_are_kept_with_the_verdict(self, store: LocalStore) -> None:
        store.set_kid_video("h", "k", "v", "ask_parent", "a sponsor read",
                            topics=["Rhymes"], concerns=["Sponsor"])
        entry = store.list_kid_videos("h", "k")["v"]
        assert entry["topics"] == ["Rhymes"] and entry["concerns"] == ["Sponsor"]

    def test_a_parent_flipping_the_switch_keeps_them(self, store: LocalStore) -> None:
        # The tags describe the video, as the reason does. A parent changes the
        # status, not what is in the video.
        store.set_kid_video("h", "k", "v", "ask_parent", "a sponsor read",
                            topics=["Rhymes"], concerns=["Sponsor"])
        store.set_kid_video("h", "k", "v", "approve", "parent decided", decided_by="parent")
        entry = store.list_kid_videos("h", "k")["v"]
        assert entry["status"] == "approve"
        assert entry["topics"] == ["Rhymes"] and entry["concerns"] == ["Sponsor"]
        assert entry["reason"] == "a sponsor read"

    def test_no_tags_leaves_no_empty_keys(self, store: LocalStore) -> None:
        store.set_kid_video("h", "k", "v", "approve", "fine")
        entry = store.list_kid_videos("h", "k")["v"]
        assert "topics" not in entry and "concerns" not in entry


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Tag Parent"}).json()
    return {"hdr": {"Authorization": f"Bearer {body['token']}"}, "hid": body["household_id"]}


@pytest.fixture
def kid_id(client: TestClient, auth: dict) -> str:
    return client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]).json()["id"]


def _review(client: TestClient, auth: dict, kid_id: str) -> dict:
    items = client.get(f"/kids/{kid_id}/review", headers=auth["hdr"]).json()["items"]
    return {i["video"]["id"]: i for i in items}


class TestServed:
    def test_the_review_sends_the_tags(self, client, auth, kid_id, store) -> None:
        store.put_video(Video(id="v_tag", channel_id="UCx", title="Twinkle", duration_s=300))
        store.set_kid_video(auth["hid"], kid_id, "v_tag", "ask_parent", "a sponsor read",
                            topics=["Rhymes"], concerns=["Sponsor"])
        item = _review(client, auth, kid_id)["v_tag"]
        assert item["topics"] == ["Rhymes"] and item["concerns"] == ["Sponsor"]

    def test_an_older_verdict_falls_back_to_the_videos_topics(
        self, client, auth, kid_id, store
    ) -> None:
        # Screened before concerns existed: no tags on the verdict, but the video
        # itself was tagged by topic, and that is still worth showing.
        store.put_video(Video(id="v_old", channel_id="UCx", title="Ducks", duration_s=300,
                              screening=Screening(topics=["Animals"])))
        store.set_kid_video(auth["hid"], kid_id, "v_old", "approve", "calm")
        item = _review(client, auth, kid_id)["v_old"]
        assert item["topics"] == ["Animals"] and item["concerns"] == []
