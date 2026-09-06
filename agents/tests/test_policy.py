"""Household policy: what this family actually wants (PROTOCOL.md).

Offline, on the fake model. The claim under test is that a household's own
answers steer the Curator without ever taking the decision away from the parent:
a preference is a matter of taste, so it routes a video to the parent's inbox
rather than hiding it silently. And, as everywhere else in HeyGilli, nothing the
model writes here is ever shown to a child.
"""
from __future__ import annotations

from typing import Any

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import coach, curator, gateway
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import CuratorDecision, Kid, Policy, PolicyAnswer, Video
from heygilli_agents.store import LocalStore


def kid(age: int = 8) -> Kid:
    return Kid(household_id="hh", nickname="Abu", age=age)


def agent_returning(questions: list[dict[str, str]]):
    def canned(model_name: str, _text: str) -> dict[str, Any]:
        return {"questions": questions} if model_name == "SuggestedPolicyQuestions" else {}

    return make_agent("coach", "s", model=FakeModel(canned))


def agent_that_fails():
    def boom(_model_name: str, _text: str) -> dict[str, Any]:
        raise RuntimeError("provider is down")

    return make_agent("coach", "s", model=FakeModel(boom))


def policy_with(choice: str, question: str = "Are unboxing videos all right?") -> Policy:
    return Policy(
        kid_id="kid_1",
        answers=[PolicyAnswer(id=coach.question_id(question), question=question, choice=choice)],
    )


# --- the questions ------------------------------------------------------------


class TestQuestionsAreDrawnFromThisHousehold:
    def test_the_prompt_carries_this_household_s_own_channels(self) -> None:
        prompt = coach.policy_prompt("Abu", "7_8", ["Toy Hauls Daily", "Sprout Science"], ["Slime time"])

        assert "Toy Hauls Daily" in prompt and "Sprout Science" in prompt
        assert "Slime time" in prompt and "Abu" in prompt

    def test_questions_come_back_with_the_reason_they_were_asked(self) -> None:
        drafts = [{"question": "Are unboxing videos all right?", "why": "Toy Hauls Daily posts them."}]
        questions = coach.suggest_policy_questions(kid(), ["Toy Hauls Daily", "Sprout Science"],
                                                   agent=agent_returning(drafts))

        assert questions[0].question == "Are unboxing videos all right?"
        assert "Toy Hauls Daily" in questions[0].why, "why must name what prompted it"
        assert questions[0].options == ["fine", "sometimes", "rather_not"]

    def test_too_few_channels_asks_the_model_nothing_at_all(self) -> None:
        """The same rule the Reviewer uses: with almost nothing to go on there is
        nothing household-specific to say, so a model that would have to invent
        the household is never called."""
        model = FakeModel()
        questions = coach.suggest_policy_questions(kid(), ["Only One Channel"],
                                                   agent=make_agent("coach", "s", model=model))

        assert model.calls == [], "no evidence, no model call"
        assert questions == coach.builtin_policy_questions()

    def test_a_provider_failure_still_fills_the_screen(self) -> None:
        questions = coach.suggest_policy_questions(kid(), ["A", "B", "C"], agent=agent_that_fails())

        assert questions == coach.builtin_policy_questions()
        assert all(q.why for q in questions), "a built-in still says why it is being asked"

    def test_junk_from_the_model_is_dropped_rather_than_shown(self) -> None:
        drafts = [
            {"question": "  ", "why": "nothing"},
            {"question": "x" * (coach.MAX_QUESTION_CHARS + 1), "why": "an essay"},
            {"question": "Are unboxing videos all right?", "why": "Toy Hauls Daily."},
            {"question": "are  unboxing   videos all right?", "why": "the same question again"},
        ]
        questions = coach.suggest_policy_questions(kid(), ["A", "B"], agent=agent_returning(drafts))

        assert [q.question for q in questions] == ["Are unboxing videos all right?"]

    def test_nothing_usable_falls_back_rather_than_returning_an_empty_screen(self) -> None:
        questions = coach.suggest_policy_questions(kid(), ["A", "B"], agent=agent_returning([]))

        assert questions == coach.builtin_policy_questions()

    def test_an_id_survives_the_question_being_asked_again(self) -> None:
        """An answer is filed under the question's id. Deriving that id from the
        text is what stops a re-ask from asking the parent the same thing twice."""
        assert coach.question_id("Are unboxing videos all right?") == coach.question_id(
            "  are   UNBOXING videos all right  "
        )
        assert coach.question_id("Are pranks all right?") != coach.question_id("Are hauls all right?")


