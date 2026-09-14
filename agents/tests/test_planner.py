"""Planner: model proposes, code enforces; offline via FakeModel."""
from __future__ import annotations

import itertools

from heygilli_agents import planner, rules
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


def test_short_video_question_placed_mid_video() -> None:
    short = Video(id="s", title="Short", duration_s=150)
    draft = [{"t_sec": 30, "type": "recall", "input": "voice", "text": "What?", "expected": "x"}]
    plan = planner.build_plan(short, SEGMENTS[:5], "7_8", "en", agent=agent_with(draft))
    assert [q.t_sec for q in plan.questions] == [30]


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

    plan = planner.build_plan(Video(id="vid1", title="", duration_s=1200), [], "9_11", "en")
    # Two or three, not one. A single end-of-video question was the whole of a
    # transcript-less plan, and with no transcripts reachable from the deployed
    # gateway that was every video a child ever saw: twenty minutes of watching
    # and one thing asked, at the very end.
    assert len(plan.questions) == planner.rules.target_questions("9_11", 1200)
    assert len(plan.questions) >= 2
    assert all(q.type in TYPES_FOR_BAND["9_11"] for q in plan.questions)
    # The last one still belongs at the end.
    assert plan.questions[-1].t_sec == 1200 - planner.rules.END_MARGIN_S
    # And they are different questions, spaced by the band's own rules.
    assert len({q.text for q in plan.questions}) == len(plan.questions)
    gaps = [b.t_sec - a.t_sec for a, b in zip(plan.questions, plan.questions[1:])]
    assert all(g >= planner.rules.min_gap_s("9_11") for g in gaps), gaps
    only_why = [{"t_sec": 130, "type": "why", "input": "voice", "text": "Why?", "expected": "x"}]
    plan = planner.build_plan(VIDEO, SEGMENTS, "4_6", "ur", agent=agent_with(only_why))
    assert plan.questions[0].type in TYPES_FOR_BAND["4_6"] and plan.language == "ur"


def test_metadata_plan_when_no_transcript_but_title_present() -> None:
    agent = make_agent("planner", "sys", model=FakeModel())
    plan = planner.build_plan(VIDEO, [], "9_11", "en", agent=agent)
    assert plan.source == "metadata"
    assert len(plan.questions) >= 2


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
    # Asked for more than will be used: `rules.select` chooses among them for a
    # mix of ways to answer, and it can only choose what it is given.
    assert "questions that will be asked: 2" in p
    assert "propose at least this many candidates: 6" in p
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
        # A length nobody could look up leaves no room to space more out, so it
        # stays at one rather than guessing where the middle of it is.
        assert len(unknown.questions) == 1, f"{band} invented slots in a video of unknown length"

    # A known length still puts the last one at the end, which is where it
    # belongs — with the others spread through what came before.
    known = planner.fallback_plan(
        Video(id="known", title="Giraffes", duration_s=600), "7_8", "en"
    )
    assert known.questions[-1].t_sec == 600 - rules.END_MARGIN_S
    assert len(known.questions) == rules.target_questions("7_8", 600)


def test_the_question_never_lands_before_the_band_would_allow_one() -> None:
    """A question asked earlier than the band's own rules permit is one the
    rules would have thrown out had the model proposed it."""
    from heygilli_agents import rules

    for band in ("4_6", "7_8", "9_11"):
        for duration in (0, 30, 200, 1800):
            plan = planner.fallback_plan(
                Video(id=f"v{band}{duration}", title="T", duration_s=duration), band, "en"
            )
            first = plan.questions[0].t_sec
            assert first >= rules.TIMING[band].first_question_s or duration <= 200, (
                f"{band}/{duration}s asks before the band allows: {first}"
            )
            if duration == 0:
                assert first == rules.TIMING[band].first_question_s
            elif duration < rules.SHORT_VIDEO_S:
                assert plan.questions[-1].t_sec < duration
                assert all(q.t_sec <= duration for q in plan.questions)
            else:
                # However many there are, the last is the end-of-video one and
                # none of them lands after the video has finished.
                assert plan.questions[-1].t_sec == max(duration - rules.END_MARGIN_S, 0)
                assert all(q.t_sec <= duration for q in plan.questions)


# --- how many questions a video actually gets -----------------------------------------
#
# The Planner was given a ceiling and no floor, so a model proposing one
# question was inside the rules — and a child watching twenty minutes was asked
# a single thing at minute two and then left alone with it.


