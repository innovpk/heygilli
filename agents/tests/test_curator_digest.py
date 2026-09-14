"""Curator and Digest pipelines end to end on the fake model, network mocked."""
from __future__ import annotations

import pytest

from heygilli_agents import curator, digest
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Answer, Channel, Kid, Session, Video
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


def test_the_curator_screens_against_a_looked_up_length(
    store: LocalStore, monkeypatch
) -> None:
    """The length the ceiling is applied to comes from `videos.list`, one call
    for the whole channel.

    The watch page is the only other source and YouTube refuses it to
    datacenter addresses, so on the deployed gateway every video was screened
    with `duration_s: 0` — "we could not find out", which the ceiling skips.
    A 2h13m film reached an eight-year-old that way. Here that same film is
    measured and kept off the shelf, and the ordinary one beside it is not.
    """
    kid = Kid(household_id="hh", nickname="Zara", age=8, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    uploads = [
        {"id": "thefilm001", "channel_id": "UCx", "title": "A Long Documentary",
         "published_at": "2026-09-01", "thumb_url": "t", "description": "About space."},
        {"id": "goodvideo01", "channel_id": "UCx", "title": "Why Do Giraffes Have Long Necks?",
         "published_at": "2026-09-02", "thumb_url": "t", "description": "Learn about giraffes."},
    ]
    asked: list[list[str]] = []

    def _durations(ids):
        asked.append(list(ids))
        return {"thefilm001": 8020, "goodvideo01": 600}  # 2h13m40s, and 10m

    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: uploads)
    monkeypatch.setattr(curator, "fetch_durations", _durations)
    # The watch page, refused in production. If the length came from here the
    # test would prove nothing about the path that actually runs.
    monkeypatch.setattr(curator, "fetch_video_meta",
                        lambda vid: {"duration_s": 0, "thumb_url": "t"})
    monkeypatch.setattr(curator, "fetch_transcript",
                        lambda vid: {"video_id": vid, "source": "captions:en:auto",
                                     "segments": SEGMENTS})
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript",
                        lambda vid: {"video_id": vid, "source": "captions:en:auto",
                                     "segments": SEGMENTS})

    model = FakeModel()
    report = curator.run_curator(kid, store, curator=make_agent("curator", "s", model=model),
                                 planner=make_agent("planner", "s", model=model))

    assert store.get_video("thefilm001").duration_s == 8020, "the length was not recorded"
    assert [v["id"] for v in report.hidden] == ["thefilm001"]
    assert [v["id"] for v in report.approved] == ["goodvideo01"]
    assert "35" in store.list_kid_videos("hh", kid.id)["thefilm001"]["reason"], (
        "the parent is not told which ceiling it passed"
    )
    # One call for the channel, not one per video: that is what makes reading
    # every upload's length affordable on every run.
    assert asked == [["thefilm001", "goodvideo01"]]


def test_run_digest_counts_in_code_and_words_from_model(store: LocalStore) -> None:
    kid = Kid(household_id="hh", nickname="Ayaan", age=5)
    store.put_kid(kid)
    from heygilli_agents.schemas import Question, QuestionPlan

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


