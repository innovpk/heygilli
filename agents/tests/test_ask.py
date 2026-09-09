"""A parent asking about one video, and the Explainer answering.

The screening writes a few sentences and then the parent decides. That works
when their question happens to be the one the Curator answered, and not
otherwise. What matters here is not that an answer comes back but that it is
honest about what it rests on: an answer sourced from a video nobody could read
is worse than no answer, because it is indistinguishable from a good one.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import ask, gateway
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Policy, PolicyAnswer, Video
from heygilli_agents.store import LocalStore
from heygilli_agents.tools import evidence
from heygilli_agents.tools.transcript import TranscriptsBlocked

SEGMENTS = [
    {"start_s": 0, "text": "Today we are looking at volcanoes."},
    {"start_s": 30, "text": "Lava is molten rock, and it is very hot."},
    {"start_s": 192, "text": "Our sponsor sells lunch boxes, go and buy one."},
    {"start_s": 400, "text": "Nobody was hurt when the volcano erupted."},
]


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Test Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


@pytest.fixture
def transcripted(monkeypatch):
    got = {"video_id": "vol0000001", "source": "captions:en:auto", "segments": SEGMENTS}
    monkeypatch.setattr(ask, "fetch_transcript", lambda vid: got)
    monkeypatch.setattr(evidence, "fetch_transcript", lambda vid: got)
    return got


# --- searching the whole video, not the part that fitted in the prompt ---------------


def test_search_reaches_past_the_excerpt(transcripted) -> None:
    """The excerpt is the opening because that is what fits. A parent's question
    is very often about the middle or the end."""
    out = evidence.search_transcript("vol0000001", "sponsor")

    assert out["found"] is True
    assert out["hits"][0]["at"] == "3:12", out["hits"]
    assert "lunch boxes" in out["hits"][0]["text"]
    assert out["searched_whole_video"] is True


def test_search_is_not_case_sensitive(transcripted) -> None:
    assert evidence.search_transcript("vol0000001", "LAVA")["found"] is True
    assert evidence.search_transcript("vol0000001", "Volcanoes")["found"] is True


def test_nothing_found_and_nothing_read_are_different_answers(monkeypatch) -> None:
    """The distinction the tool exists for. "It is not in the video" and "nobody
    read the video" are opposite things to tell a parent, and a tool that
    returns found=False for both invites the confident wrong one."""
    monkeypatch.setattr(evidence, "fetch_transcript",
                        lambda vid: {"source": "none", "segments": []})
    unread = evidence.search_transcript("vol0000001", "hurt")
    assert unread["found"] is False
    assert unread["searched_whole_video"] is False, (
        "an unread video reports the same as one that was read and lacked the word"
    )

    def _blocked(vid):
        raise TranscriptsBlocked("refused")

    monkeypatch.setattr(evidence, "fetch_transcript", _blocked)
    assert evidence.search_transcript("v", "hurt")["searched_whole_video"] is False


def test_searching_for_nothing_asks_youtube_nothing(monkeypatch) -> None:
    def _boom(vid):  # pragma: no cover - must not be reached
        raise AssertionError("fetched a transcript for an empty search")

    monkeypatch.setattr(evidence, "fetch_transcript", _boom)
    assert evidence.search_transcript("v", "   ")["found"] is False


def test_channel_reputation_only_reads_what_is_cached(store: LocalStore) -> None:
    """A parent waiting on an answer about a video must not end up waiting on a
    channel being reviewed from scratch."""
    assert evidence.channel_reputation("UCnever")["known"] is False
    store.put_channel_review("UCx", {"verdict": "good", "summary": "Short science explainers.",
                                     "flags": [{"kind": "ads", "note": "Sponsor reads."}]})
    out = evidence.channel_reputation("UCx")
    assert out["known"] is True and out["verdict"] == "good"
    assert out["flags"] == ["Sponsor reads."]


# --- what the answer says it rests on -------------------------------------------------


def test_the_answer_says_it_read_the_words_when_it_did(transcripted) -> None:
    out = ask.answer_about_video(
        Video(id="vol0000001", title="Volcanoes", duration_s=600),
        "Is anyone hurt in it?",
        agent=make_agent("explainer", "s", model=FakeModel()),
    )
    assert out.answered_from == "the words of the video"
    assert out.answer


def test_an_unread_video_never_claims_to_have_been_watched(monkeypatch) -> None:
    """The one sentence on that screen a parent has to be able to trust. A model
    that can say "I watched it" eventually says it about a video nobody could
    fetch, so it is not the model's to say."""
    monkeypatch.setattr(ask, "fetch_transcript",
                        lambda vid: {"source": "none", "segments": []})

    def boasting(model_name: str, text: str) -> dict:
        return {"answer": "I watched the whole thing and it is lovely.",
                "answered_from": "the words of the video"}

    out = ask.answer_about_video(
        Video(id="vol0000001", title="Volcanoes", duration_s=600),
        "What happens in it?",
        agent=make_agent("explainer", "s", model=FakeModel(canned=boasting)),
    )
    assert out.answered_from == "the title and description only", (
        "the model talked its way into having watched a video nobody fetched"
    )


