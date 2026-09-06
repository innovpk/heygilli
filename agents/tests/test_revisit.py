"""Revisiting a shaky concept (PROTOCOL.md "Revisiting a shaky concept").

Offline. The failure mode this feature has to avoid is a child noticing they are
being retested, so most of what is tested here is what does NOT happen: no
revisit as the first question, none two sessions running on the same idea, none
a third time, and nothing in what the child hears that refers to the past.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, revisit
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import (
    Answer,
    Kid,
    Question,
    QuestionPlan,
    RevisitRecord,
    RevisitTag,
    Session,
    Video,
)
from heygilli_agents.store import LocalStore

HH = "hh_revisit"
CONCEPT = "Ice melts"
VIDEO = Video(id="vid00000001", channel_id="UCx", title="Why Ice Melts", duration_s=900)
LATER = Video(id="vid00000002", channel_id="UCx", title="Boiling A Kettle", duration_s=900)


def day(n: int) -> str:
    """`n` days ago, as a date string."""
    return (datetime.now(UTC).date() - timedelta(days=n)).isoformat()


def kid(age: int = 8) -> Kid:
    return Kid(id="kid_1", household_id=HH, nickname="Abu", age=age)


def plan_for(video: Video, *texts: str) -> QuestionPlan:
    return QuestionPlan(video_id=video.id, age_band="7_8", language="en", questions=[
        Question(t_sec=100 + 200 * i, type="why", input="voice", text=t, expected=e)
        for i, (t, e) in enumerate(texts_and_expected(texts))
    ])


def texts_and_expected(texts: tuple[str, ...]) -> list[tuple[str, str]]:
    # `expected` is what the concept label is drawn from, so it is spelled out here.
    return [(t, CONCEPT if i == 0 else f"something else {i}") for i, t in enumerate(texts)]


def watched(store: LocalStore, k: Kid, date: str, results: list[str], video: Video = VIDEO) -> Session:
    """One session on `date` whose answers had these results, question by question."""
    s = Session(household_id=HH, kid_id=k.id, video_id=video.id, age_band="7_8", language="en",
                watched_sec=600, date=date, started_at=f"{date}T10:00:00+00:00")
    store.put_session(s)
    for i, result in enumerate(results):
        store.put_answer(HH, Answer(session_id=s.id, question_idx=i, input_used="voice",
                                    result=result, created_at=f"{date}T10:0{i}:00+00:00"))
    return s


@pytest.fixture
def shaky_twice(store: LocalStore) -> Kid:
    """A child who was shaky on one concept on two separate days, which is what
    analytics calls `needs_another_look`."""
    k = kid()
    store.put_kid(k)
    store.put_video(VIDEO)
    store.put_plan(plan_for(VIDEO, "Why did the ice melt?", "What happened to the puddle?"))
    watched(store, k, day(5), ["partial", "correct"])
    watched(store, k, day(3), ["off_topic", "correct"])
    return k


# --- what a child must never hear ---------------------------------------------


class TestNothingRefersToThePast:
    @pytest.mark.parametrize("text", [
        "Do you remember when we talked about ice?",
        "Last time you said the sun did it — what about now?",
        "Why did the ice melt again?",
        "You didn't know this one before: why does ice melt?",
        "Let's try that one more time: why does ice melt?",
    ])
    def test_a_question_that_gives_the_game_away_is_caught(self, text: str) -> None:
        assert revisit.refers_to_the_past(text) is not None

    @pytest.mark.parametrize("text", [
        "Why is the water in the kettle disappearing?",
        "What is the steam made of?",
        "How does the heat change the water?",
    ])
    def test_a_fresh_question_about_this_video_is_fine(self, text: str) -> None:
        assert revisit.refers_to_the_past(text) is None


# --- which concepts are still worth asking about ------------------------------


class TestTheList:
    def test_two_shaky_days_puts_a_concept_on_it(self, store: LocalStore, shaky_twice: Kid) -> None:
        concepts = revisit.candidates(shaky_twice, store)

        assert [c.concept for c in concepts] == [CONCEPT]
        assert concepts[0].times_shaky == 2 and concepts[0].asked_again == 0

    def test_one_bad_day_is_noise_and_stays_off_it(self, store: LocalStore) -> None:
        k = kid()
        store.put_kid(k)
        store.put_video(VIDEO)
        store.put_plan(plan_for(VIDEO, "Why did the ice melt?", "What happened to the puddle?"))
        watched(store, k, day(3), ["partial", "correct"])

        assert revisit.candidates(k, store) == []

    def test_getting_it_right_twice_since_clears_it(self, store: LocalStore, shaky_twice: Kid) -> None:
        """PROTOCOL.md: a concept the child gets right twice leaves the list."""
        watched(store, shaky_twice, day(2), ["correct", "correct"])
        assert [c.concept for c in revisit.candidates(shaky_twice, store)] == [CONCEPT]

        watched(store, shaky_twice, day(1), ["correct", "correct"])
        assert revisit.candidates(shaky_twice, store) == []

    def test_corrects_from_before_the_wobble_do_not_count(self, store: LocalStore) -> None:
        """Counting every correct answer in the window would clear a concept on
        the strength of answers given before the child started struggling."""
        k = kid()
        store.put_kid(k)
        store.put_video(VIDEO)
        store.put_plan(plan_for(VIDEO, "Why did the ice melt?", "What happened to the puddle?"))
        watched(store, k, day(9), ["correct", "correct"])
        watched(store, k, day(8), ["correct", "correct"])
        watched(store, k, day(5), ["partial", "correct"])
        watched(store, k, day(3), ["off_topic", "correct"])

        assert [c.concept for c in revisit.candidates(k, store)] == [CONCEPT]

    def test_a_concept_asked_again_twice_is_never_offered_a_third_time(
        self, store: LocalStore, shaky_twice: Kid
    ) -> None:
        store.put_revisit(HH, RevisitRecord(kid_id=shaky_twice.id, concept=CONCEPT, asked_again=2,
                                            last_asked_at=day(1), last_session_id="ses_old"))
        assert revisit.candidates(shaky_twice, store) == []

    def test_a_pre_reader_has_no_revisits_at_all(self, store: LocalStore) -> None:
        """Concepts are a 7_8 and 9_11 idea; for a pre-reader the story is
        vocabulary, and analytics does not compute concepts for them either."""
        k = Kid(id="kid_2", household_id=HH, nickname="Abeeha", age=5)
        store.put_kid(k)
        assert revisit.candidates(k, store) == []


class TestNeverTwoSessionsRunning:
    def test_the_concept_the_last_session_asked_about_is_skipped(
        self, store: LocalStore, shaky_twice: Kid
    ) -> None:
        assert revisit.pick(shaky_twice, store, "ses_new").concept == CONCEPT

        store.put_revisit(HH, RevisitRecord(kid_id=shaky_twice.id, concept=CONCEPT, asked_again=1,
                                            last_asked_at=day(1), last_session_id="ses_old"))
        assert revisit.pick(shaky_twice, store, "ses_new") is None

    def test_but_the_session_that_asked_it_can_still_see_it(
        self, store: LocalStore, shaky_twice: Kid
    ) -> None:
        """Otherwise a reconnect mid-session would lose the revisit that session
        is already carrying."""
        store.put_revisit(HH, RevisitRecord(kid_id=shaky_twice.id, concept=CONCEPT, asked_again=1,
                                            last_asked_at=day(0), last_session_id="ses_this"))
        assert revisit.pick(shaky_twice, store, "ses_this").concept == CONCEPT


# --- writing and placing the question -----------------------------------------


def agent_returning(draft: dict[str, Any]):
    def canned(model_name: str, _text: str) -> dict[str, Any]:
        return draft if model_name == "RevisitDraft" else {}

    return make_agent("planner", "s", model=FakeModel(canned))


def agent_that_fails():
    def boom(_model_name: str, _text: str) -> dict[str, Any]:
        raise RuntimeError("provider is down")

    return make_agent("planner", "s", model=FakeModel(boom))


def later_plan() -> QuestionPlan:
    return plan_for(LATER, "What is in the kettle?", "What is the steam?")


class TestTheQuestionItself:
    def test_a_usable_draft_becomes_a_tagged_question(self, store: LocalStore) -> None:
        plan = later_plan()
        q = revisit.build_question(
            CONCEPT, plan.questions[-1], LATER, plan, last_seen=day(3),
            agent=agent_returning({"text": "What is the heat doing to the water?",
                                   "expected": "turning it to steam", "variants": [], "followup": ""}),
        )

        assert q is not None
        assert q.text == "What is the heat doing to the water?"
        assert q.revisit == RevisitTag(concept=CONCEPT, last_seen=day(3))
        assert q.t_sec == plan.questions[-1].t_sec, "the timing the Planner chose is kept"
        assert q.type == plan.questions[-1].type and q.input == "voice"

    def test_a_question_that_refers_to_the_past_is_thrown_away(self, store: LocalStore) -> None:
        """Not repaired: a near miss here is exactly the thing this feature has
        to avoid, and a session with no revisit costs nothing."""
        plan = later_plan()
        assert revisit.build_question(
            CONCEPT, plan.questions[-1], LATER, plan,
            agent=agent_returning({"text": "Remember when we talked about ice? Why does it melt?",
                                   "expected": "heat"}),
        ) is None

    def test_the_model_may_say_this_video_cannot_carry_the_idea(self, store: LocalStore) -> None:
        """An empty text is a correct answer. Forcing a question about volcanoes
        into a video about giraffes would be worse than no revisit."""
        plan = later_plan()
        assert revisit.build_question(CONCEPT, plan.questions[-1], LATER, plan,
                                      agent=agent_returning({"text": "  ", "expected": "x"})) is None

    def test_a_provider_failure_simply_means_no_revisit(self, store: LocalStore) -> None:
        """There is no canned fallback question on purpose: a revisit has to be
        answerable from the video just watched, and no canned sentence can be."""
        plan = later_plan()
        assert revisit.build_question(CONCEPT, plan.questions[-1], LATER, plan,
                                      agent=agent_that_fails()) is None


class TestWhereItGoes:
    def test_at_most_one_per_session_and_never_the_first_question(
        self, store: LocalStore, shaky_twice: Kid
    ) -> None:
        plan = later_plan()
        seeded = revisit.seed(plan, shaky_twice, store, LATER, "ses_new",
                              agent=agent_returning({"text": "What is the heat doing to the water?",
                                                     "expected": "steam"}))

        tagged = [i for i, q in enumerate(seeded.questions) if q.revisit is not None]
        assert tagged == [1], "one revisit, and not the question that opens the session"
        assert seeded.questions[0] == plan.questions[0]

    def test_a_one_question_plan_is_left_alone(self, store: LocalStore, shaky_twice: Kid) -> None:
        """The only question there is would be the first one."""
        plan = QuestionPlan(video_id=LATER.id, age_band="7_8", language="en", questions=[
            Question(t_sec=100, type="why", input="voice", text="What is in the kettle?", expected="water"),
        ])
        assert revisit.seed(plan, shaky_twice, store, LATER, "ses_new") == plan

    def test_nothing_to_revisit_leaves_the_plan_exactly_as_it_was(self, store: LocalStore) -> None:
        k = kid()
        store.put_kid(k)
        plan = later_plan()
        assert revisit.seed(plan, k, store, LATER, "ses_new") == plan

    def test_the_cached_plan_is_never_touched(self, store: LocalStore, shaky_twice: Kid) -> None:
        """Plans are cached per (video, band, language) and shared by every
        household. Writing one child's revisit into that cache would put their
        shaky concept into another family's session."""
        store.put_video(LATER)
        store.put_plan(later_plan())
        cached = store.get_plan(LATER.id, "7_8", "en")

        revisit.seed(cached, shaky_twice, store, LATER, "ses_new",
                     agent=agent_returning({"text": "What is the heat doing to the water?",
                                            "expected": "steam"}))

        stored = store.get_plan(LATER.id, "7_8", "en")
        assert all(q.revisit is None for q in stored.questions)
        assert stored == cached


