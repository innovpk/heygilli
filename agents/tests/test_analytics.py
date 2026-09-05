"""Parent analytics: aggregation edges, then the note (cache + refresh), all offline.

`aggregate` is pure, so most of this builds records by hand and never touches the store.
"""
from __future__ import annotations

from datetime import UTC, date, datetime

import pytest

from heygilli_agents import analytics
from heygilli_agents.analytics import (
    aggregate,
    clamp_days,
    concept_label,
    run_analytics,
    window_dates,
    write_note,
)
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import (
    Answer,
    Channel,
    Kid,
    Question,
    QuestionPlan,
    Session,
    Video,
)
from heygilli_agents.store import LocalStore

TODAY = date(2026, 9, 5)
HH = "hh_test"

VIDEOS = {
    "vol00000001": Video(id="vol00000001", channel_id="UCsci", title="Volcanoes!", duration_s=600),
    "song00000001": Video(id="song00000001", channel_id="UCsong", title="Counting Songs", duration_s=300),
}
CHANNELS = {
    "UCsci": Channel(id="UCsci", title="SciShow Kids"),
    "UCsong": Channel(id="UCsong", title="Super Simple Songs"),
}


def plan_9_11() -> QuestionPlan:
    return QuestionPlan(video_id="vol00000001", age_band="9_11", language="en", questions=[
        Question(t_sec=120, type="explain", input="voice",
                 text="Can you explain why Olympus Mons is so much taller than volcanoes on Earth?",
                 expected="Mars has no moving plates"),
        Question(t_sec=300, type="compare", input="voice",
                 text="How do islands form from volcanoes?",
                 expected="Lava erupts, cools and piles up until it breaks the ocean surface."),
    ])


def plan_4_6() -> QuestionPlan:
    return QuestionPlan(video_id="song00000001", age_band="4_6", language="en", questions=[
        Question(t_sec=130, type="name_it", input="voice", text="What animal is that?", expected="giraffe"),
        Question(t_sec=200, type="name_it", input="voice", text="What colour is the ball?", expected="purple"),
        Question(t_sec=260, type="copy_it", input="copy", text="Can you clap?", expected="clap"),
    ])


def plans(*ps: QuestionPlan) -> dict[str, QuestionPlan]:
    return {QuestionPlan.key(p.video_id, p.age_band, p.language): p for p in ps}


def session(kid: Kid, day: str, video: str, band: str, secs: int, sid: str) -> Session:
    return Session(id=sid, household_id=HH, kid_id=kid.id, video_id=video, age_band=band,
                   language="en", watched_sec=secs, date=day)


def older() -> Kid:
    return Kid(id="kid_older", household_id=HH, nickname="Ayaan", age=9)


def prereader() -> Kid:
    return Kid(id="kid_pre", household_id=HH, nickname="Zara", age=4)


def run(kid: Kid, days: int, sessions, answers, ps=None) -> object:
    return aggregate(kid, days, sessions, answers, ps or plans(plan_9_11(), plan_4_6()),
                     VIDEOS, CHANNELS, TODAY)


# --- window ---------------------------------------------------------------------------------------


def test_days_are_clamped_and_the_window_is_inclusive() -> None:
    assert (clamp_days(1), clamp_days(14), clamp_days(365)) == (7, 14, 90)
    dates = window_dates(14, TODAY)
    assert len(dates) == 14 and dates[0] == "2026-08-23" and dates[-1] == "2026-09-05"


def test_session_exactly_on_the_boundary_is_in_the_day_before_is_out() -> None:
    kid = older()
    on_edge = session(kid, "2026-08-23", "vol00000001", "9_11", 600, "ses_edge")
    before = session(kid, "2026-08-22", "vol00000001", "9_11", 600, "ses_before")
    a = run(kid, 14, [on_edge, before], [])
    assert a.totals.sessions == 1 and a.totals.minutes == 10
    assert a.daily[0].date == "2026-08-23" and a.daily[0].minutes == 10


