"""Time limits, break accounting, and the safety gate (PROTOCOL.md).

Offline: every function under test is pure, so the clock is passed in and no
model, store or network is involved.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta

import pytest

from heygilli_agents import breaks
from heygilli_agents.schemas import (
    AgeBand,
    BreakMessage,
    BreakPeriod,
    BreakTask,
    Kid,
    Session,
    WatchState,
)

NOW = datetime(2026, 9, 6, 18, 0, tzinfo=UTC)


def kid(**over) -> Kid:
    return Kid(household_id="hh_1", nickname="Abu", age=8, **over)


def session(minutes_ago: int, watched_min: int, kid_id: str = "kid_1", day: str | None = None) -> Session:
    start = NOW - timedelta(minutes=minutes_ago)
    end = start + timedelta(minutes=watched_min)
    return Session(
        household_id="hh_1", kid_id=kid_id, video_id="v1", age_band="7_8",
        started_at=start.isoformat(timespec="seconds"),
        ended_at=end.isoformat(timespec="seconds"),
        watched_sec=watched_min * 60,
        date=day or start.date().isoformat(),
    )


def movement_break(started_min_ago: int, minutes: int = 5) -> BreakPeriod:
    start = NOW - timedelta(minutes=started_min_ago)
    return BreakPeriod(
        kid_id="kid_1",
        started_at=start.isoformat(timespec="seconds"),
        ends_at=(start + timedelta(minutes=minutes)).isoformat(timespec="seconds"),
        task=breaks.SAFE_FALLBACKS["7_8"][0],
    )


# --- continuous-watch accounting ----------------------------------------------------


def test_continuous_minutes_adds_up_back_to_back_sessions() -> None:
    sessions = [session(40, 15), session(24, 12), session(11, 10)]
    assert breaks.continuous_minutes(sessions, NOW - timedelta(minutes=1)) == 37


def test_a_ten_minute_gap_starts_the_count_over() -> None:
    # 20 minutes watched, away for 11, then 8 more: only the 8 count.
    sessions = [session(45, 20), session(14, 8)]
    assert breaks.continuous_minutes(sessions, NOW - timedelta(minutes=6)) == 8


def test_a_gap_since_the_last_session_also_resets() -> None:
    sessions = [session(60, 30)]  # ended 30 minutes ago
    assert breaks.continuous_minutes(sessions, NOW) == 0


def test_a_break_wipes_everything_before_it() -> None:
    sessions = [session(60, 25), session(20, 9)]
    ended = NOW - timedelta(minutes=25)  # a break that finished between the two
    assert breaks.continuous_minutes(sessions, NOW - timedelta(minutes=5), last_break_end=ended) == 9


def test_live_session_seconds_count_before_they_are_persisted() -> None:
    sessions = [session(20, 18)]
    assert breaks.continuous_minutes(sessions, NOW - timedelta(minutes=2), extra_seconds=7 * 60) == 25


def test_minutes_today_rolls_over_at_midnight() -> None:
    yesterday = session(60, 30, day="2026-09-05")
    today = session(30, 12, day="2026-09-06")
    assert breaks.minutes_today([yesterday, today], "2026-09-06") == 12
    assert breaks.minutes_today([yesterday, today], "2026-09-05") == 30


def test_continuous_watching_survives_midnight() -> None:
    """A sitting that crosses midnight is one sitting; only the daily total resets."""
    late = Session(
        household_id="hh_1", kid_id="kid_1", video_id="v1", age_band="7_8",
        started_at="2026-09-05T23:50:00+00:00", ended_at="2026-09-06T00:05:00+00:00",
        watched_sec=15 * 60, date="2026-09-05",
    )
    after = Session(
        household_id="hh_1", kid_id="kid_1", video_id="v2", age_band="7_8",
        started_at="2026-09-06T00:06:00+00:00", ended_at="2026-09-06T00:16:00+00:00",
        watched_sec=10 * 60, date="2026-09-06",
    )
    now = datetime(2026, 9, 6, 0, 18, tzinfo=UTC)
    assert breaks.continuous_minutes([late, after], now) == 25
    assert breaks.minutes_today([late, after], "2026-09-06") == 10


def midnight_sitting() -> Session:
    """61 minutes ending at 00:29, so the day's whole allowance is already spent."""
    return Session(
        household_id="hh_1", kid_id="kid_1", video_id="v1", age_band="7_8",
        started_at="2026-09-05T23:28:00+00:00", ended_at="2026-09-06T00:29:00+00:00",
        watched_sec=61 * 60, date="2026-09-05",
    )


