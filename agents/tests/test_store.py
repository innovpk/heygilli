from __future__ import annotations

from heygilli_agents.schemas import (
    Answer,
    Channel,
    Digest,
    Kid,
    ParentPrompt,
    QuestionPlan,
    Session,
    Video,
)
from heygilli_agents.store import LocalStore


def test_primitive_crud(store: LocalStore) -> None:
    assert store.get("hh", "thing", "a") is None
    store.put("hh", "thing", "a", {"x": 1})
    store.put("hh", "thing", "b#c/d", {"x": 2})  # unsafe chars in ids are escaped
    assert store.get("hh", "thing", "a") == {"x": 1, "_id": "a"}
    assert store.get("hh", "thing", "b#c/d")["x"] == 2
    assert [d["_id"] for d in store.list("hh", "thing")] == ["a", "b#c/d"]
    store.delete("hh", "thing", "a")
    assert store.get("hh", "thing", "a") is None
    assert store.list("hh", "missing") == []


def test_typed_helpers(store: LocalStore) -> None:
    kid = Kid(household_id="hh", nickname="Ayaan", age=5)
    store.put_kid(kid)
    assert store.get_kid("hh", kid.id) == kid
    assert store.list_kids("hh") == [kid]
    assert store.get_kid("other", kid.id) is None

    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    assert store.list_channels("hh", kid.id)[0].title == "SciShow Kids"

    v = Video(id="vid1", title="Giraffes", duration_s=600)
    store.put_video(v)
    assert store.get_video("vid1") == v
    store.set_kid_video("hh", kid.id, "vid1", "approve", "ok")
    assert store.list_kid_videos("hh", kid.id)["vid1"]["status"] == "approve"

    plan = QuestionPlan(video_id="vid1", age_band="4_6", language="ur")
    store.put_plan(plan)
    assert store.get_plan("vid1", "4_6", "ur") == plan
    assert store.get_plan("vid1", "4_6", "en") is None


def test_sessions_answers_digest_prompts(store: LocalStore) -> None:
    s = Session(household_id="hh", kid_id="k", video_id="vid1", age_band="7_8")
    store.put_session(s)
    assert store.list_sessions("hh", "k") == [s]
    assert store.list_sessions("hh", "k", date="1999-01-01") == []

    a1 = Answer(session_id=s.id, question_idx=0, input_used="voice", result="correct", created_at="2026-01-01T00:00:01")
    a0 = Answer(session_id=s.id, question_idx=1, input_used="none", result="silence", created_at="2026-01-01T00:00:00")
    store.put_answer("hh", a1)
    store.put_answer("hh", a0)
    assert [a.question_idx for a in store.list_answers("hh", s.id)] == [1, 0]  # sorted by time

    d = Digest(kid_id="k", date="2026-09-05", asked=2)
    store.put_digest("hh", d)
    assert store.get_digest("hh", "k", "2026-09-05") == d

    p = ParentPrompt(household_id="hh", kid_id="k", video=Video(id="vid1"), reason="borderline")
    store.put_parent_prompt(p)
    assert [x.id for x in store.list_parent_prompts("hh")] == [p.id]
    p.decision = "approve"
    store.put_parent_prompt(p)
    assert store.list_parent_prompts("hh") == []
    assert len(store.list_parent_prompts("hh", open_only=False)) == 1

    store.cache_put("transcript", "vid1", {"source": "none", "segments": []})
    assert store.cache_get("transcript", "vid1")["source"] == "none"