def test_zero_history_kid_is_a_valid_empty_payload() -> None:
    a = run(older(), 14, [], [])
    assert a.totals.model_dump() == {"minutes": 0, "videos": 0, "sessions": 0, "asked": 0,
                                     "answered": 0, "answer_rate": 0.0}  # no divide by zero
    assert len(a.daily) == 14 and all(d.asked == 0 for d in a.daily)
    assert a.concepts == [] and a.needs_another_look == [] and a.channels == []
    assert a.vocabulary.said == [] and a.vocabulary.emerging == [] and a.vocabulary.total_said == 0
    assert a.note.kind == "quiet"


def test_gap_days_are_filled_with_zeros_oldest_first() -> None:
    kid = older()
    sessions = [session(kid, "2026-08-30", "vol00000001", "9_11", 300, "s1"),
                session(kid, "2026-09-05", "vol00000001", "9_11", 600, "s2")]
    a = run(kid, 7, sessions, [])
    assert [d.date for d in a.daily] == ["2026-08-30", "2026-08-31", "2026-09-01", "2026-09-02",
                                         "2026-09-03", "2026-09-04", "2026-09-05"]
    assert [d.minutes for d in a.daily] == [5, 0, 0, 0, 0, 0, 10]


def test_answer_rate_and_daily_counts() -> None:
    kid = older()
    s = session(kid, "2026-09-05", "vol00000001", "9_11", 600, "s1")
    answers = [
        Answer(session_id="s1", question_idx=0, input_used="voice", result="correct", paraphrase="x"),
        Answer(session_id="s1", question_idx=1, input_used="none", result="silence"),
    ]
    a = run(kid, 7, [s], answers)
    assert a.totals.asked == 2 and a.totals.answered == 1 and a.totals.answer_rate == 0.5
    assert a.daily[-1].asked == 2 and a.daily[-1].answered == 1


def test_answers_outside_the_window_are_ignored() -> None:
    kid = older()
    old = session(kid, "2026-07-01", "vol00000001", "9_11", 600, "s_old")
    a = run(kid, 14, [old], [Answer(session_id="s_old", question_idx=0, input_used="voice", result="correct")])
    assert a.totals.asked == 0 and a.totals.sessions == 0


# --- vocabulary -------------------------------------------------------------------------------------


def _vocab_answer(sid: str, idx: int, result: str, word: str | None, used: str = "voice") -> Answer:
    return Answer(session_id=sid, question_idx=idx, input_used=used, result=result, word_said=word)


def test_heard_becomes_said_and_emerging_is_heard_only() -> None:
    kid = prereader()
    s1 = session(kid, "2026-09-01", "song00000001", "4_6", 300, "s1")
    s2 = session(kid, "2026-09-04", "song00000001", "4_6", 300, "s2")
    answers = [
        _vocab_answer("s1", 0, "silence", None, used="none"),   # heard "giraffe", not said
        _vocab_answer("s1", 1, "silence", None, used="none"),   # heard "purple", not said
        _vocab_answer("s2", 0, "partial", "giraffe"),           # now said
        _vocab_answer("s2", 1, "silence", None, used="none"),   # heard "purple" a second time
        _vocab_answer("s2", 2, "correct", None, used="copy"),   # copy_it: never a vocabulary word
    ]
    a = run(kid, 14, [s1, s2], answers)
    v = a.vocabulary
    assert [w.word for w in v.said] == ["giraffe"]
    assert v.said[0].times_said == 1 and v.said[0].first_said == "2026-09-04"
    assert [w.word for w in v.emerging] == ["purple"]
    assert v.emerging[0].times_heard == 2
    assert "clap" not in {w.word for w in v.emerging} | {w.word for w in v.said}
    assert v.total_said == 1


def test_a_voice_answer_scored_correct_counts_as_said_without_word_said() -> None:
    kid = prereader()
    s = session(kid, "2026-09-05", "song00000001", "4_6", 300, "s1")
    a = run(kid, 14, [s], [_vocab_answer("s1", 1, "correct", None)])
    assert [w.word for w in a.vocabulary.said] == ["purple"]
    assert a.vocabulary.emerging == []