class TestCountingWhatWasActuallyAsked:
    def test_asking_it_counts_once(self, store: LocalStore, shaky_twice: Kid) -> None:
        tag = RevisitTag(concept=CONCEPT, last_seen=day(3))
        assert revisit.record_asked(shaky_twice, store, tag, "ses_1").asked_again == 1
        assert revisit.record_asked(shaky_twice, store, tag, "ses_2").asked_again == 2
        assert revisit.candidates(shaky_twice, store) == [], "and then never again"


# --- the endpoints ------------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Revisit Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def seed_household(client: TestClient, auth: dict, store: LocalStore) -> str:
    """A kid in the token's own household who was shaky on the same concept twice."""
    hid = auth["_hid"]
    kid_id = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()["id"]
    store.put_video(VIDEO)
    store.put_video(LATER)
    store.put_plan(plan_for(VIDEO, "Why did the ice melt?", "What happened to the puddle?"))
    store.put_plan(later_plan())
    for date, results in ((day(5), ["partial", "correct"]), (day(3), ["off_topic", "correct"])):
        s = Session(household_id=hid, kid_id=kid_id, video_id=VIDEO.id, age_band="7_8",
                    language="en", watched_sec=600, date=date, started_at=f"{date}T10:00:00+00:00")
        store.put_session(s)
        for i, result in enumerate(results):
            store.put_answer(hid, Answer(session_id=s.id, question_idx=i, input_used="voice",
                                         result=result, created_at=f"{date}T10:0{i}:00+00:00"))
    return kid_id


