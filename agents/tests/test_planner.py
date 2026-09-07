"""Planner: model proposes, code enforces; offline via FakeModel."""
from __future__ import annotations

from heygilli_agents import planner
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Option, Question, Video
from heygilli_agents.store import LocalStore

SEGMENTS = [{"start_s": i * 30, "text": f"line {i}"} for i in range(40)]
VIDEO = Video(id="vid1", title="Giraffes", duration_s=1200)


def agent_with(questions: list[dict]):
    def canned(model: str, text: str) -> dict:
        return {"questions": questions} if model == "PlanDraft" else {}

    return make_agent("planner", "sys", model=FakeModel(canned))


def test_default_fake_plan_passes_rules_for_every_band() -> None:
    for band in ("4_6", "7_8", "9_11"):
        plan = planner.build_plan(VIDEO, SEGMENTS, band, "en", agent=make_agent("planner", "sys", model=FakeModel()))
        assert plan.questions and all(q.type in planner.TYPES_FOR_BAND[band] for q in plan.questions)


def test_post_validation_drops_violations() -> None:
    bad = [
        {"t_sec": 60, "type": "name_it", "input": "voice", "text": "Too early", "expected": "cat"},
        {"t_sec": 130, "type": "why", "input": "voice", "text": "Why?", "expected": "nope"},
        {"t_sec": 200, "type": "name_it", "input": "voice", "text": "Which animal?", "expected": "giraffe"},
        {"t_sec": 300, "type": "name_it", "input": "voice", "text": "Gap too small", "expected": "lion"},
        {"t_sec": 700, "type": "pick_it", "input": "pick", "text": "Show me", "expected": "red",
         "options": [{"icon_id": "icon_red", "label": "red", "correct": True},
                     {"icon_id": "icon_red", "label": "red", "correct": True}]},
        {"t_sec": 1100, "type": "copy_it", "input": "copy", "text": "Roar!", "expected": "roar"},
    ]
    plan = planner.build_plan(VIDEO, SEGMENTS, "4_6", "en", agent=agent_with(bad))
    assert [(q.t_sec, q.type) for q in plan.questions] == [(200, "name_it"), (700, "pick_it")]
    # 700: two correct options -> repaired? no: two "correct" cannot be fixed, so it is dropped...
    # ...unless repair_pick de-duplicates the same icon first, leaving one correct + pool distractors.
    pick = plan.questions[1]
    assert len({o.icon_id for o in pick.options}) == 3 and sum(o.correct for o in pick.options) == 1
    assert plan.questions[0].model_line  # filled in by rules._fill


def test_short_video_question_is_shifted_to_the_end() -> None:
    short = Video(id="s", title="Short", duration_s=150)
    draft = [{"t_sec": 30, "type": "recall", "input": "voice", "text": "What?", "expected": "x"}]
    plan = planner.build_plan(short, SEGMENTS[:5], "7_8", "en", agent=agent_with(draft))
    assert [q.t_sec for q in plan.questions] == [147]


def test_repair_pick_maps_labels_to_icons_and_fills_distractors() -> None:
    q = Question(t_sec=300, type="pick_it", input="pick", text="Show me the giraffe.",
                 options=[Option(icon_id="giraff", label="giraffe", correct=True)])
    fixed = planner.repair_pick(q, "ur")
    ids = [o.icon_id for o in fixed.options]
    assert ids[0] == "icon_giraffe" and len(set(ids)) == 3
    assert fixed.options[0].label == "زرافہ"
    assert sum(o.correct for o in fixed.options) == 1
    unfixable = planner.repair_pick(Question(t_sec=300, type="pick_it", input="pick", text="?", options=[]), "en")
    assert unfixable.options == []


def test_fallback_when_nothing_survives_or_no_transcript() -> None:
    from heygilli_agents.schemas import TYPES_FOR_BAND

    plan = planner.build_plan(VIDEO, [], "9_11", "en")
    assert len(plan.questions) == 1
    assert plan.questions[0].type in TYPES_FOR_BAND["9_11"]
    assert plan.questions[0].t_sec == 1200 - planner.rules.END_MARGIN_S
    only_why = [{"t_sec": 130, "type": "why", "input": "voice", "text": "Why?", "expected": "x"}]
    plan = planner.build_plan(VIDEO, SEGMENTS, "4_6", "ur", agent=agent_with(only_why))
    assert plan.questions[0].type in TYPES_FOR_BAND["4_6"] and plan.language == "ur"