def test_a_blocked_transcript_is_not_an_error_to_the_parent(monkeypatch) -> None:
    def _blocked(vid):
        raise TranscriptsBlocked("refused from this address")

    monkeypatch.setattr(ask, "fetch_transcript", _blocked)
    out = ask.answer_about_video(
        Video(id="v", title="Volcanoes"), "What is in it?",
        agent=make_agent("explainer", "s", model=FakeModel()),
    )
    assert out.answered_from == "the title and description only"
    assert out.answer


def test_a_model_failure_says_so_rather_than_inventing(monkeypatch, transcripted) -> None:
    from heygilli_agents.llm import LLMError

    def _fail(*a, **k):
        raise LLMError("model down")

    monkeypatch.setattr(ask, "structured", _fail)
    out = ask.answer_about_video(
        Video(id="vol0000001", title="Volcanoes"), "What is in it?",
        agent=make_agent("explainer", "s", model=FakeModel()),
    )
    assert out.answered_from == "nothing"
    assert "could not read" in out.answer


def test_an_empty_question_costs_nothing(monkeypatch) -> None:
    def _boom(vid):  # pragma: no cover - must not be reached
        raise AssertionError("fetched a transcript for an empty question")

    monkeypatch.setattr(ask, "fetch_transcript", _boom)
    assert ask.answer_about_video(Video(id="v"), "   ").answered_from == "nothing"


def test_a_channel_id_is_refused_before_anything_is_fetched(transcripted) -> None:
    """The Explainer passed one in production, because the prompt showed it the
    channel id and no video id. `watch?v=UC...` resolves nowhere: captions raise
    and Gemini answers 400. Refusing on the shape costs nothing and says which
    id was wrong, so an empty result is never read back as an absence."""
    out = evidence.search_transcript("UCRFIPG2u1DxKLNuE3y2SjHA", "sponsor")
    assert out["searched_whole_video"] is False
    assert "channel id" in out["error"]


def test_a_real_video_id_is_not_caught_by_that(transcripted) -> None:
    # 11 characters, so it cannot match the 24-character channel pattern.
    assert "error" not in evidence.search_transcript("vol0000001", "lava")


def test_the_evidence_names_both_ids(transcripted) -> None:
    """`search_transcript` needs a video id, and the model can only pass what it
    can see. Both ids labelled, so neither can stand in for the other."""
    seen: dict = {}

    def capture(model_name: str, text: str) -> dict:
        seen["prompt"] = text
        return {"answer": "ok", "answered_from": ""}

    ask.answer_about_video(
        Video(id="vol0000001", channel_id="UCRFIPG2u1DxKLNuE3y2SjHA", title="Volcanoes"),
        "Is anything scary in it?",
        agent=make_agent("explainer", "s", model=FakeModel(canned=capture)),
    )
    assert "video id: vol0000001" in seen["prompt"]
    assert "channel id: UCRFIPG2u1DxKLNuE3y2SjHA" in seen["prompt"]