def test_a_thin_model_answer_is_topped_up_to_the_target() -> None:
    from heygilli_agents import rules

    one = [{"t_sec": 100, "type": "why", "input": "voice", "text": "Why did it melt?",
            "expected": "the sun"}]
    plan = planner.build_plan(
        Video(id="vidtop", title="Ice", duration_s=1200), SEGMENTS, "7_8", "en",
        agent=agent_with(one),
    )

    assert len(plan.questions) == rules.target_questions("7_8", 1200)
    assert len(plan.questions) >= 2
    # The model's own question about this video survives; the bank fills in.
    assert any(q.text == "Why did it melt?" for q in plan.questions)
    assert len({q.text for q in plan.questions}) == len(plan.questions)


def test_topping_up_never_crowds_the_band_spacing() -> None:
    """A plan that hit the target by putting two questions a minute apart would
    be worse than a short one: the gap is what the band exists to protect."""
    one = [{"t_sec": 100, "type": "why", "input": "voice", "text": "Why?", "expected": "x"}]
    for band in ("4_6", "7_8", "9_11"):
        for duration in (200, 400, 900, 3000):
            plan = planner.build_plan(
                Video(id=f"v{band}{duration}", title="T", duration_s=duration),
                SEGMENTS, band, "en", agent=agent_with(one),
            )
            times = [q.t_sec for q in plan.questions]
            gaps = [b - a for a, b in itertools.pairwise(times)]
            assert all(g >= rules.min_gap_s(band, duration_s=duration) for g in gaps), (
                f"{band}/{duration}: {times}"
            )
            assert len(times) <= rules.max_questions(band, duration), f"{band}/{duration}"
            assert all(t <= duration for t in times), f"{band}/{duration}: {times}"


def test_a_plan_that_already_meets_the_target_is_left_alone() -> None:
    three = [
        {"t_sec": 100, "type": "why", "input": "voice", "text": "Why?", "expected": "x"},
        {"t_sec": 400, "type": "recall", "input": "voice", "text": "What happened?", "expected": "y"},
        {"t_sec": 700, "type": "predict", "input": "voice", "text": "What next?", "expected": "z"},
    ]
    plan = planner.build_plan(
        Video(id="vidfull", title="T", duration_s=1200), SEGMENTS, "7_8", "en",
        agent=agent_with(three),
    )
    assert [q.text for q in plan.questions] == ["Why?", "What happened?", "What next?"], (
        "the bank was used where the model had already answered"
    )


def test_a_plan_cached_under_the_old_count_is_brought_down(
    store: LocalStore, monkeypatch
) -> None:
    """Plans are cached per video and shared by every household, so lowering the
    count changed nothing for anything already planned: a video went on handing
    out the six questions it was given the first time, to everyone, for ever.

    Measured live — a 5m48s video still came back with three after the cap
    shipped, because its plan predated it.
    """
    from heygilli_agents.schemas import Question, QuestionPlan

    video = Video(id="vidcached1", title="Volcanoes", duration_s=348)  # 5m48s -> target 3
    six = [
        Question(t_sec=90 + i * 200, type="recall", input="voice", text=f"q{i}", expected="x")
        for i in range(6)
    ]
    store.put_plan(QuestionPlan(video_id=video.id, age_band="7_8", language="en", questions=six))

    def _never(vid):  # pragma: no cover - a trim must cost no model call
        raise AssertionError("re-planned a video that only needed trimming")

    monkeypatch.setattr(planner, "build_plan", _never)
    plan = planner.ensure_plan(video, "7_8", "en", store)

    want = rules.target_questions("7_8", 348)
    assert want == 3
    assert len(plan.questions) == want
    # The ones kept are the first, which are already in order and already
    # spaced — the front of a correct plan.
    assert [q.text for q in plan.questions] == ["q0", "q1", "q2"]
    # And it is written back, so the next child does not pay for it again.
    assert len(store.get_plan(video.id, "7_8", "en").questions) == want


def test_a_cached_plan_already_within_the_target_is_untouched(store: LocalStore) -> None:
    from heygilli_agents.schemas import Question, QuestionPlan

    video = Video(id="vidcached2", title="Volcanoes", duration_s=1200)
    two = [
        Question(t_sec=90, type="recall", input="voice", text="a", expected="x"),
        Question(t_sec=400, type="why", input="voice", text="b", expected="y"),
    ]
    store.put_plan(QuestionPlan(video_id=video.id, age_band="7_8", language="en", questions=two))
    plan = planner.ensure_plan(video, "7_8", "en", store)
    assert [q.text for q in plan.questions] == ["a", "b"]