def test_new_this_week_boundary() -> None:
    kid = prereader()
    # window ends 2026-09-05, so "this week" is 2026-08-30 .. 2026-09-05
    inside = session(kid, "2026-08-30", "song00000001", "4_6", 60, "s_in")
    outside = session(kid, "2026-08-29", "song00000001", "4_6", 60, "s_out")
    answers = [_vocab_answer("s_in", 0, "correct", "giraffe"),
               _vocab_answer("s_out", 1, "correct", "purple")]
    a = run(kid, 14, [inside, outside], answers)
    assert a.vocabulary.total_said == 2
    assert a.vocabulary.new_this_week == 1  # giraffe only; purple was first said one day earlier
    assert [w.word for w in a.vocabulary.said] == ["giraffe", "purple"]  # most recent first


def test_vocabulary_is_computed_for_older_bands_but_sentences_are_not_words() -> None:
    """An older band's `expected` is usually a whole sentence; only real words count."""
    kid = older()
    plan = QuestionPlan(video_id="vol00000001", age_band="9_11", language="en", questions=[
        Question(t_sec=120, type="explain", input="voice", text="What is the biggest volcano?",
                 expected="Olympus Mons"),
        Question(t_sec=300, type="compare", input="voice", text="How do islands form?",
                 expected="Lava erupts, cools and piles up until it breaks the surface."),
    ])
    s = session(kid, "2026-09-05", "vol00000001", "9_11", 600, "s1")
    a = run(kid, 7, [s], [_vocab_answer("s1", 0, "correct", None),
                          _vocab_answer("s1", 1, "correct", None)], plans(plan))
    assert [w.word for w in a.vocabulary.said] == ["Olympus Mons"]
    assert a.vocabulary.emerging == []


# --- concepts -----------------------------------------------------------------------------------------


def test_concept_labels_come_from_the_question_not_the_answer() -> None:
    q = plan_9_11().questions
    assert concept_label(q[0]) == "Mars has no moving plates"   # short expected wins
    assert concept_label(q[1]) == "Islands form from volcanoes"  # long expected -> question subject
    assert concept_label(Question(t_sec=1, type="why", input="voice", text="?", expected=""),
                         fallback="Volcanoes!") == "Volcanoes"


def test_concepts_and_needs_another_look_need_two_separate_days() -> None:
    kid = older()
    days = ["2026-09-01", "2026-09-02", "2026-09-03"]
    sessions, answers = [], []
    for i, d in enumerate(days):
        sid = f"s{i}"
        sessions.append(session(kid, d, "vol00000001", "9_11", 300, sid))
        # question 0 is shaky on all three days, question 1 is shaky twice on ONE day only
        answers.append(Answer(session_id=sid, question_idx=0, input_used="voice", result="partial"))
    sessions.append(session(kid, "2026-09-04", "vol00000001", "9_11", 300, "s_bad"))
    answers += [Answer(session_id="s_bad", question_idx=1, input_used="voice", result="off_topic"),
                Answer(session_id="s_bad", question_idx=1, input_used="voice", result="unclear")]

    a = run(kid, 14, sessions, answers)
    by_concept = {c.concept: c for c in a.concepts}
    assert by_concept["Mars has no moving plates"].shaky == 3
    assert by_concept["Islands form from volcanoes"].shaky == 2
    review = {c.concept: c.times_shaky for c in a.needs_another_look}
    assert review == {"Mars has no moving plates": 3}  # one bad day is not a pattern
    assert a.needs_another_look[0].last_seen == "2026-09-03"


def test_silence_is_neither_understood_nor_shaky() -> None:
    kid = older()
    s = session(kid, "2026-09-05", "vol00000001", "9_11", 600, "s1")
    a = run(kid, 7, [s], [Answer(session_id="s1", question_idx=0, input_used="none", result="silence")])
    c = a.concepts[0]
    assert (c.asked, c.understood, c.shaky) == (1, 0, 0) and a.needs_another_look == []


def test_prereader_gets_no_concepts() -> None:
    kid = prereader()
    s = session(kid, "2026-09-05", "song00000001", "4_6", 300, "s1")
    a = run(kid, 7, [s], [_vocab_answer("s1", 0, "correct", "giraffe")])
    assert a.band == "4_6" and a.concepts == [] and a.needs_another_look == []