def test_the_parent_can_see_what_is_worth_another_look(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid_id = seed_household(client, auth, store)
    body = client.get(f"/kids/{kid_id}/revisits", headers=hdr(auth)).json()

    assert [c["concept"] for c in body["concepts"]] == [CONCEPT]
    assert set(body["concepts"][0]) == {"concept", "times_shaky", "last_seen", "asked_again"}
    assert client.get("/kids/kid_nope/revisits", headers=hdr(auth)).status_code == 404
    assert client.get(f"/kids/{kid_id}/revisits").status_code == 401


def test_the_child_is_asked_but_never_told(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """End to end over the real socket: the revisit is in the session, and
    nothing the device receives says so — `revisit` is on the plan's question,
    not on the `ask` message."""
    kid_id = seed_household(client, auth, store)
    sid = client.post("/sessions", json={"kid_id": kid_id, "video_id": LATER.id},
                      headers=hdr(auth)).json()["session_id"]
    token = auth["Authorization"].split()[1]

    with client.websocket_connect(f"/sessions/{sid}/ws?token={token}") as ws:
        ws.send_json({"t": "hello"})
        assert ws.receive_json()["plan_questions"] == 2

        ws.send_json({"t": "position", "seconds": 101})
        assert ws.receive_json() == {"t": "pause"}
        first = ws.receive_json()
        assert first["q"] == 0 and first["text"] == "What is in the kettle?"
        ws.send_json({"t": "answer", "q": 0, "input": "none"})
        ws.receive_json()
        assert ws.receive_json() == {"t": "resume"}

        ws.send_json({"t": "position", "seconds": 301})
        assert ws.receive_json() == {"t": "pause"}
        ask = ws.receive_json()
        assert "revisit" not in ask, "the tag is for the parent's screen, not the child's device"
        assert revisit.refers_to_the_past(ask["text"]) is None
        assert ask["text"] == "What is making the water rise here?"
        ws.send_json({"t": "answer", "q": 1, "input": "none"})
        ws.receive_json()
        ws.receive_json()
        ws.send_json({"t": "bye"})
        ws.receive_json()

    records = store.list_revisits(auth["_hid"], kid_id)
    assert [(r.concept, r.asked_again) for r in records] == [(CONCEPT, 1)]
    body = client.get(f"/kids/{kid_id}/revisits", headers=hdr(auth)).json()
    assert body["concepts"][0]["asked_again"] == 1


def test_a_session_the_child_left_early_does_not_use_up_a_chance(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """A revisit counts when it is asked, not when it is planned: a child who
    stopped watching before the question never met it."""
    kid_id = seed_household(client, auth, store)
    sid = client.post("/sessions", json={"kid_id": kid_id, "video_id": LATER.id},
                      headers=hdr(auth)).json()["session_id"]
    token = auth["Authorization"].split()[1]

    with client.websocket_connect(f"/sessions/{sid}/ws?token={token}") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "bye"})
        ws.receive_json()

    assert store.list_revisits(auth["_hid"], kid_id) == []
