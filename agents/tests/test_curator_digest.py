"""Curator and Digest pipelines end to end on the fake model, network mocked."""
from __future__ import annotations

from heygilli_agents import curator, digest
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Answer, Channel, Kid, Session
from heygilli_agents.store import LocalStore
from heygilli_agents.tools.transcript import TranscriptsBlocked

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


def _blocking_after(n: int):
    """A transcript fetcher that works n times, then YouTube cuts us off."""
    seen: list[str] = []

    def fetch(video_id: str) -> dict:
        seen.append(video_id)
        if len(seen) > n:
            raise TranscriptsBlocked("the request was blocked")
        return {"video_id": video_id, "source": "captions:en:auto", "segments": SEGMENTS}

    return fetch


def test_a_blocked_ip_stops_the_run_instead_of_screening_on_titles(
    store: LocalStore, monkeypatch
) -> None:
    """YouTube rate-limits a machine that fetches many captions in a row, and it
    happened on the first real run over a household's own channels.

    Two things must not happen. The endpoint must not 500 — it did, after three
    and a half minutes of real work that was already saved. And the run must not
    carry on: `excerpt` falls back to "(no transcript)", so every remaining
    video would be screened on its title alone and the decisions would be
    indistinguishable from ones made with the transcript.
    """
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: UPLOADS)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(curator, "fetch_transcript", _blocking_after(1))
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:en:auto", "segments": SEGMENTS},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )

    # It came back rather than raising, and the first video's real decision kept.
    assert report.stopped_early, "a partial run that reports itself as whole is the worst outcome"
    assert "unscreened" in report.stopped_early
    # Carrying the cause matters as much as reporting the stop: "nothing was
    # screened" without it sends whoever reads it to check the wrong thing.
    assert "the request was blocked" in report.stopped_early, report.stopped_early
    decided = len(report.approved) + len(report.hidden) + len(report.ask_parent)
    assert decided == 1, "only the video that had a transcript was judged"
    # And nothing was invented for the two it never got to.
    assert len(store.list_kid_videos("hh", kid.id)) == 1


def test_a_complete_run_does_not_claim_it_stopped(store: LocalStore, monkeypatch) -> None:
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: UPLOADS)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(curator, "fetch_transcript", _blocking_after(99))
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:en:auto", "segments": SEGMENTS},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )
    assert report.stopped_early == ""
    assert len(report.approved) + len(report.hidden) + len(report.ask_parent) == 3


def test_one_video_without_captions_does_not_stop_anything(
    store: LocalStore, monkeypatch
) -> None:
    """The ordinary case, and the one the fix must not break: plenty of kids'
    videos have captions disabled, and they are screened on what is known."""
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: UPLOADS)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(
        curator, "fetch_transcript",
        lambda vid: {"video_id": vid, "source": "none", "segments": []},
    )
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "none", "segments": []},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )
    assert report.stopped_early == ""
    assert len(report.approved) + len(report.hidden) + len(report.ask_parent) == 3


# --- a child cannot answer a question about a video they cannot understand ----------------------
#
# The first real run over a household's own subscriptions put Russian and
# Spanish toy videos on an English-only five-year-old's home. The kid's
# `languages` was already set; nothing screened against it.


def _uploads_langs() -> list[dict]:
    return [{"id": "englishvid1", "channel_id": "UCx", "title": "Why Do Giraffes Have Long Necks?",
             "published_at": "2026-09-01", "thumb_url": "", "description": "Learn about giraffes."}]


def test_a_video_in_another_language_is_not_offered(store: LocalStore, monkeypatch) -> None:
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="Toys"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: _uploads_langs())
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(
        curator, "fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:ru:auto", "segments": SEGMENTS},
    )
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:ru:auto", "segments": SEGMENTS},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )
    assert [v["id"] for v in report.hidden] == ["englishvid1"]
    assert "ru" in report.hidden[0]["reason"]
    # Decided in code, so it never cost a model call and a model could not
    # overrule it by liking the thumbnail.
    assert model.calls == []


def test_a_language_the_child_does_speak_is_left_alone(store: LocalStore, monkeypatch) -> None:
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en", "ur"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="Toys"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: _uploads_langs())
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(
        curator, "fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:ur:manual", "segments": SEGMENTS},
    )
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "captions:ur:manual", "segments": SEGMENTS},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )
    assert report.hidden == [], "an Urdu video was hidden from an Urdu speaker"


def test_no_captions_is_not_treated_as_a_foreign_language(store: LocalStore, monkeypatch) -> None:
    """Plenty of good children's videos have captions disabled. Hiding
    everything we cannot identify would empty the shelf, which is the failure
    the language check must not trade itself for."""
    kid = Kid(household_id="hh", nickname="Abu", age=5, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="Toys"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: _uploads_langs())
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    monkeypatch.setattr(
        curator, "fetch_transcript",
        lambda vid: {"video_id": vid, "source": "none", "segments": []},
    )
    monkeypatch.setattr(
        "heygilli_agents.planner.fetch_transcript",
        lambda vid: {"video_id": vid, "source": "none", "segments": []},
    )

    model = FakeModel()
    report = curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )
    assert report.hidden == []


def test_region_tagged_captions_still_match(store: LocalStore) -> None:
    # "en-GB" and "es-419" are ordinary caption codes; a naive equality check
    # would hide an English video from an English speaker.
    assert curator.understandable("captions:en-GB:auto", ["en"])
    assert curator.understandable("captions:es-419:manual", ["es"])
    assert not curator.understandable("captions:ru:auto", ["en", "ur"])
