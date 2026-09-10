"""What the parent asked for, carried through to the screening.

A parent picked Science, was offered Free School — a genuine educational
channel, correctly tagged — and got Swami Vivekananda and Albert Einstein
quote compilations approved onto an eight-year-old's shelf. Nothing was
broken: the topics filtered which *channels* were suggested and were then
thrown away, so by the time each upload was read there was no record that
science had been asked for, and a channel's topics are the channel's rather
than each video's.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import curator as curator_mod
from heygilli_agents import gateway
from heygilli_agents.schemas import CuratorDecision, Video


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Topic Parent"}).json()
    return {"hdr": {"Authorization": f"Bearer {body['token']}"}, "hid": body["household_id"]}


def test_what_the_parent_asked_for_is_remembered(client, auth, store, monkeypatch):
    """It used to filter the suggestions and then be dropped on the floor."""
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: None)
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]

    client.post(
        f"/kids/{kid_id}/channels/import",
        json={"channel_ids": ["UC5AN7XdQkLo6SO9_nI5Mk9Q"], "topics": ["science"]},
        headers=auth["hdr"],
    )

    assert store.get_kid(auth["hid"], kid_id).topics == ["science"]


def test_coming_back_for_more_does_not_forget_the_first_answer(
    client, auth, store, monkeypatch
):
    """A parent who adds animals later has not stopped wanting science."""
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: None)
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]

    for topic, channel in (("science", "UCa"), ("animals", "UCb")):
        client.post(
            f"/kids/{kid_id}/channels/import",
            json={"channel_ids": [channel], "topics": [topic]},
            headers=auth["hdr"],
        )

    assert store.get_kid(auth["hid"], kid_id).topics == ["animals", "science"]


class _Recorder:
    """Stands in for the model, keeping the prompt it was asked."""

    def __init__(self) -> None:
        self.prompt = ""

    def __call__(self, agent, prompt, schema, **_):
        self.prompt = prompt
        return CuratorDecision(decision="approve", reason="fine")


def test_the_screening_is_told_what_was_asked_for(monkeypatch):
    """Without this the model has no way to know the video is off-topic: the
    title reads as perfectly wholesome, because it is."""
    recorder = _Recorder()
    monkeypatch.setattr(curator_mod, "structured", recorder)
    video = Video(
        id="v1", channel_id="UCx", title="Swami Vivekananda Motivational Quotes",
        duration_s=300, thumb_url="t",
    )

    curator_mod.decide(
        video, "7_8", agent=None, excerpt="quotes about life",
        languages=["en"], transcript_source="gemini", wanted_topics=["science"],
    )

    assert "science" in recorder.prompt
    # Told what to do about it, not merely told the topic — and told the one
    # thing it must not do, since a preference is never a reason to hide.
    assert "ask_parent" in recorder.prompt
    assert "Never hide it for that alone." in recorder.prompt


def test_a_child_with_no_chosen_topics_is_not_asked_about_everything(monkeypatch):
    """A household that never picked topics has expressed no preference, and
    inventing one would send every upload to the parent."""
    recorder = _Recorder()
    monkeypatch.setattr(curator_mod, "structured", recorder)
    video = Video(id="v1", channel_id="UCx", title="Why Volcanoes Erupt", duration_s=300)

    curator_mod.decide(
        video, "7_8", agent=None, excerpt="lava", languages=["en"],
        transcript_source="gemini", wanted_topics=[],
    )

    assert "the parent asked for" not in recorder.prompt


def test_a_run_carries_the_child_s_topics_into_each_decision(store, monkeypatch):
    """The wiring, not the prompt: `decide` accepting topics is no use if the
    run that calls it for every upload never passes any."""
    from heygilli_agents.fake_model import FakeModel
    from heygilli_agents.llm import make_agent
    from heygilli_agents.schemas import Channel, Kid

    kid = Kid(household_id="hh", nickname="Abu", age=8, languages=["en"], topics=["science"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="Free School"))
    monkeypatch.setattr(
        curator_mod, "fetch_uploads",
        lambda cid, limit: [{
            "id": "quotes00001", "channel_id": "UCx",
            "title": "Swami Vivekananda Motivational Quotes",
            "published_at": "2026-09-01", "thumb_url": "", "description": "Quotes.",
        }],
    )
    monkeypatch.setattr(curator_mod, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(
        curator_mod, "fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:en:auto", "segments": [{"start_s": 0, "text": "quote"}]},
    )
    recorder = _Recorder()
    monkeypatch.setattr(curator_mod, "structured", recorder)

    model = FakeModel()
    curator_mod.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )

    assert "the parent asked for: science" in recorder.prompt


# --- Questions pitched at the child's age -------------------------------------------------------


def test_the_questions_follow_the_age():
    """One list was asked of every family, so a parent of a four-year-old was
    asked about sponsor reads and a parent of an eleven-year-old about cartoon
    peril — each answering somebody else's question."""
    from heygilli_agents.coach import builtin_policy_questions

    young = [q.question for q in builtin_policy_questions("4_6")]
    older = [q.question for q in builtin_policy_questions("9_11")]

    assert not set(young) & set(older)
    assert any("cartoon peril" in q for q in young)
    assert any("pranks played on real people" in q for q in older)
    # And it says which age it chose them for, since it cannot honestly claim
    # they came from this family's own channels.
    assert "5 to 6" in builtin_policy_questions("4_6")[0].why
    assert "9 to 12" in builtin_policy_questions("9_11")[0].why