# --- weight -------------------------------------------------------------------


class TestWeightIsAReportNotAKnob:
    def test_a_client_cannot_set_its_own_weight(self) -> None:
        """`weight` says how far an answer actually travels in this server. A
        parent app that sent its own number would be describing our behaviour,
        not setting it."""
        a = PolicyAnswer(id="pq_1", question="q", choice="fine", weight=1.0)
        assert a.weight == 0.5

    def test_rather_not_weighs_most_because_it_is_the_one_enforced_in_code(self) -> None:
        assert PolicyAnswer(id="pq_1", choice="rather_not").weight == 1.0
        assert PolicyAnswer(id="pq_1", choice="sometimes").weight == 0.5


# --- the Curator reads it -----------------------------------------------------


class TestThePolicySteersTheCuratorWithoutDecidingForTheParent:
    def test_an_empty_policy_adds_nothing_to_the_prompt(self) -> None:
        """An empty policy is a valid state meaning "use the age-band defaults",
        so it must not appear as an empty heading the model has to interpret."""
        assert curator.policy_prompt(None) == ""
        assert curator.policy_prompt(Policy(kid_id="kid_1")) == ""

    def test_the_answers_reach_the_model_with_their_ids(self) -> None:
        prompt = curator.policy_prompt(policy_with("rather_not"))

        assert "Are unboxing videos all right?" in prompt and "rather_not" in prompt
        assert coach.question_id("Are unboxing videos all right?") in prompt

    def test_the_parents_own_words_reach_the_model_too(self) -> None:
        policy = policy_with("fine")
        policy.notes = "He gets upset by anything with shouting."
        assert "shouting" in curator.policy_prompt(policy)

    def test_a_rather_not_sends_the_video_to_the_parent_instead_of_hiding_it(self) -> None:
        """The product's whole position: a preference is taste, not a safety
        rule, so the parent gets to say yes to this particular video."""
        decision = CuratorDecision(decision="hide", reason="A toy unboxing.",
                                   policy_id=coach.question_id("Are unboxing videos all right?"))
        out = curator.apply_policy(decision, policy_with("rather_not"))

        assert out.decision == "ask_parent"
        assert "rather not" in out.reason and "unboxing" in out.reason

    def test_a_video_approved_on_a_rather_not_also_goes_to_the_parent(self) -> None:
        decision = CuratorDecision(decision="approve", reason="Harmless haul video.",
                                   policy_id=coach.question_id("Are unboxing videos all right?"))
        assert curator.apply_policy(decision, policy_with("rather_not")).decision == "ask_parent"

    def test_an_id_the_parent_never_answered_that_way_changes_nothing(self) -> None:
        """Otherwise the model could launder any `hide` into an `ask_parent` by
        naming an id, and the safety rules would stop meaning anything."""
        decision = CuratorDecision(decision="hide", reason="Jump scares throughout.",
                                   policy_id=coach.question_id("Are unboxing videos all right?"))

        assert curator.apply_policy(decision, policy_with("fine")).decision == "hide"
        assert curator.apply_policy(decision, None).decision == "hide"
        assert curator.apply_policy(
            decision.model_copy(update={"policy_id": "pq_invented"}), policy_with("rather_not")
        ).decision == "hide"

    def test_a_decision_the_policy_had_nothing_to_do_with_passes_through(self) -> None:
        decision = CuratorDecision(decision="hide", reason="Gore in the thumbnail.")
        assert curator.apply_policy(decision, policy_with("rather_not")) == decision

    def test_run_curator_reads_the_stored_policy(self, store: LocalStore, monkeypatch) -> None:
        """End to end: the policy in the store reaches the decision, so a family
        that said "rather not" gets an inbox card rather than a silent hide."""
        k = Kid(household_id="hh", nickname="Zara", age=8)
        store.put_kid(k)
        from heygilli_agents.schemas import Channel

        store.put_channel("hh", k.id, Channel(id="UCx", title="Toy Hauls Daily"))
        question = "Are unboxing videos all right?"
        store.put_policy("hh", Policy(kid_id=k.id, answers=[
            PolicyAnswer(id=coach.question_id(question), question=question, choice="rather_not"),
        ]))
        uploads = [{"id": "hauls000001", "channel_id": "UCx", "title": "Ten New Toys",
                    "published_at": "2026-09-01", "thumb_url": "", "description": ""}]
        monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: uploads)
        monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
        monkeypatch.setattr(curator, "fetch_transcript",
                            lambda vid: {"video_id": vid, "source": "none", "segments": []})

        def canned(model_name: str, _text: str) -> dict[str, Any]:
            if model_name != "CuratorDecision":
                return {}
            return {"decision": "hide", "reason": "A toy haul.", "topics": [],
                    "policy_id": coach.question_id(question)}

        model = FakeModel(canned)
        report = curator.run_curator(
            k, store,
            curator=make_agent("curator", "s", model=model),
            planner=make_agent("planner", "s", model=FakeModel()),
        )
        prompts = [c["prompt"] for c in model.calls if c["model"] == "CuratorDecision"]
        assert prompts and question in prompts[0], "the policy must be in the prompt the model sees"
        assert [v["id"] for v in report.ask_parent] == ["hauls000001"]
        assert report.hidden == []
        assert len(store.list_parent_prompts("hh")) == 1, "the parent decides, not HeyGilli"