def test_a_blocked_ip_falls_back_to_titles_and_says_so(
    store: LocalStore, monkeypatch
) -> None:
    """YouTube rate-limits a machine that fetches many captions in a row, and
    refuses datacenter addresses outright — which is where this runs.

    This used to end the run, so that a screening done on titles could not pass
    for one done on transcripts. That protected the wrong thing: the refusal is
    permanent in production, so it did not mean "screen fewer videos", it meant
    a child with an empty screen for ever.

    So the run carries on from the title and description. What must still hold
    is the honesty the old guard was really after: the endpoint must not 500,
    every video read that way is stored as `transcript_source: "none"` — which
    the app shows as "read: title only" — and the report says how many and why.
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

    # It came back rather than raising, and every upload was judged — the one
    # that had a transcript and the two that had to be read on their titles.
    assert report.stopped_early == "", "the run finished; saying it stopped would be a lie"
    decided = len(report.approved) + len(report.hidden) + len(report.ask_parent)
    assert decided == len(UPLOADS), "a child was left with nothing rather than with less"
    assert len(store.list_kid_videos("hh", kid.id)) == len(UPLOADS)

    # And it says so, rather than passing the weaker reads off as full ones.
    assert report.read_titles_only == len(UPLOADS) - 1
    assert "the request was blocked" in report.no_transcripts, report.no_transcripts
    sources = {vid: (store.get_video(vid) or Video(id=vid)).transcript_source
               for vid in store.list_kid_videos("hh", kid.id)}
    assert sorted(sources.values()) == ["captions:en:auto", "none", "none"], sources


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


# --- a bad fifteen minutes must not cost a child real questions for ever -------------------------
#
# A transcript failure is nearly always temporary: a Gemini quota window, a
# 503, a rate-limited caption fetch. The run that hits one writes a fallback
# plan — one general end-of-video question, the same one for every video it
# happened to — and that plan is cached forever while the video sits in `seen`.
# So the next run skipped it, and the child kept "what was your favourite bit?"
# on a video the words for were available again fifteen minutes later.


def _transcripts(available: bool):
    def fetch(video_id: str) -> dict:
        if not available:
            raise TranscriptsBlocked("the request was blocked")
        return {"video_id": video_id, "source": "captions:en:auto", "segments": SEGMENTS}

    return fetch


def _set_transcripts(monkeypatch, available: bool) -> None:
    monkeypatch.setattr(curator, "fetch_transcript", _transcripts(available))
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript", _transcripts(available))


def _kid_with_channel(store: LocalStore, monkeypatch) -> Kid:
    kid = Kid(household_id="hh", nickname="Abu", age=8, languages=["en"])
    store.put_kid(kid)
    store.put_channel("hh", kid.id, Channel(id="UCx", title="SciShow Kids"))
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: UPLOADS)
    monkeypatch.setattr(curator, "fetch_video_meta", lambda vid: {"duration_s": 600, "thumb_url": "t"})
    return kid


def _run(kid: Kid, store: LocalStore) -> curator.CuratorReport:
    model = FakeModel()
    return curator.run_curator(
        kid, store,
        curator=make_agent("curator", "s", model=model),
        planner=make_agent("planner", "s", model=model),
    )


def test_a_video_read_on_its_title_is_read_properly_when_the_words_come_back(
    store: LocalStore, monkeypatch
) -> None:
    kid = _kid_with_channel(store, monkeypatch)

    _set_transcripts(monkeypatch, available=False)
    first = _run(kid, store)
    assert first.read_titles_only == len(UPLOADS), "the fixture stopped blocking transcripts"
    assert first.reread == 0, "nothing was readable, so there was nothing to go back to"
    assert store.get_video("goodvideo01").transcript_source == "none"
    fallback = store.get_plan("goodvideo01", "7_8", "en")
    # A fallback plan is one written from the bank rather than from the video,
    # which is what its questions being bank wordings says. The count used to
    # identify it — there was exactly one — and that stopped being true when a
    # transcript-less plan went from one question to two or three.
    from heygilli_agents import question_bank

    assert fallback is not None
    assert fallback.source in ("none", "metadata")

    _set_transcripts(monkeypatch, available=True)
    second = _run(kid, store)

    assert second.reread == 1
    assert store.get_video("goodvideo01").transcript_source == "captions:en:auto"
    now = store.get_plan("goodvideo01", "7_8", "en")
    assert now is not None and (now.questions != fallback.questions or now.source != fallback.source), (
        "the cached fallback plan survived, so the child still gets the same one question"
    )


def test_going_back_over_a_shelf_never_redecides_what_is_on_it(
    store: LocalStore, monkeypatch
) -> None:
    """A transcript is new evidence, and re-deciding on it would take back an
    answer somebody gave. A video on this shelf either passed screening or a
    parent put it there by hand; the words only change what Gilli *asks*."""
    kid = _kid_with_channel(store, monkeypatch)
    _set_transcripts(monkeypatch, available=False)
    _run(kid, store)
    before = {v: e["status"] for v, e in store.list_kid_videos("hh", kid.id).items()}
    assert sorted(before.values()) == ["approve", "ask_parent", "hide"], before

    _set_transcripts(monkeypatch, available=True)
    _run(kid, store)

    assert {v: e["status"] for v, e in store.list_kid_videos("hh", kid.id).items()} == before
    # And the ones that are not on the shelf were not spent on either: a
    # re-read is a transcript fetch and a Planner call, and a hidden video has
    # nobody to ask questions of.
    assert store.get_video("scaryvideo1").transcript_source == "none"
    assert store.get_video("borderline1").transcript_source == "none"


def test_a_refusal_stops_the_backlog_rather_than_being_asked_once_per_video(
    store: LocalStore, monkeypatch
) -> None:
    """The refusal is about this machine, not this video, so the first one
    answers for all of them. Carrying on would be a fetch per video for the
    same refusal each time, on top of a run that has already got nowhere."""
    kid = _kid_with_channel(store, monkeypatch)
    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: [])
    for i in range(5):
        vid = f"backlog{i:04d}"
        store.put_video(Video(id=vid, title=f"Old {i}", duration_s=600, transcript_source="none"))
        store.set_kid_video("hh", kid.id, vid, "approve", "screened on its title")

    calls: list[str] = []

    def counted(video_id: str) -> dict:
        calls.append(video_id)
        raise TranscriptsBlocked("the request was blocked")

    monkeypatch.setattr(curator, "fetch_transcript", counted)
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript", counted)
    report = _run(kid, store)

    assert report.reread == 0
    assert len(calls) == 1, f"asked {len(calls)} times for one answer"


def test_a_run_that_already_hit_the_wall_does_not_spend_anything_going_back(
    store: LocalStore, monkeypatch
) -> None:
    """Screening this run's own uploads established that the words are not
    available. Going back over the shelf afterwards would ask again for the
    same refusal, having just been told."""
    kid = _kid_with_channel(store, monkeypatch)
    store.put_video(Video(id="oldvideo001", title="Old", duration_s=600, transcript_source="none"))
    store.set_kid_video("hh", kid.id, "oldvideo001", "approve", "screened on its title")

    calls: list[str] = []

    def counted(video_id: str) -> dict:
        calls.append(video_id)
        raise TranscriptsBlocked("the request was blocked")

    monkeypatch.setattr(curator, "fetch_transcript", counted)
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript", counted)
    report = _run(kid, store)

    assert report.no_transcripts, "the fixture did not block the run's own uploads"
    assert report.reread == 0
    # Asked once, told once, and the latch carried the answer to the rest of
    # the run — including the backlog, which was never asked about at all.
    #
    # Counted rather than named: the backlog is walked in insertion order and
    # `goodvideo01` is ahead of it, so a re-read that ran anyway would break on
    # that one and never name `oldvideo001` at all. Only the extra call shows.
    assert calls == ["goodvideo01", "goodvideo01"], (
        "one for the upload, one for its plan; a third is the backlog being "
        f"asked after the run had just been told: {calls}"
    )


def test_going_back_is_capped_so_new_uploads_stay_the_point_of_the_run(
    store: LocalStore, monkeypatch
) -> None:
    kid = _kid_with_channel(store, monkeypatch)
    backlog = curator.REREAD_PER_RUN + 4
    for i in range(backlog):
        vid = f"backlog{i:04d}"
        store.put_video(Video(id=vid, title=f"Old {i}", duration_s=600, transcript_source="none"))
        store.set_kid_video("hh", kid.id, vid, "approve", "screened on its title")

    fetched: list[str] = []

    def counted(video_id: str) -> dict:
        fetched.append(video_id)
        return {"video_id": video_id, "source": "captions:en:auto", "segments": SEGMENTS}

    monkeypatch.setattr(curator, "fetch_uploads", lambda cid, limit: [])
    monkeypatch.setattr(curator, "fetch_transcript", counted)
    monkeypatch.setattr("heygilli_agents.planner.fetch_transcript", counted)

    report = _run(kid, store)

    assert report.reread == curator.REREAD_PER_RUN
    assert len(fetched) == curator.REREAD_PER_RUN
    # The rest are still waiting, so the next run picks them up.
    left = [v for v in store.list_kid_videos("hh", kid.id)
            if (store.get_video(v) or Video(id=v)).transcript_source == "none"]
    assert len(left) == backlog - curator.REREAD_PER_RUN


def test_a_video_is_marked_read_only_once_its_plans_are_written(
    store: LocalStore, monkeypatch
) -> None:
    """`transcript_source` is the only thing that brings a video back here.

    Marking it read before the plans exist loses it for good on any failure
    partway through: it would claim a transcript it never used, and nothing
    would ever come back for it.
    """
    kid = _kid_with_channel(store, monkeypatch)
    store.put_video(Video(id="oldvideo001", title="Old", duration_s=600, transcript_source="none"))
    store.set_kid_video("hh", kid.id, "oldvideo001", "approve", "screened on its title")
    monkeypatch.setattr(curator, "fetch_transcript", _transcripts(available=True))

    def exploding(*args, **kwargs):
        raise RuntimeError("the planner fell over")

    monkeypatch.setattr(curator, "build_plan", exploding)

    with pytest.raises(RuntimeError):
        curator.reread_titles_only(kid, store)

    assert store.get_video("oldvideo001").transcript_source == "none", (
        "the video claims a transcript it never used, so nothing will come back for it"
    )


# --- what the family asked for -------------------------------------------------------
#
# The rule lived in the prompt and held until the prompt also asked for a fuller
# `reason`. Then the Curator began approving Crash Course *Literature* for a
# household that asked for science, writing "aligns with the parent's request
# for science content" underneath it. A check the model can compose its way
# around is not a check.


def test_a_video_that_is_not_what_the_family_asked_for_goes_to_the_parent() -> None:
    from heygilli_agents.schemas import CuratorDecision

    approved_off_topic = CuratorDecision(
        decision="approve", reason="It teaches how to find themes in a novel.",
        matches_wanted=False,
    )
    out = curator.apply_wanted(approved_off_topic, ["science"])

    assert out.decision == "ask_parent", "an off-topic video was approved for the child"
    assert "not one of the things you asked for" in out.reason
    assert "science" in out.reason, "the parent is not told which topic it missed"
    # The model's own words survive: the parent still learns what it *is*.
    assert "find themes" in out.reason


def test_decide_actually_applies_the_check() -> None:
    """Testing `apply_wanted` alone proves nothing about whether anything calls
    it — which is the very shape of the bug being fixed here: a check that
    exists and does not run."""
    from heygilli_agents.schemas import Video

    def off_topic(model_name: str, text: str) -> dict:
        assert model_name == "CuratorDecision", model_name
        return {"decision": "approve", "reason": "It teaches how to find themes in a novel.",
                "topics": ["literature"], "matches_wanted": False}

    out = curator.decide(
        Video(id="lit0000001", title="How to find themes", description="A novel.",
              duration_s=600),
        "7_8", make_agent("curator", "s", model=FakeModel(canned=off_topic)),
        "excerpt about a novel", wanted_topics=["science"],
    )

    assert out.decision == "ask_parent", "decide() approved an off-topic video"
    assert "not one of the things you asked for" in out.reason
    assert "find themes" in out.reason, "the model's own words were thrown away"


def test_being_off_topic_never_hides_a_video() -> None:
    """Wanting science is a preference, not a safety rule, so it goes to the
    parent rather than being decided for them."""
    from heygilli_agents.schemas import CuratorDecision

    out = curator.apply_wanted(
        CuratorDecision(decision="approve", reason="r", matches_wanted=False), ["science"]
    )
    assert out.decision != "hide"


def test_a_video_that_is_what_they_asked_for_is_left_alone() -> None:
    from heygilli_agents.schemas import CuratorDecision

    on_topic = CuratorDecision(decision="approve", reason="Volcano shapes and eruptions.",
                               matches_wanted=True)
    assert curator.apply_wanted(on_topic, ["science"]) == on_topic
    # And a household that asked for nothing in particular is not second-guessed.
    off = CuratorDecision(decision="approve", reason="r", matches_wanted=False)
    assert curator.apply_wanted(off, []) == off


def test_an_off_topic_hide_is_not_quietly_softened_into_a_question() -> None:
    """`hide` is a safety verdict. Being off-topic as well must not turn it into
    something the parent is invited to allow — that would launder a hide."""
    from heygilli_agents.schemas import CuratorDecision

    hidden = CuratorDecision(decision="hide", reason="Scary throughout.", matches_wanted=False)
    assert curator.apply_wanted(hidden, ["science"]).decision == "hide"


# --- reasons that talk to the parent instead of about the video ----------------------
#
# "Please let me know if this video is acceptable." closed all eleven reasons in
# one live run. It sits beside a switch the parent is already reaching for.


@pytest.mark.parametrize(
    ("written", "kept"),
    [
        ("It explains volcano shapes. Please let me know if this video is acceptable.",
         "It explains volcano shapes."),
        ("It explains volcano shapes. Let me know if this is okay.",
         "It explains volcano shapes."),
        ("Slugs and dung beetles, calmly told. Kindly confirm.",
         "Slugs and dung beetles, calmly told."),
        # Untouched: nothing to drop.
        ("It explains volcano shapes.", "It explains volcano shapes."),
        # The words, but as part of what the video does — the thing the parent
        # most needs to hear. Matching anywhere cut this to "The presenter says".
        ("The presenter says let me know in the comments, which is a call to action.",
         "The presenter says let me know in the comments, which is a call to action."),
        # The same, with a sentence before it so the "only one sentence" guard
        # is not what saves it: the anchor has to be doing the work.
        (
            (
                "It is calm throughout. "
                "The presenter says let me know in the comments, which is a call to action."
            ),
            (
                "It is calm throughout. "
                "The presenter says let me know in the comments, which is a call to action."
            ),
        ),
        # Nothing but a plea: leave it. A reason cut to nothing is worse.
        ("Please let me know if this video is acceptable.",
         "Please let me know if this video is acceptable."),
    ],
)
def test_a_closing_plea_is_dropped_and_nothing_else_is(written: str, kept: str) -> None:
    assert curator.tidy_reason(written) == kept


def test_decide_tidies_what_the_model_actually_returns() -> None:
    """Same trap as `apply_wanted`: a tidier nothing calls is not a tidier."""
    from heygilli_agents.schemas import Video

    def pleading(model_name: str, text: str) -> dict:
        return {"decision": "approve",
                "reason": "It walks through how lava cools into rock. "
                          "Please let me know if this video is acceptable.",
                "topics": ["science"], "matches_wanted": True}

    out = curator.decide(
        Video(id="vol0000001", title="Lava", description="Rocks.", duration_s=600),
        "7_8", make_agent("curator", "s", model=FakeModel(canned=pleading)), "excerpt",
    )
    assert out.reason == "It walks through how lava cools into rock."