def test_an_unknown_band_still_gets_questions():
    """A parent seeing the middle band's questions is a smaller failure than a
    parent seeing an empty screen."""
    from heygilli_agents.coach import builtin_policy_questions

    assert len(builtin_policy_questions("nonsense")) == 5


def test_preferences_pick_the_channels_and_start_the_screening(
    client, auth, store, monkeypatch
):
    """The parent is asked what their child likes, not to vouch for a channel's
    entire future output from a one-line blurb they cannot check."""
    started: list[str] = []
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: started.append(kid.id))
    monkeypatch.setattr(
        gateway, "_channel_info",
        lambda cid: {"channel_id": cid, "title": cid, "thumb_url": ""},
    )
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]

    r = client.post(
        f"/kids/{kid_id}/preferences", json={"topics": ["science"]}, headers=auth["hdr"]
    )

    assert r.status_code == 200
    assert r.json()["channels"] > 0
    assert store.get_kid(auth["hid"], kid_id).topics == ["science"]
    assert started == [kid_id]
    # Chosen for the band and the topic, not the whole list.
    approved = store.list_channels(auth["hid"], kid_id)
    assert 0 < len(approved) < 26


# --- What a child does while the screen is paused -----------------------------------------------


def test_break_lines_are_built_from_the_parent_s_own_picks(client, auth, store, monkeypatch):
    """A break said "time for a break" and stopped the video, which leaves a
    child looking at a still frame with nothing to do — the moment a break
    either works or is simply waited out."""
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: None)
    monkeypatch.setattr(
        gateway, "_channel_info",
        lambda cid: {"channel_id": cid, "title": cid, "thumb_url": ""},
    )
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]

    client.post(
        f"/kids/{kid_id}/preferences",
        json={"topics": [], "break_activities": ["jump", "water"]},
        headers=auth["hdr"],
    )

    kid = store.get_kid(auth["hid"], kid_id)
    assert kid.break_activities == ["jump", "water"]
    said = [m.text for m in kid.break_messages]
    assert any("Star jumps" in t for t in said)
    assert any("drink of water" in t for t in said)


def test_lines_a_parent_wrote_are_never_overwritten(client, auth, store, monkeypatch):
    """A setup step must not replace something a person sat and typed."""
    from heygilli_agents.schemas import BreakMessage

    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: None)
    monkeypatch.setattr(
        gateway, "_channel_info",
        lambda cid: {"channel_id": cid, "title": cid, "thumb_url": ""},
    )
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]
    kid = store.get_kid(auth["hid"], kid_id)
    kid.break_messages = [BreakMessage(text="Go and find Nani", spoken="Go and find Nani")]
    store.put_kid(kid)

    client.post(
        f"/kids/{kid_id}/preferences",
        json={"break_activities": ["jump"]},
        headers=auth["hdr"],
    )

    after = store.get_kid(auth["hid"], kid_id)
    assert [m.text for m in after.break_messages] == ["Go and find Nani"]
    # The picks are still recorded, so the Rules screen can offer to use them.
    assert after.break_activities == ["jump"]


def test_an_activity_we_do_not_know_is_dropped_not_spoken(client, auth, store, monkeypatch):
    """Gilli says these to a child, so an unrecognised id becomes nothing
    rather than being echoed back verbatim."""
    monkeypatch.setattr(gateway, "_curate_in_background", lambda kid: None)
    monkeypatch.setattr(
        gateway, "_channel_info",
        lambda cid: {"channel_id": cid, "title": cid, "thumb_url": ""},
    )
    kid_id = client.post(
        "/kids", json={"nickname": "Abu", "age": 8}, headers=auth["hdr"]
    ).json()["id"]

    client.post(
        f"/kids/{kid_id}/preferences",
        json={"break_activities": ["jump", "<script>alert(1)</script>"]},
        headers=auth["hdr"],
    )

    said = [m.text for m in store.get_kid(auth["hid"], kid_id).break_messages]
    assert len(said) == 1
    assert "script" not in said[0]
