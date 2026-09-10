"""Full traces, the audit that fixes what the agents got wrong, and the reports. Offline."""
from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import agent_audit, gateway, guardrails, tracing
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent, structured
from heygilli_agents.schemas import Question as Q
from heygilli_agents.schemas import QuestionPlan, ScoredReply, Video
from heygilli_agents.store import GLOBAL

tracing.setup_tracing()


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def parent(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Trace Parent"}).json()
    return {"headers": {"Authorization": f"Bearer {body['token']}"}, "hid": body["household_id"]}


def buddy(reply: dict):
    return make_agent("buddy", "sys", model=FakeModel(lambda name, text: reply))


# --- traces -------------------------------------------------------------------------------------------


def test_every_agent_call_is_traced_in_full_without_the_childs_words(store) -> None:
    agent = buddy({"result": "correct", "paraphrase": "a fruit", "reply_text": "Yes! A fruit."})
    with tracing.scope("hh_t", "kid_t"):
        structured(agent, 'age_band: 7_8\nquestion: What is it?\nchild said: "my secret banana word"', ScoredReply)

    [event] = store.list("hh_t", "agent_event")
    doc = store.get("hh_t", "trace", event["trace_id"])
    assert doc["role"] == "buddy" and doc["kid_id"] == "kid_t" and doc["outcome"] == "ok"
    names = [s["name"] for s in doc["spans"]]
    assert tracing.ROOT in names and len(names) > 1  # Strands' own spans nest under the root
    raw = json.dumps(doc)
    assert "my secret banana word" not in raw
    assert "[not kept]" in raw


def test_redaction_handles_the_json_escaped_form_too() -> None:
    assert tracing.redact('child said: \\"hello there\\"') == 'child said: \\"[not kept]\\"'
    assert tracing.redact('child said: "hi"') == 'child said: "[not kept]"'


def test_a_trace_is_only_its_own_households(client: TestClient, parent: dict, store) -> None:
    with tracing.scope("someone_else"):
        structured(buddy({"result": "correct", "paraphrase": "", "reply_text": "Yes!"}), "go", ScoredReply)
    [event] = store.list("someone_else", "agent_event")
    r = client.get(f"/agents/traces/{event['trace_id']}", headers=parent["headers"])
    assert r.status_code == 404


def test_the_request_says_whose_calls_these_are(client: TestClient, parent: dict, store, monkeypatch) -> None:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=parent["headers"]).json()
    seen: list[tuple[str, str]] = []
    monkeypatch.setattr(gateway.playmate, "next_turn", lambda *a, **k: (
        seen.append(tracing.current()), gateway.playmate.PlayTurn(game="find", round=0, done=True))[1])
    client.post(f"/kids/{kid['id']}/play", json={"game": "find"}, headers=parent["headers"])
    assert seen == [(parent["hid"], kid["id"])]


# --- report -------------------------------------------------------------------------------------------


def test_the_report_counts_calls_and_lists_what_was_caught(client: TestClient, parent: dict) -> None:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=parent["headers"]).json()
    v = guardrails.Violation("game_line", "the game line has a number")
    agent_audit.record(role="playmate", output="PlayDraft", outcome="fixed", violations=[v], ms=900,
                       trace_id="t" * 32, household=parent["hid"], kid_id=kid["id"])
    agent_audit.record(role="curator", output="CuratorDecision", outcome="ok", violations=[], ms=1200,
                       trace_id="u" * 32, household=parent["hid"], kid_id=kid["id"])

    r = client.get(f"/agents/report?kid_id={kid['id']}", headers=parent["headers"]).json()
    assert r["calls"] == 2
    assert r["agents"]["playmate"]["fixed"] == 1 and r["agents"]["curator"]["ok"] == 1
    [incident] = r["incidents"]
    assert incident["rules"] == ["game_line"] and incident["outcome"].startswith("fixed")