# --- a plan written without a transcript is not for ever --------------------------------------


def test_a_stale_fallback_plan_is_replaced_once_the_words_can_be_read(
    store: LocalStore, monkeypatch
) -> None:
    """Every video on the deployed gateway was planned while no transcript
    source could answer, and those bank-question plans were cached for ever:
    adding a Gemini key changed nothing a child could hear. A fallback plan
    old enough is tried again, and a transcript now turns it into questions
    about the video."""
    from datetime import UTC, datetime, timedelta

    video = Video(id="vidstale1", title="Why Do Giraffes Have Long Necks?", duration_s=600)
    stale = planner.fallback_plan(video, "7_8", "en")
    assert stale.source == "none"
    stale.created_at = (datetime.now(UTC) - timedelta(days=2)).isoformat(timespec="seconds")
    store.put_plan(stale)
    video.transcript_source = "none"
    store.put_video(video)

    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: {
        "video_id": vid, "source": "gemini", "segments": SEGMENTS})
    plan = planner.ensure_plan(video, "7_8", "en", store, make_agent("planner", "s", model=FakeModel()))
    assert plan.source == "gemini"
    assert "What did the giraffe eat?" in [q.text for q in plan.questions]
    assert store.get_plan(video.id, "7_8", "en").source == "gemini"
    assert store.get_video(video.id).transcript_source == "gemini"


def test_a_fallback_plan_from_before_source_existed_counts_as_one(store: LocalStore, monkeypatch) -> None:
    """Plans cached before `source` was written carry "". The video's own record
    says whether it was ever read, and "none" there means the same thing."""
    from datetime import UTC, datetime, timedelta

    from heygilli_agents.schemas import Question, QuestionPlan

    video = Video(id="vidstale2", title="Volcanoes", duration_s=600, transcript_source="none")
    old = QuestionPlan(video_id=video.id, age_band="7_8", language="en", questions=[
        Question(t_sec=100, type="recall", input="voice", text="bank q", expected="x")])
    old.created_at = (datetime.now(UTC) - timedelta(hours=3)).isoformat(timespec="seconds")
    assert planner.is_stale_fallback(old, video)
    assert not planner.is_stale_fallback(old, Video(id="v", transcript_source="captions:en:auto"))
    fresh = planner.fallback_plan(video, "7_8", "en")
    assert not planner.is_stale_fallback(fresh, video), "just written; not tried again on every session"


def test_a_fallback_that_still_has_no_transcript_costs_no_model_call(store: LocalStore, monkeypatch) -> None:
    from datetime import UTC, datetime, timedelta

    video = Video(id="vidstale3", title="Volcanoes", duration_s=600, transcript_source="none")
    stale = planner.fallback_plan(video, "7_8", "en")
    stale.created_at = (datetime.now(UTC) - timedelta(hours=3)).isoformat(timespec="seconds")
    store.put_plan(stale)
    store.put_video(video)
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: {"video_id": vid, "source": "none", "segments": []})
    monkeypatch.setattr(planner, "structured", lambda *a, **k: (_ for _ in ()).throw(AssertionError("model called")))
    plan = planner.ensure_plan(video, "7_8", "en", store)
    assert plan.source == "none" and plan.questions
    assert store.get_plan(video.id, "7_8", "en").created_at > stale.created_at, "stamped afresh"


def test_the_prompt_asks_for_hints_and_video_specific_questions() -> None:
    assert "hint" in planner.PLANNER_SYSTEM_PROMPT
    assert "never says the answer" in planner.PLANNER_SYSTEM_PROMPT
    assert "about THIS video" in planner.PLANNER_SYSTEM_PROMPT


def test_hints_survive_the_rules() -> None:
    plan = planner.build_plan(VIDEO, SEGMENTS, "7_8", "en",
                              agent=make_agent("planner", "s", model=FakeModel()))
    hints = {q.text: q.hint for q in plan.questions}
    assert hints.get("Why did the ice melt?") == "Think about where the ice was sitting."