def test_the_day_does_not_reset_underneath_a_child_who_is_still_watching() -> None:
    """Midnight rolls the day over; a sitting in progress carries across it.

    Sessions are dated by the day they started, so without this a child who
    started at 23:28 was handed a fresh hour at midnight, mid-video.
    """
    late = midnight_sitting()
    now = datetime(2026, 9, 6, 0, 30, tzinfo=UTC)  # a minute after they stopped
    assert breaks.minutes_today([late], "2026-09-06", now=now) == 61

    state = breaks.build_state(kid(daily_minutes=60), [late], [], now=now)
    assert state.minutes_left_today == 0
    assert state.watching_allowed is False and state.blocked_reason == "daily_limit"

    # Stopping for the gap is what ends the day: after it, the new one is theirs.
    stopped = datetime(2026, 9, 6, 0, 45, tzinfo=UTC)
    assert breaks.minutes_today([late], "2026-09-06", now=stopped) == 0


def test_a_movement_break_does_not_hand_back_the_day() -> None:
    """A break wipes the sitting, which is what it is for, and nothing else."""
    late = midnight_sitting()
    ended = NOW.replace(year=2026, month=9, day=6, hour=0, minute=34)
    now = datetime(2026, 9, 6, 0, 35, tzinfo=UTC)
    assert breaks.minutes_today([late], "2026-09-06", now=now) == 61
    assert breaks.continuous_minutes([late], now, last_break_end=ended) == 0


# --- state ---------------------------------------------------------------------------


def test_build_state_reports_the_day_and_the_sitting() -> None:
    k = kid(daily_minutes=60)
    sessions = [session(40, 15, day=NOW.date().isoformat()), session(20, 10, day=NOW.date().isoformat())]
    state = breaks.build_state(k, sessions, [], now=NOW - timedelta(minutes=5))
    assert state.minutes_today == 25 and state.minutes_left_today == 35
    assert state.continuous_minutes == 25 and state.watching_allowed is True


def test_no_daily_limit_means_no_number_and_no_block() -> None:
    state = breaks.build_state(kid(daily_minutes=0), [session(30, 200)], [], now=NOW - timedelta(minutes=1))
    assert state.minutes_left_today is None and state.watching_allowed is True


def test_a_spent_day_blocks_with_daily_limit() -> None:
    sessions = [session(70, 61, day=NOW.date().isoformat())]
    state = breaks.build_state(kid(daily_minutes=60), sessions, [], now=NOW)
    assert state.watching_allowed is False and state.blocked_reason == "daily_limit"
    assert state.minutes_left_today == 0


def test_a_running_break_blocks_and_expires_by_the_clock() -> None:
    running = movement_break(started_min_ago=2, minutes=5)
    state = breaks.build_state(kid(), [], [running], now=NOW)
    assert state.watching_allowed is False and state.blocked_reason == "break"
    assert state.active_break is not None and state.active_break.seconds_left == 180

    later = breaks.build_state(kid(), [], [running], now=NOW + timedelta(minutes=4))
    assert later.watching_allowed is True and later.active_break is None


def test_an_acked_break_is_still_running() -> None:
    """`ack` records that the child says they did it; the clock still decides."""
    running = movement_break(started_min_ago=1, minutes=5)
    running.acked = True
    state = breaks.build_state(kid(), [], [running], now=NOW)
    assert state.watching_allowed is False and state.active_break.acked is True
    assert state.active_break.seconds_left == 240


def test_override_ends_a_break_immediately() -> None:
    cleared = breaks.end_break_now(movement_break(started_min_ago=1, minutes=5))
    assert cleared.is_active() is False
    state = breaks.build_state(kid(), [], [cleared])
    assert state.watching_allowed is True and state.active_break is None


# --- due() ---------------------------------------------------------------------------


def _state(continuous: int, active: BreakPeriod | None = None) -> WatchState:
    return WatchState(continuous_minutes=continuous, active_break=active)


def test_due_waits_for_a_natural_moment_then_hard_interrupts() -> None:
    k = kid(break_after_minutes=25)
    assert breaks.due(k, _state(24)) == "no"
    assert breaks.due(k, _state(25)) == "wait_for_moment"
    assert breaks.due(k, _state(25), natural_moment=True) == "now"
    assert breaks.due(k, _state(27)) == "wait_for_moment"
    assert breaks.due(k, _state(28)) == "now"  # +3 minutes: interrupt anyway


def test_due_is_never_when_breaks_are_switched_off() -> None:
    assert breaks.due(kid(break_after_minutes=0), _state(300), natural_moment=True) == "no"


def test_due_says_no_while_a_break_is_already_running() -> None:
    running = movement_break(started_min_ago=1)
    assert breaks.due(kid(break_after_minutes=25), _state(90, running.at(NOW))) == "no"


# --- the safety gate -----------------------------------------------------------------


def task(**over) -> BreakTask:
    base = {
        "title": "Volcano stretch",
        "steps": ["Crouch down small, then push up tall with your arms wide."],
        "seconds": 120,
        "spoken": "Crouch down small and erupt up tall, five times!",
    }
    return BreakTask(**{**base, **over})