# --- the audit: finding and fixing -------------------------------------------------------------------


def _approve(store, hid: str, kid_id: str, vid: str, title: str, decided_by: str = "") -> None:
    store.put_video(Video(id=vid, channel_id="UC1", title=title, duration_s=300, thumb_url="t"))
    store.set_kid_video(hid, kid_id, vid, "approve", "Looks fine.", decided_by=decided_by)


def test_the_audit_hides_and_sends_back_what_the_curator_should_not_have_approved(
    client: TestClient, parent: dict, store
) -> None:
    hid = parent["hid"]
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=parent["headers"]).json()
    _approve(store, hid, kid["id"], "zombie00001", "Zombie dance party")
    _approve(store, hid, kid["id"], "unbox000001", "Giant toy unboxing")
    _approve(store, hid, kid["id"], "parent00001", "Zombie facts", decided_by="parent")  # the parent's call
    _approve(store, hid, kid["id"], "fine0000001", "Why ice melts")

    r = client.post("/agents/audit", headers=parent["headers"]).json()

    shelf = store.list_kid_videos(hid, kid["id"])
    assert shelf["zombie00001"]["status"] == "hide" and shelf["zombie00001"]["decided_by"] == "audit"
    assert shelf["unbox000001"]["status"] == "ask_parent"
    assert shelf["parent00001"]["status"] == "approve"  # never overrules a parent
    assert shelf["fine0000001"]["status"] == "approve"
    assert {f["video_id"] for f in r["fixed"]} == {"zombie00001", "unbox000001"}
    assert any("unboxing" in p["reason"] for p in client.get("/parent/inbox", headers=parent["headers"]).json())
    # Fixed once; a second audit finds nothing new.
    assert client.post("/agents/audit", headers=parent["headers"]).json()["fixed"] == []


def test_the_audit_drops_a_cached_plan_a_child_must_not_hear(client: TestClient, parent: dict, store) -> None:
    hid = parent["hid"]
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=parent["headers"]).json()
    _approve(store, hid, kid["id"], "plan0000001", "Why ice melts", decided_by="parent")
    store.put_plan(QuestionPlan(video_id="plan0000001", age_band="7_8", language="en", questions=[
        Q(t_sec=60, type="name_it", input="voice", text="Tell me your address?"),
    ]))

    fixed = client.post("/agents/audit", headers=parent["headers"]).json()["fixed"]

    assert [f["role"] for f in fixed] == ["planner"]
    assert store.get_plan("plan0000001", "7_8", "en") is None


def test_an_agent_that_keeps_failing_is_reported(client: TestClient, parent: dict) -> None:
    for i in range(6):
        agent_audit.record(role="curator", output="CuratorDecision", outcome="model_error", violations=[],
                           ms=10, trace_id=f"{i:032x}", household=parent["hid"], kid_id="")
    fixed = client.post("/agents/audit", headers=parent["headers"]).json()["fixed"]
    assert [(f["kind"], f["role"]) for f in fixed] == [("degraded", "curator")]


# --- the operator's view ------------------------------------------------------------------------------


def test_the_ops_view_needs_its_token(client: TestClient, parent: dict, store, monkeypatch) -> None:
    assert client.get("/ops/agents").status_code == 404
    monkeypatch.setenv("HEYGILLI_OPS_TOKEN", "sekret")
    assert client.get("/ops/agents", headers={"x-ops-token": "wrong"}).status_code == 404
    agent_audit.record(role="buddy", output="ScoredReply", outcome="blocked",
                       violations=[guardrails.Violation("harsh_reply", "said wrong")], ms=5,
                       trace_id="v" * 32, household=parent["hid"], kid_id="")
    r = client.get("/ops/agents", headers={"x-ops-token": "sekret"}).json()
    assert r["by_kind"] == {"guardrail": 1} and r["incidents"][0]["household"] == parent["hid"]
    assert store.list(GLOBAL, "agent_incident_all")