def test_a_video_of_unknown_length_takes_the_transcripts(store: LocalStore, monkeypatch) -> None:
    """Every video the deployed gateway met had duration 0 — the watch page is
    refused to it — so the questions sat at the band's default seconds and an
    end-of-video question had no end to aim at. The transcript source has just
    read the whole video and knows how long it is."""
    video = Video(id="vidlen1", title="Why do cats purr?", duration_s=0)
    store.put_video(video)
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: {
        "video_id": vid, "source": "gemini", "segments": SEGMENTS, "duration_s": 250})
    plan = planner.ensure_plan(video, "7_8", "en", store, make_agent("planner", "s", model=FakeModel()))
    assert store.get_video("vidlen1").duration_s == 250
    # The canned draft proposes questions at 100, 400 and 700 s. With the
    # length unknown all three were kept; against 250 s only the first fits,
    # which is the proof the plan was built with the length.
    assert [q.t_sec for q in plan.questions] == [100]
    assert all(q.t_sec <= 250 - rules.END_MARGIN_S for q in plan.questions)


def test_a_known_length_is_not_overwritten_by_the_transcripts(store: LocalStore, monkeypatch) -> None:
    video = Video(id="vidlen2", title="Volcanoes", duration_s=900)
    store.put_video(video)
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: {
        "video_id": vid, "source": "gemini", "segments": SEGMENTS, "duration_s": 250})
    planner.ensure_plan(video, "7_8", "en", store, make_agent("planner", "s", model=FakeModel()))
    assert store.get_video("vidlen2").duration_s == 900


def test_a_fresh_fallback_is_replaced_at_once_when_the_words_are_already_cached(
    store: LocalStore, monkeypatch
) -> None:
    """A transient refusal at plan time — a 503 at the wrong moment — wrote a
    bank plan; the Curator, or a probe, read the transcript minutes later. The
    plan was the only thing still pretending the video could not be read, and
    it was going to say so for the rest of the hour."""
    video = Video(id="vidcached_words", title="Why do we yawn?", duration_s=0, transcript_source="none")
    store.put_video(video)
    store.put_plan(planner.fallback_plan(video, "7_8", "en"))  # just written; not stale
    store.cache_put("transcript", video.id, {
        "video_id": video.id, "source": "gemini", "segments": SEGMENTS, "duration_s": 516})
    plan = planner.ensure_plan(video, "7_8", "en", store, make_agent("planner", "s", model=FakeModel()))
    assert plan.source == "gemini"
    assert "What did the giraffe eat?" in [q.text for q in plan.questions]
    assert store.get_video(video.id).duration_s == 516


def test_a_fresh_fallback_with_nothing_new_cached_is_served_as_is(store: LocalStore, monkeypatch) -> None:
    video = Video(id="vidcached_none", title="Volcanoes", duration_s=0, transcript_source="none")
    store.put_video(video)
    stale = planner.fallback_plan(video, "7_8", "en")
    store.put_plan(stale)
    monkeypatch.setattr(planner, "fetch_transcript", lambda vid: (_ for _ in ()).throw(AssertionError("fetched")))
    assert planner.ensure_plan(video, "7_8", "en", store) == stale


def test_a_readers_pick_keeps_the_models_words_and_a_pre_readers_does_not() -> None:
    from heygilli_agents.schemas import Option, Question

    q = Question(t_sec=300, type="pick_it", input="pick", text="Why do we yawn when hot?",
                 expected="to cool the brain", options=[
                     Option(label="to cool the brain", correct=True),
                     Option(label="to get more oxygen"),
                     Option(label="because we are bored"),
                 ])
    reader = planner.repair_pick(q, "en", "7_8")
    assert [(o.icon_id, o.label, o.correct) for o in reader.options] == [
        ("", "to cool the brain", True), ("", "to get more oxygen", False), ("", "because we are bored", False)]
    # A label that names a picture still gets it, so a reader's card can be a picture.
    q2 = q.model_copy(update={"options": [Option(label="sun", correct=True),
                                          Option(label="a warm bath"), Option(label="a fever")]})
    fixed = planner.repair_pick(q2, "en", "9_11").options
    assert fixed[0].icon_id == "icon_sun" and fixed[1].icon_id == "" and fixed[2].icon_id == ""
    # The pre-reader path is unchanged: every card is a picture, or the pick is emptied.
    pre = planner.repair_pick(q, "en", "4_6").options
    assert pre == [] or all(o.icon_id for o in pre)