def test_a_good_task_passes() -> None:
    assert breaks.validate(task(), "7_8") is None


# One case per rule PROTOCOL.md names. Each of these must never reach a child.
UNSAFE: list[tuple[str, dict, AgeBand, str]] = [
    ("climbing", {"steps": ["Climb up onto something tall and be a volcano."]}, "7_8", "climbing"),
    ("standing on furniture", {"steps": ["Stand on the sofa and reach for the ceiling."]}, "7_8", "furniture"),
    ("standing on a chair", {"spoken": "Get up on a chair and stretch tall like a tree!"}, "7_8", "furniture"),
    ("jumping off furniture", {"steps": ["Jump off the bed like lava bursting out."]}, "7_8", "furniture"),
    ("jumping down", {"steps": ["Jump down from as high as you can reach."]}, "7_8", "jumping off"),
    ("running", {"steps": ["Run around the room five times like a cheetah."]}, "7_8", "running"),
    ("stairs", {"steps": ["Go up and down the stairs like a mountain goat."]}, "7_8", "stairs"),
    ("outdoors", {"steps": ["Go outside and find a tree to hug."]}, "7_8", "outdoors"),
    ("the garden", {"spoken": "Head into the garden and stomp like a dinosaur!"}, "7_8", "outdoors"),
    ("water", {"steps": ["Fill a glass of water and pretend it is lava."]}, "7_8", "water"),
    ("the kitchen", {"steps": ["Go to the kitchen and mix vinegar into baking soda."]}, "7_8", "kitchen"),
    ("scissors", {"steps": ["Cut a paper volcano out with scissors."]}, "7_8", "sharp"),
    ("a knife", {"steps": ["Carve a shape with a knife like the video showed."]}, "7_8", "sharp"),
    ("spinning fast", {"steps": ["Spin around really fast like a tornado."]}, "7_8", "spinning fast"),
    ("dizziness", {"spoken": "Twirl as fast as you can until you feel dizzy!"}, "7_8", "spinning fast"),
    ("needing an adult", {"steps": ["Ask a grown-up to hold your feet down."]}, "7_8", "adult"),
    ("needing a parent", {"spoken": "Get your mum to time you while you stretch."}, "7_8", "adult"),
    ("fetching equipment", {"steps": ["Go and get a broom to hold like a flagpole."]}, "7_8", "fetching"),
    ("punishment framing", {"spoken": "You have watched too much telly, so stretch now."}, "7_8", "punishment"),
]


@pytest.mark.parametrize("label,over,band,expected", UNSAFE, ids=[u[0] for u in UNSAFE])
def test_unsafe_tasks_are_rejected(label: str, over: dict, band: AgeBand, expected: str) -> None:
    reason = breaks.validate(task(**over), band)
    assert reason is not None, f"{label} was allowed through"
    assert expected in reason


def test_a_task_that_is_too_long_or_too_short_is_rejected() -> None:
    assert "at most" in (breaks.validate(task(seconds=240), "7_8") or "")
    assert "at least" in (breaks.validate(task(seconds=30), "7_8") or "")
    assert breaks.validate(task(seconds=60), "7_8") is None
    assert breaks.validate(task(seconds=180), "7_8") is None


def test_an_empty_task_is_rejected() -> None:
    assert breaks.validate(BreakTask(title="", steps=[], seconds=90), "7_8") == "empty task"
    assert breaks.validate(BreakTask(title="Move", steps=[], spoken="", seconds=90), "7_8") == "empty task"


def test_band_4_6_rejects_a_sequence_of_steps() -> None:
    multi = task(steps=["Crouch down small.", "Push up tall.", "Wave your arms."],
                 spoken="Crouch, push up, wave.")
    reason = breaks.validate(multi, "4_6")
    assert reason is not None and "one imitation" in reason


def test_band_4_6_rejects_a_routine_hidden_in_one_step() -> None:
    """Two mimed halves joined by one "then" is still "be a volcano"; a numbered
    recipe in a single string is not."""
    one_mime = task(steps=["Crouch down small and then grow up tall."],
                    spoken="Crouch down teeny tiny and then grow up taaall!")
    assert breaks.validate(one_mime, "4_6") is None

    routine = task(steps=["Crouch down, then wave, then stomp, then clap."],
                   spoken="Crouch, wave, stomp, clap!")
    assert "one imitation" in (breaks.validate(routine, "4_6") or "")

    ordered = task(steps=["First, crouch down small. Next, erupt up tall."],
                   spoken="First crouch. Next erupt.")
    assert "one imitation" in (breaks.validate(ordered, "4_6") or "")


def test_band_4_6_rejects_anything_needing_reading() -> None:
    single = task(steps=["Read the word on the screen and act it out."],
                  spoken="Read the word and act it out!")
    reason = breaks.validate(single, "4_6")
    assert reason is not None and "cannot read" in reason


