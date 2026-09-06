"""Bilingual word seeding (PROTOCOL.md "Bilingual word seeding").

Offline. This is the one place the product teaches rather than checks, so the
thing worth pinning down is where the word comes from: `shared/icons.json`, the
curated list a person wrote, matched exactly. No model translates anything, and
a wrong word taught confidently would be worse than no word at all.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, words
from heygilli_agents.schemas import (
    Answer,
    Kid,
    Question,
    QuestionPlan,
    RevisitTag,
    ServerReply,
    Session,
    Video,
    WordSeed,
    WordTag,
)
from heygilli_agents.store import LocalStore

HH = "hh_words"
GIRAFFE = "زرافہ"
LION = "شیر"
VIDEO = Video(id="vid00000001", channel_id="UCx", title="Tall Animals", duration_s=900)
LATER = Video(id="vid00000002", channel_id="UCx", title="Big Cats", duration_s=900)


def day(n: int) -> str:
    return (datetime.now(UTC).date() - timedelta(days=n)).isoformat()


def kid(languages: list[str] | None = None, age: int = 8) -> Kid:
    return Kid(id="kid_1", household_id=HH, nickname="Abu", age=age,
               languages=languages or ["en", "ur"])


def plan_for(video: Video, *expected: str) -> QuestionPlan:
    return QuestionPlan(video_id=video.id, age_band="7_8", language="en", questions=[
        Question(t_sec=100 + 200 * i, type="recall", input="voice",
                 text=f"What animal is that? ({e})", expected=e)
        for i, e in enumerate(expected)
    ])


def watched(store: LocalStore, k: Kid, date: str, video: Video, results: list[str],
            household: str = HH) -> Session:
    s = Session(household_id=household, kid_id=k.id, video_id=video.id, age_band="7_8",
                language="en", watched_sec=600, date=date, started_at=f"{date}T10:00:00+00:00")
    store.put_session(s)
    for i, result in enumerate(results):
        store.put_answer(household, Answer(session_id=s.id, question_idx=i, input_used="voice",
                                           result=result, created_at=f"{date}T10:0{i}:00+00:00"))
    return s


@pytest.fixture
def got_giraffe_right(store: LocalStore) -> Kid:
    k = kid()
    store.put_kid(k)
    store.put_video(VIDEO)
    store.put_video(LATER)
    store.put_plan(plan_for(VIDEO, "giraffe", "tall"))
    store.put_plan(plan_for(LATER, "lion", "loud"))
    watched(store, k, day(2), VIDEO, ["correct", "correct"])
    return k


# --- where the word comes from ------------------------------------------------


class TestTheTermIsCuratedNeverTranslated:
    def test_a_word_in_the_library_comes_back_exactly(self) -> None:
        assert words.curated_term("giraffe") == GIRAFFE
        assert words.curated_term("  GIRAFFE ") == GIRAFFE

    def test_a_word_nobody_wrote_a_translation_for_has_none(self) -> None:
        assert words.curated_term("photosynthesis") == ""
        assert words.curated_term("") == ""

    def test_a_near_miss_is_not_good_enough(self) -> None:
        """`find_icon` matches fuzzily, which is right for choosing a picture and
        wrong here: a mis-picked picture costs a moment, a mis-taught word is
        something a child repeats."""
        from heygilli_agents.tools.icons import find_icon

        assert find_icon("giraff") is not None, "the fuzzy lookup does match this"
        assert words.curated_term("giraff") == "", "and the teaching lookup does not"


class TestOnlyForAHouseholdThatAskedForIt:
    def test_the_language_list_is_the_opt_in(self) -> None:
        assert words.wants_seeding(kid(["en", "ur"]), "en") is True
        assert words.wants_seeding(kid(["en"]), "en") is False

    def test_a_child_already_watching_in_urdu_is_not_taught_urdu(self) -> None:
        assert words.wants_seeding(kid(["ur", "en"]), "ur") is False

    def test_a_monolingual_plan_is_left_exactly_as_it_was(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        english_only = kid(["en"])
        store.put_kid(english_only)
        plan = plan_for(LATER, "lion", "loud")
        assert words.seed(plan, english_only, store) == plan


# --- which word ---------------------------------------------------------------


class TestNeverAWordForSomethingTheyDoNotHaveYet:
    def test_a_word_they_got_right_is_a_candidate(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        assert ("giraffe", GIRAFFE) in words.known_words(got_giraffe_right, store)

    def test_a_word_they_did_not_get_right_is_not(self, store: LocalStore) -> None:
        """PROTOCOL.md: never a word for a concept the child has not already got
        right in their stronger language."""
        k = kid()
        store.put_kid(k)
        store.put_plan(plan_for(VIDEO, "giraffe", "tall"))
        watched(store, k, day(2), VIDEO, ["partial", "silence"])

        assert words.known_words(k, store) == []

    def test_a_sentence_is_not_a_word_to_learn(self, store: LocalStore) -> None:
        k = kid()
        store.put_kid(k)
        store.put_plan(plan_for(VIDEO, "because the sun warmed it up"))
        watched(store, k, day(2), VIDEO, ["correct"])

        assert words.known_words(k, store) == []

    def test_one_new_word_per_session_and_never_the_same_one_twice(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        """A child who hears six new words remembers none."""
        offer = words.pick_new(got_giraffe_right, store)
        assert offer == WordTag(term=GIRAFFE, language="ur", gloss="giraffe", first_heard=True)

        words.record_heard(got_giraffe_right, store, offer, datetime.now(UTC).date())
        assert words.pick_new(got_giraffe_right, store) is None, "there is no second word yet"


class TestAskingForItBack:
    def test_only_in_a_later_session(self, store: LocalStore, got_giraffe_right: Kid) -> None:
        """Asking two minutes after modelling a word tests memory of the last
        sentence, not a word learnt."""
        today = datetime.now(UTC).date()
        words.record_heard(got_giraffe_right, store, WordTag(term=GIRAFFE, gloss="giraffe"), today)

        assert words.pick_ask_back(got_giraffe_right, store, today) is None
        assert words.pick_ask_back(got_giraffe_right, store, today + timedelta(days=1)) is not None

    def test_a_word_the_child_has_already_said_is_not_asked_for_again(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        store.put_word_seed(HH, WordSeed(kid_id=got_giraffe_right.id, term=GIRAFFE, gloss="giraffe",
                                         times_heard=1, times_said=1,
                                         first_heard=day(3), last_heard=day(3)))
        assert words.pick_ask_back(got_giraffe_right, store) is None

    def test_the_question_is_written_in_code_with_the_curated_answer(self) -> None:
        """Nothing a model wrote is involved: the English half is fixed and the
        expected answer is the curated term."""
        replacing = Question(t_sec=300, type="recall", input="voice", text="anything", expected="x")
        q = words.ask_back_question(WordTag(term=GIRAFFE, gloss="giraffe"), replacing)

        assert q.text == "What do we say for giraffe in Urdu?"
        assert q.expected == GIRAFFE and q.model_line == GIRAFFE
        assert q.t_sec == 300 and q.input == "voice"
        assert q.word is not None and q.word.first_heard is False


# --- putting it in the session ------------------------------------------------


class TestWhereItGoes:
    def test_the_offer_rides_on_a_question_the_child_will_answer(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        plan = plan_for(LATER, "lion", "loud")
        seeded = words.seed(plan, got_giraffe_right, store)

        tagged = [i for i, q in enumerate(seeded.questions) if q.word is not None]
        assert tagged == [0], "one word, on the first question the session will reach"
        assert seeded.questions[0].word.gloss == "giraffe"

    def test_an_ask_back_replaces_the_last_question(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        store.put_word_seed(HH, WordSeed(kid_id=got_giraffe_right.id, term=GIRAFFE, gloss="giraffe",
                                         times_heard=1, first_heard=day(3), last_heard=day(3)))
        plan = plan_for(LATER, "lion", "loud")
        seeded = words.seed(plan, got_giraffe_right, store)

        assert seeded.questions[-1].text == "What do we say for giraffe in Urdu?"
        assert seeded.questions[0] == plan.questions[0], "the first question is untouched"

    def test_a_revisit_already_there_keeps_its_place(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        """One special question per session. Two makes a session feel like a test,
        which is the thing both features are trying not to be."""
        store.put_word_seed(HH, WordSeed(kid_id=got_giraffe_right.id, term=GIRAFFE, gloss="giraffe",
                                         times_heard=1, first_heard=day(3), last_heard=day(3)))
        plan = plan_for(LATER, "lion", "loud")
        with_revisit = plan.model_copy(update={"questions": [
            plan.questions[0],
            plan.questions[1].model_copy(update={"revisit": RevisitTag(concept="Ice melts")}),
        ]})

        seeded = words.seed(with_revisit, got_giraffe_right, store)

        assert seeded.questions[-1].revisit is not None
        assert seeded.questions[-1].text == with_revisit.questions[-1].text

    def test_the_cached_plan_is_never_touched(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        """Plans are shared by every household; a word seed belongs to one child."""
        cached = store.get_plan(LATER.id, "7_8", "en")
        words.seed(cached, got_giraffe_right, store)

        stored = store.get_plan(LATER.id, "7_8", "en")
        assert all(q.word is None for q in stored.questions)
        assert stored == cached


class TestWhatIsCountedAndWhen:
    def test_the_word_is_offered_only_after_a_correct_answer(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        """It is the word for something the child has *just shown they
        understand*; following a wrong answer with a new foreign word is the
        opposite of that."""
        tagged = plan_for(LATER, "lion").questions[0].model_copy(
            update={"word": WordTag(term=GIRAFFE, gloss="giraffe", first_heard=True)}
        )

        missed = words.after_answer(ServerReply(result="partial"), tagged, got_giraffe_right, store)
        assert missed.word is None
        assert store.list_word_seeds(HH, got_giraffe_right.id) == []

        got = words.after_answer(ServerReply(result="correct"), tagged, got_giraffe_right, store)
        assert got.word is not None and got.word.term == GIRAFFE
        seeds = store.list_word_seeds(HH, got_giraffe_right.id)
        assert [(s.term, s.times_heard, s.times_said) for s in seeds] == [(GIRAFFE, 1, 0)]

    def test_saying_it_back_is_what_moves_it_off_emerging(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        """`emerging` on the parent's analytics screen is exactly a seed with
        times_said == 0."""
        heard = WordTag(term=GIRAFFE, gloss="giraffe", first_heard=True)
        words.record_heard(got_giraffe_right, store, heard, datetime.now(UTC).date())

        asked = Question(t_sec=300, type="recall", input="voice", text="?", expected=GIRAFFE,
                         word=WordTag(term=GIRAFFE, gloss="giraffe", first_heard=False))
        words.after_answer(ServerReply(result="correct"), asked, got_giraffe_right, store)

        seed = store.list_word_seeds(HH, got_giraffe_right.id)[0]
        assert (seed.times_heard, seed.times_said) == (1, 1)

    def test_a_word_that_was_never_modelled_is_not_counted_as_said(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        asked = Question(t_sec=300, type="recall", input="voice", text="?", expected=LION,
                         word=WordTag(term=LION, gloss="lion", first_heard=False))
        words.after_answer(ServerReply(result="correct"), asked, got_giraffe_right, store)

        assert store.list_word_seeds(HH, got_giraffe_right.id) == []

    def test_a_question_with_no_word_on_it_changes_nothing(
        self, store: LocalStore, got_giraffe_right: Kid
    ) -> None:
        plain = plan_for(LATER, "lion").questions[0]
        reply = ServerReply(result="correct")
        assert words.after_answer(reply, plain, got_giraffe_right, store) is reply


# --- the endpoints ------------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Words Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def seed_household(client: TestClient, auth: dict, store: LocalStore) -> str:
    hid = auth["_hid"]
    kid_id = client.post("/kids", json={"nickname": "Abu", "age": 8, "languages": ["en", "ur"]},
                         headers=hdr(auth)).json()["id"]
    store.put_video(VIDEO)
    store.put_video(LATER)
    store.put_plan(plan_for(VIDEO, "giraffe", "tall"))
    store.put_plan(plan_for(LATER, "lion", "loud"))
    date = day(2)
    s = Session(household_id=hid, kid_id=kid_id, video_id=VIDEO.id, age_band="7_8", language="en",
                watched_sec=600, date=date, started_at=f"{date}T10:00:00+00:00")
    store.put_session(s)
    store.put_answer(hid, Answer(session_id=s.id, question_idx=0, input_used="voice",
                                 result="correct", created_at=f"{date}T10:00:00+00:00"))
    return kid_id


def test_the_parent_can_see_every_word_the_child_has_met(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid_id = seed_household(client, auth, store)
    assert client.get(f"/kids/{kid_id}/words", headers=hdr(auth)).json() == {"words": []}

    store.put_word_seed(auth["_hid"], WordSeed(kid_id=kid_id, term=GIRAFFE, gloss="giraffe",
                                               times_heard=1, first_heard=day(1), last_heard=day(1)))
    body = client.get(f"/kids/{kid_id}/words", headers=hdr(auth)).json()

    assert set(body["words"][0]) == {"kid_id", "term", "language", "gloss", "times_heard",
                                     "times_said", "first_heard", "last_heard"}
    assert body["words"][0]["term"] == GIRAFFE and body["words"][0]["times_said"] == 0
    assert client.get("/kids/kid_nope/words", headers=hdr(auth)).status_code == 404
    assert client.get(f"/kids/{kid_id}/words").status_code == 401


def test_gilli_offers_the_word_over_the_real_socket(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """The term rides beside the reply rather than inside its text, because
    Polly has no Urdu voice: a client with no Urdu voice of its own drops it and
    the child still gets the English reply, never a silence."""
    kid_id = seed_household(client, auth, store)
    sid = client.post("/sessions", json={"kid_id": kid_id, "video_id": LATER.id},
                      headers=hdr(auth)).json()["session_id"]
    token = auth["Authorization"].split()[1]

    with client.websocket_connect(f"/sessions/{sid}/ws?token={token}") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 101})
        assert ws.receive_json() == {"t": "pause"}
        ask = ws.receive_json()
        assert "word" not in ask, "the ask is unchanged; the word comes with the reply"

        ws.send_json({"t": "answer", "q": 0, "input": "voice", "transcript": "a lion"})
        reply = ws.receive_json()
        assert reply["result"] == "correct"
        assert reply["word"] == {"term": GIRAFFE, "language": "ur", "gloss": "giraffe",
                                 "first_heard": True}
        assert GIRAFFE not in (reply["text"] or ""), "Polly would have to say it, and cannot"
        ws.receive_json()
        ws.send_json({"t": "bye"})
        ws.receive_json()

    body = client.get(f"/kids/{kid_id}/words", headers=hdr(auth)).json()
    assert [(w["term"], w["times_heard"], w["times_said"]) for w in body["words"]] == [(GIRAFFE, 1, 0)]


def test_a_child_who_answers_badly_is_offered_nothing(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    kid_id = seed_household(client, auth, store)
    sid = client.post("/sessions", json={"kid_id": kid_id, "video_id": LATER.id},
                      headers=hdr(auth)).json()["session_id"]
    token = auth["Authorization"].split()[1]

    with client.websocket_connect(f"/sessions/{sid}/ws?token={token}") as ws:
        ws.send_json({"t": "hello"})
        ws.receive_json()
        ws.send_json({"t": "position", "seconds": 101})
        ws.receive_json()
        ws.receive_json()
        ws.send_json({"t": "answer", "q": 0, "input": "none"})
        reply = ws.receive_json()
        assert reply["result"] == "silence" and "word" not in reply
        ws.receive_json()
        ws.send_json({"t": "bye"})
        ws.receive_json()

    assert client.get(f"/kids/{kid_id}/words", headers=hdr(auth)).json() == {"words": []}