# --- channels ------------------------------------------------------------------------------------------


def test_channels_are_ordered_by_minutes_desc() -> None:
    kid = older()
    sessions = [
        session(kid, "2026-09-05", "song00000001", "9_11", 120, "s1"),
        session(kid, "2026-09-05", "vol00000001", "9_11", 600, "s2"),
        session(kid, "2026-09-04", "vol00000001", "9_11", 300, "s3"),
    ]
    a = run(kid, 7, sessions, [])
    assert [(c.title, c.minutes, c.videos) for c in a.channels] == [
        ("SciShow Kids", 15, 1),
        ("Super Simple Songs", 2, 1),
    ]


def test_unknown_channel_falls_back_to_the_id() -> None:
    kid = older()
    s = session(kid, "2026-09-05", "mystery0001", "9_11", 600, "s1")
    a = aggregate(kid, 7, [s], [], plans(plan_9_11()), {}, {}, TODAY)
    assert a.channels == [] or a.channels[0].channel_id == "unknown"
    assert a.channels[0].title == "unknown" and a.channels[0].minutes == 10


# --- the note ----------------------------------------------------------------------------------------


def _counting_model() -> FakeModel:
    """A fake whose note text changes every call, so a cache hit is visible."""
    calls = {"n": 0}

    def canned(name: str, text: str) -> dict:
        if name != "AnalyticsNote":
            return {}
        if text:  # "" is FakeModel probing which structured-output tool this is
            calls["n"] += 1
        return {"kind": "praise", "text": f"note number {max(calls['n'], 1)}"}

    model = FakeModel(canned)
    return model


def _seed(store: LocalStore, kid: Kid) -> None:
    store.put_kid(kid)
    store.put_video(VIDEOS["vol00000001"])
    store.put_plan(plan_9_11())
    store.put_channel(HH, kid.id, CHANNELS["UCsci"])
    s = session(kid, TODAY.isoformat(), "vol00000001", "9_11", 600, "s1")
    store.put_session(s)
    store.put_answer(HH, Answer(session_id=s.id, question_idx=0, input_used="voice", result="correct"))


def test_note_is_cached_and_refresh_bypasses_the_cache(store: LocalStore) -> None:
    kid = older()
    _seed(store, kid)
    model = _counting_model()

    def agent():
        return make_agent("digest", "s", model=model)

    first = run_analytics(kid, 14, store, agent=agent(), today=TODAY)
    assert first.note.kind == "praise" and first.note.text == "note number 1"

    again = run_analytics(kid, 14, store, agent=agent(), today=TODAY)
    assert again.note.text == "note number 1"  # cache hit: the model was not called again

    fresh = run_analytics(kid, 14, store, refresh=True, agent=agent(), today=TODAY)
    assert fresh.note.text == "note number 2"

    assert [c["model"] for c in model.calls] == ["AnalyticsNote", "AnalyticsNote"]


def test_note_cache_key_moves_when_the_numbers_move(store: LocalStore) -> None:
    kid = older()
    _seed(store, kid)
    a = run_analytics(kid, 14, store, agent=make_agent("digest", "s", model=FakeModel()), today=TODAY)
    key_before = analytics.note_cache_key(a)
    store.put_session(session(kid, TODAY.isoformat(), "vol00000001", "9_11", 3000, "s2"))
    b = run_analytics(kid, 14, store, agent=make_agent("digest", "s", model=FakeModel()), today=TODAY)
    assert analytics.note_cache_key(b) != key_before


def test_note_falls_back_to_quiet_when_the_model_fails(store: LocalStore) -> None:
    kid = older()
    _seed(store, kid)

    class Boom:
        def __call__(self, *a, **k):
            raise RuntimeError("provider down")

    a = run_analytics(kid, 14, store, agent=Boom(), today=TODAY)
    assert a.note.kind == "quiet" and a.note.text