def test_the_evidence_carries_the_decision_and_the_household(transcripted) -> None:
    """What was decided and what the family said are the two things a "why was
    this flagged?" question is actually about."""
    seen: dict = {}

    def capture(model_name: str, text: str) -> dict:
        seen["prompt"] = text
        return {"answer": "ok", "answered_from": ""}

    policy = Policy(kid_id="k", answers=[
        PolicyAnswer(id="merch", question="Are sponsor videos all right?", choice="rather_not"),
    ], notes="No advertising please.")
    ask.answer_about_video(
        Video(id="vol0000001", title="Volcanoes", duration_s=600),
        "Why was this one flagged?",
        status="ask_parent", reason="There is a sponsor read.", policy=policy,
        agent=make_agent("explainer", "s", model=FakeModel(canned=capture)),
    )

    prompt = seen["prompt"]
    assert "ask_parent" in prompt and "sponsor read" in prompt
    assert "Are sponsor videos all right?" in prompt and "rather_not" in prompt
    assert "No advertising please." in prompt
    assert "Why was this one flagged?" in prompt


def test_earlier_turns_come_back_so_a_follow_up_makes_sense(transcripted) -> None:
    seen: dict = {}

    def capture(model_name: str, text: str) -> dict:
        seen["prompt"] = text
        return {"answer": "ok", "answered_from": ""}

    ask.answer_about_video(
        Video(id="vol0000001", title="Volcanoes"), "And how long is that bit?",
        history=[("Is there advertising?", "Yes, at 3:12 there is a sponsor read.")],
        agent=make_agent("explainer", "s", model=FakeModel(canned=capture)),
    )
    assert "Is there advertising?" in seen["prompt"]
    assert "sponsor read" in seen["prompt"]


# --- over the wire ---------------------------------------------------------------------


def test_a_parent_can_ask_about_a_video_on_their_childs_list(
    client: TestClient, auth: dict, store: LocalStore, transcripted
) -> None:
    hid = auth["_hid"]
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    store.put_video(Video(id="vol0000001", title="Volcanoes", duration_s=600))
    store.set_kid_video(hid, kid["id"], "vol0000001", "ask_parent", "There is a sponsor read.")

    r = client.post(f"/kids/{kid['id']}/videos/vol0000001/ask",
                    json={"question": "Is there advertising in it?"}, headers=hdr(auth))

    assert r.status_code == 200
    body = r.json()
    assert body["answer"]
    assert body["answered_from"] == "the words of the video"


def test_asking_decides_nothing(
    client: TestClient, auth: dict, store: LocalStore, transcripted
) -> None:
    """It is information for somebody about to decide. The switch stays theirs."""
    hid = auth["_hid"]
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    store.put_video(Video(id="vol0000001", title="Volcanoes", duration_s=600))
    store.set_kid_video(hid, kid["id"], "vol0000001", "ask_parent", "There is a sponsor read.")
    before = dict(store.list_kid_videos(hid, kid["id"])["vol0000001"])

    client.post(f"/kids/{kid['id']}/videos/vol0000001/ask",
                json={"question": "Should I allow this?"}, headers=hdr(auth))

    assert store.list_kid_videos(hid, kid["id"])["vol0000001"] == before
    assert store.get_video("vol0000001").age_ok is False


def test_asking_about_a_video_needs_the_household_it_belongs_to(
    client: TestClient, auth: dict, store: LocalStore, transcripted
) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    store.put_video(Video(id="vol0000001", title="Volcanoes"))
    path = f"/kids/{kid['id']}/videos/vol0000001/ask"

    assert client.post(path, json={"question": "hi"}).status_code == 401
    other = client.post("/auth/dev", json={"name": "Someone Else"}).json()
    assert client.post(path, json={"question": "hi"},
                       headers={"Authorization": f"Bearer {other['token']}"}).status_code == 404


def test_asking_about_a_video_that_does_not_exist_is_a_404(
    client: TestClient, auth: dict
) -> None:
    kid = client.post("/kids", json={"nickname": "Zara", "age": 8}, headers=hdr(auth)).json()
    r = client.post(f"/kids/{kid['id']}/videos/nosuchvid01/ask",
                    json={"question": "hi"}, headers=hdr(auth))
    assert r.status_code == 404