def test_band_4_6_needs_a_spoken_line() -> None:
    silent = BreakTask(title="Be a volcano", steps=["Erupt up tall."], seconds=90, spoken="")
    assert breaks.validate(silent, "4_6") == "band 4_6 needs a spoken line; there is no text on screen"


# --- the built-in fallbacks ----------------------------------------------------------


@pytest.mark.parametrize("band", ["4_6", "7_8", "9_11"])
def test_every_built_in_fallback_passes_its_own_gate(band: AgeBand) -> None:
    pool = breaks.SAFE_FALLBACKS[band]
    assert len(pool) >= 3
    for t in pool:
        assert breaks.validate(t, band) is None, f"{band} fallback {t.title!r} fails the gate"


def test_band_4_6_fallbacks_are_a_single_imitation() -> None:
    for t in breaks.SAFE_FALLBACKS["4_6"]:
        assert len(t.steps) == 1 and t.spoken


def test_fallback_task_is_stable_and_spreads_out() -> None:
    assert breaks.fallback_task("7_8", "volcanoes") is breaks.fallback_task("7_8", "volcanoes")
    picks = {breaks.fallback_task("7_8", f"video {i}").title for i in range(30)}
    assert len(picks) > 1


def test_start_break_uses_the_parents_break_length() -> None:
    msg = BreakMessage(text="Tidy one thing.", spoken="Go and tidy one thing.")
    b = breaks.start_break(kid(break_minutes=7), msg, NOW)
    assert b.seconds_left == 7 * 60
    assert b.message is not None and b.message.text == "Tidy one thing."
    assert b.remaining(NOW + timedelta(minutes=8)) == 0


def test_a_break_with_no_parent_message_is_valid_and_quiet() -> None:
    b = breaks.start_break(kid(), None, NOW)
    assert b.message is None, "a parent who wrote nothing gets a quiet break, not a made-up one"


def test_the_parents_messages_rotate_so_a_child_hears_them_all() -> None:
    lines = [BreakMessage(text=f"line {i}", spoken=f"line {i}") for i in range(3)]
    k = kid()
    k = k.model_copy(update={"break_messages": lines})
    seen = []
    previous: list = []
    for _ in range(4):
        m = breaks.pick_message(k, previous)
        seen.append(m.text)
        previous.append(breaks.start_break(k, m, NOW))
    assert seen == ["line 0", "line 1", "line 2", "line 0"]


def test_pick_message_returns_nothing_when_the_parent_wrote_nothing() -> None:
    assert breaks.pick_message(kid(), []) is None


# --- how long one video may run ------------------------------------------------------
#
# The screening-time ceiling tests a length, the only source of a length is the
# YouTube watch page, and YouTube refuses that page to datacenter addresses. So
# in production the ceiling had nothing to test and a two-hour-thirteen-minute
# film reached an eight-year-old with a 35-minute ceiling in force.


def _kid_with(max_video_minutes: int) -> Kid:
    return Kid(household_id="hh", nickname="Zara", age=8,
               max_video_minutes=max_video_minutes)


def test_a_video_nobody_could_measure_is_capped_while_it_plays() -> None:
    """The case that let the film through. Screening skipped it for want of a
    length, so the cap has to be applied where a length is not needed."""
    assert breaks.video_cap_seconds(_kid_with(0), duration_s=0, unmeasured_cap_s=2100) == 2100


def test_a_parent_who_set_a_number_gets_that_number() -> None:
    """Theirs is the setting that exists for exactly this, so it wins whether or
    not the video was ever measured."""
    for duration in (0, 600, 8020):
        assert breaks.video_cap_seconds(
            _kid_with(20), duration_s=duration, unmeasured_cap_s=2100
        ) == 1200, duration


def test_a_measured_video_on_the_shelf_is_not_cut_off_mid_way() -> None:
    """A length that was known had the ceiling applied to it at screening time.
    Anything over it that is still on the shelf is there because a parent put it
    there, and stopping it now would overrule somebody who already said yes."""
    assert breaks.video_cap_seconds(_kid_with(0), duration_s=600, unmeasured_cap_s=2100) == 0
    long_one = breaks.video_cap_seconds(_kid_with(0), duration_s=8020, unmeasured_cap_s=2100)
    assert long_one == 0, "a video the parent allowed knowing its length was cut off"


def test_stopping_for_length_never_blames_the_child() -> None:
    """A stop that sounds like a telling-off makes the next one something to
    avoid. It is about the video being long, not about them watching too much."""
    for band in ("4_6", "7_8", "9_11"):
        line = breaks.too_long_line(band).lower()
        assert line, band
        for blame in ("too much", "you watched", "enough", "no more", "stop watching"):
            assert blame not in line, f"{band}: {line!r}"