def test_zero_history_kid_never_calls_the_model(store: LocalStore) -> None:
    kid = older()
    store.put_kid(kid)
    model = FakeModel()
    a = run_analytics(kid, 14, store, agent=make_agent("digest", "s", model=model), today=TODAY)
    assert a.note.kind == "quiet" and model.calls == []
    assert a.totals.sessions == 0 and len(a.daily) == 14


# --- the route ---------------------------------------------------------------------------------------


@pytest.fixture
def client():
    from fastapi.testclient import TestClient

    from heygilli_agents import gateway

    return TestClient(gateway.app)


def test_analytics_endpoint(client, store: LocalStore) -> None:
    auth = client.post("/auth/dev", json={"name": "Analytics Parent"}).json()
    hdr = {"Authorization": f"Bearer {auth['token']}"}
    hid = auth["household_id"]
    kid = client.post("/kids", json={"nickname": "Ayaan", "age": 9}, headers=hdr).json()

    empty = client.get(f"/kids/{kid['id']}/analytics", headers=hdr)
    assert empty.status_code == 200
    body = empty.json()
    assert body["days"] == 14 and body["band"] == "9_11" and len(body["daily"]) == 14
    assert body["totals"]["answer_rate"] == 0.0 and body["note"]["kind"] == "quiet"
    assert set(body) == {"kid_id", "band", "days", "generated_at", "totals", "daily", "vocabulary",
                         "concepts", "needs_another_look", "channels", "note"}

    store.put_video(VIDEOS["vol00000001"])
    store.put_plan(plan_9_11())
    s = Session(id="ses_route", household_id=hid, kid_id=kid["id"], video_id="vol00000001",
                age_band="9_11", language="en", watched_sec=600,
                date=datetime.now(UTC).date().isoformat())
    store.put_session(s)
    store.put_answer(hid, Answer(session_id=s.id, question_idx=0, input_used="voice", result="correct"))

    body = client.get(f"/kids/{kid['id']}/analytics?days=200", headers=hdr).json()
    assert body["days"] == 90 and len(body["daily"]) == 90  # clamped
    assert body["totals"] == {"minutes": 10, "videos": 1, "sessions": 1, "asked": 1,
                              "answered": 1, "answer_rate": 1.0}
    assert body["concepts"][0]["concept"] == "Mars has no moving plates"
    assert body["note"]["text"]
    assert client.get(f"/kids/{kid['id']}/analytics?days=1", headers=hdr).json()["days"] == 7
    assert client.get("/kids/nope/analytics", headers=hdr).status_code == 404
    assert client.get(f"/kids/{kid['id']}/analytics").status_code == 401


# --- label quality and note honesty -------------------------------------------------------------------


def test_a_long_question_is_not_truncated_into_a_fragment() -> None:
    """Slicing produced labels like "New planet was discovered with similar"."""
    long_q = Question(
        t_sec=90,
        type="explain",
        input="voice",
        text="Why was the new planet discovered with a composition similar to our own?",
        expected="",
    )
    # No usable short subject and no expected answer: say so rather than emit half a sentence.
    assert concept_label(long_q) == "This video"
    assert concept_label(long_q, fallback="Planets") == "Planets"


def test_a_short_clause_is_still_a_good_label() -> None:
    short_q = Question(
        t_sec=90, type="why", input="voice", text="Why do islands form?", expected=""
    )
    assert concept_label(short_q) == "Islands form"


def test_a_window_where_nobody_answered_never_praises_the_child() -> None:
    """A weaker model writes "great questions this week!" over silence. Deterministic instead."""
    kid = older()
    sessions = [session(kid, "2026-09-05", "vol00000001", "9_11", 300, "s1")]
    answers = [
        Answer(session_id="s1", question_idx=0, input_used="none", result="silence"),
        Answer(session_id="s1", question_idx=1, input_used="none", result="silence"),
    ]
    a = run(kid, 14, sessions, answers)
    assert a.totals.asked > 0
    assert a.totals.answered == 0

    note = write_note(a, kid, agent=make_agent("digest", "s", model=FakeModel()))
    assert note.kind == "watch"
    assert "heard nothing back" in note.text
    assert "great" not in note.text.lower()
