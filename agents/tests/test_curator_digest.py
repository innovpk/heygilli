"""Curator and Digest pipelines end to end on the fake model, network mocked."""
from __future__ import annotations

from heygilli_agents import curator, digest
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Answer, Channel, Kid, Session
from heygilli_agents.store import LocalStore

UPLOADS = [
    {"id": "goodvideo01", "channel_id": "UCx", "title": "Why Do Giraffes Have Long Necks?", "published_at": "2026-09-01",
     "thumb_url": "", "description": "Learn about giraffes."},
    {"id": "scaryvideo1", "channel_id": "UCx", "title": "Scary 3AM Prank", "published_at": "2026-09-02",
     "thumb_url": "", "description": ""},
    {"id": "borderline1", "channel_id": "UCx", "title": "Slime Challenge", "published_at": "2026-09-03",
     "thumb_url": "", "description": ""},
]
SEGMENTS = [{"start_s": i * 30, "text": f"line {i}"} for i in range(30)]


def test_run_curator_approves_hides_and_asks(store: LocalStore, monkeypatch) -> None:
    kid = Kid(household_id="hh", nickname="Zara", age=8, languages=["en", "ur"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: UPLOADS)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(curator, "fetch_transcript", lambda vid: {"video_id": vid, "source": "captions:en:auto", "segments": SEGMENTS})
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript", lambda vid: {"video_id": vid, "source": "captions:en:auto", "segments": SEGMENTS})

    model = FakeModel()
    report = curator.run_curator(kid, store, curator=make_agent("curator", "s", model=model),
                                 planner=make_agent("planner", "s", model=model))
    assert [v["id"] for v in report.approved] == ["goodvideo01"]
    assert [v["id"] for v in report.hidden] == ["scaryvideo1"]
    assert [v["id"] for v in report.ask_parent] == ["borderline1"]
    assert report.approved[0]["plan_ready"] is True
    assert store.get_plan("goodvideo01", "7_8", "en") and store.get_plan("goodvideo01", "7_8", "ur")
    assert store.list_kid_videos("hh", kid.id)["scaryvideo1"]["status"] == "hide"
    inbox = store.list_parent_prompts("hh")
    assert len(inbox) == 1 and inbox[0].video.id == "borderline1"
    # only the model-reviewed video cost a model call: one CuratorDecision, plus two plans
    assert [c["model"] for c in model.calls] == ["CuratorDecision", "PlanDraft", "PlanDraft"]
    # second run: everything already seen, nothing happens
    again = curator.run_curator(kid, store, curator=make_agent("curator", "s", model=model),
                                planner=make_agent("planner", "s", model=model))
    assert again.approved == [] and again.hidden == [] and again.ask_parent == []


def test_run_digest_counts_in_code_and_words_from_model(store: LocalStore) -> None:
    kid = Kid(household_id="hh", nickname="Ayaan", age=5)
    store.put_kid(kid)
    from heygilli_agents.schemas import Question, QuestionPlan, Video

    store.put_video(Video(id="v1", title="Giraffes", duration_s=600))
    store.put_plan(QuestionPlan(video_id="v1", age_band="4_6", language="en", questions=[
        Question(t_sec=130, type="name_it", input="voice", text="What animal?", expected="giraffe"),
        Question(t_sec=500, type="copy_it", input="copy", text="Roar!", expected="roar"),
    ]))
    s = Session(household_id="hh", kid_id=kid.id, video_id="v1", age_band="4_6", watched_sec=540, date="2026-09-05")
    store.put_session(s)
    store.put_answer("hh", Answer(session_id=s.id, question_idx=0, input_used="voice", result="partial",
                                  paraphrase="gaffe", word_said="giraffe"))
    store.put_answer("hh", Answer(session_id=s.id, question_idx=1, input_used="none", result="silence"))

    d = digest.run_digest(kid, "2026-09-05", store, agent=make_agent("digest", "s", model=FakeModel()))
    assert d.kind == "prereader" and d.videos == 1 and d.minutes == 9
    assert d.asked == 2 and d.answered == 1
    assert d.words_said == ["giraffe"]
    assert "giraffe" in d.words_heard and "roar" not in d.words_heard  # copy_it is not a modelled word
    assert d.dinner_prompt and d.notify is False
    assert store.get_digest("hh", kid.id, "2026-09-05") == d

    empty = digest.run_digest(kid, "2026-09-06", store)
    assert empty.asked == 0 and empty.dinner_prompt == ""