def test_ensure_plan_caches_and_marks_video(store: LocalStore, monkeypatch) -> None:
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: {"video_id": vid, "source": "captions:en:manual",
                                                                   "segments": SEGMENTS})
    store.put_video(VIDEO)
    agent = make_agent("planner", "sys", model=FakeModel())
    plan = planner.ensure_plan(VIDEO, "7_8", "en", store, agent)
    assert store.get_plan("vid1", "7_8", "en") == plan
    v = store.get_video("vid1")
    assert v.plan_ready and v.transcript_source == "captions:en:manual"
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: (_ for _ in ()).throw(AssertionError("cached")))
    assert planner.ensure_plan(VIDEO, "7_8", "en", store, agent) == plan


def test_prompt_states_the_band_contract() -> None:
    p = planner.plan_prompt(VIDEO, SEGMENTS, "4_6", "en", None)
    assert "first question no earlier than: 120s" in p
    assert "minimum gap between questions: 360s" in p
    assert "maximum questions: 2" in p
    assert "Never \"why\"" in p
    for banned in ("mock", "personal information", "scary"):
        assert banned in planner.PLANNER_SYSTEM_PROMPT


def test_a_refused_transcript_plans_from_the_title_instead_of_raising(store, monkeypatch) -> None:
    """The Curator now screens without a transcript where it must, so the
    Planner meets videos it never used to. Raising here took down the whole
    run — a 500 after minutes of work that was already saved — because the
    first video approved that way went straight into planning."""
    from heygilli_agents.tools.transcript import TranscriptsBlocked

    def refused(video_id):
        raise TranscriptsBlocked("YouTube is refusing captions to this machine")

    monkeypatch.setattr(planner, "fetch_transcript", refused)
    video = Video(id="vidblocked1", title="Why Do Giraffes Have Long Necks?", duration_s=600)
    store.put_video(video)

    plan = planner.ensure_plan(video, "4_6", "en", store,
                               agent=make_agent("planner", "s", model=FakeModel()))
    assert plan.questions, "a video with no transcript still gets something to ask"
    assert (store.get_video("vidblocked1")).transcript_source == "none", (
        "planned without a transcript, so it must not claim to have had one"
    )


def test_a_video_of_unknown_length_is_not_asked_about_at_second_zero() -> None:
    """The end-of-video question is scheduled relative to the end. A video
    whose length nobody could look up has no known end, so `duration - 3` came
    out below zero and clamped to 0: Gilli asked "what was your favourite bit?"
    the instant the video started, before there was anything to have a
    favourite bit of.

    Every household without a Google grant hits this, because a length can only
    be looked up with one.
    """
    from heygilli_agents import rules

    for band in ("4_6", "7_8", "9_11"):
        unknown = planner.fallback_plan(
            Video(id=f"vid{band}", title="Giraffes", duration_s=0), band, "en"
        )
        asked_at = unknown.questions[0].t_sec
        assert asked_at > 0, f"{band} asks before the video has played"
        # The same threshold every other question in that band obeys, rather
        # than a number invented here.
        assert asked_at == rules.TIMING[band].first_question_s

    # A known length still puts it at the end, which is where it belongs.
    known = planner.fallback_plan(
        Video(id="known", title="Giraffes", duration_s=600), "7_8", "en"
    )
    assert known.questions[0].t_sec == 600 - rules.END_MARGIN_S


def test_the_question_never_lands_before_the_band_would_allow_one() -> None:
    """A question asked earlier than the band's own rules permit is one the
    rules would have thrown out had the model proposed it."""
    from heygilli_agents import rules

    for band in ("4_6", "7_8", "9_11"):
        for duration in (0, 30, 200, 1800):
            plan = planner.fallback_plan(
                Video(id=f"v{band}{duration}", title="T", duration_s=duration), band, "en"
            )
            t = plan.questions[0].t_sec
            if duration == 0:
                assert t == rules.TIMING[band].first_question_s
            else:
                assert t == max(duration - rules.END_MARGIN_S, 0)