# --- the endpoints ------------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Policy Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def make_kid(client: TestClient, auth: dict) -> dict:
    return client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()


class TestTheEndpoints:
    def test_a_kid_who_was_never_asked_has_an_empty_policy_not_an_error(
        self, client: TestClient, auth: dict
    ) -> None:
        k = make_kid(client, auth)
        r = client.get(f"/kids/{k['id']}/policy", headers=hdr(auth))

        assert r.status_code == 200
        assert r.json() == {"kid_id": k["id"], "updated_at": r.json()["updated_at"],
                            "answers": [], "notes": ""}

    def test_saving_and_reading_back_the_parents_answers(self, client: TestClient, auth: dict) -> None:
        k = make_kid(client, auth)
        body = {"answers": [{"id": "pq_1", "question": "Are hauls all right?", "choice": "rather_not"}],
                "notes": "No shouting please."}
        saved = client.put(f"/kids/{k['id']}/policy", json=body, headers=hdr(auth)).json()

        assert saved["answers"][0]["choice"] == "rather_not"
        assert saved["answers"][0]["weight"] == 1.0
        assert saved["notes"] == "No shouting please."
        assert client.get(f"/kids/{k['id']}/policy", headers=hdr(auth)).json() == saved

    def test_the_last_answer_to_one_question_is_the_one_kept(
        self, client: TestClient, auth: dict
    ) -> None:
        k = make_kid(client, auth)
        body = {"answers": [{"id": "pq_1", "question": "q", "choice": "fine"},
                            {"id": "pq_1", "question": "q", "choice": "rather_not"}], "notes": ""}
        saved = client.put(f"/kids/{k['id']}/policy", json=body, headers=hdr(auth)).json()

        assert [a["choice"] for a in saved["answers"]] == ["rather_not"]

    def test_a_bad_choice_is_refused(self, client: TestClient, auth: dict) -> None:
        k = make_kid(client, auth)
        body = {"answers": [{"id": "pq_1", "question": "q", "choice": "absolutely_not"}], "notes": ""}
        assert client.put(f"/kids/{k['id']}/policy", json=body, headers=hdr(auth)).status_code == 422

    def test_questions_are_asked_about_this_kids_own_channels(
        self, client: TestClient, auth: dict, store: LocalStore
    ) -> None:
        from heygilli_agents.schemas import Channel

        k = make_kid(client, auth)
        for cid, title in (("UC1", "Toy Hauls Daily"), ("UC2", "Sprout Science")):
            store.put_channel(auth["_hid"], k["id"], Channel(id=cid, title=title))
        store.put_video(Video(id="v1", title="Slime time"))

        r = client.post(f"/kids/{k['id']}/policy/questions", headers=hdr(auth))

        assert r.status_code == 200
        questions = r.json()["questions"]
        assert questions and all({"id", "question", "why", "options"} == set(q) for q in questions)
        assert all(q["options"] == ["fine", "sometimes", "rather_not"] for q in questions)

    def test_policy_endpoints_need_auth_and_a_real_kid(self, client: TestClient, auth: dict) -> None:
        assert client.get("/kids/kid_nope/policy", headers=hdr(auth)).status_code == 404
        assert client.get("/kids/kid_nope/policy").status_code == 401
        assert client.post("/kids/kid_nope/policy/questions", headers=hdr(auth)).status_code == 404
