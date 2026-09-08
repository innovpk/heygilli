"""Time limits and movement breaks: the accounting and the safety gate.

PROTOCOL.md "Time limits and movement breaks". Everything here is a pure
function over data — sessions in, minutes out; a task in, a reason out — so the
rules can be tested without a store, a clock or a model.

Two things live here that must never depend on a model call succeeding:

* `SAFE_FALLBACKS`, a handful of built-in tasks per band, and
* `validate`, the safety gate every generated task passes through.

The gate is the point of the feature. A generated task that mentions climbing,
furniture, running, stairs, water, the kitchen, or needing an adult is dropped
and a fallback is used instead. Code beats prompt: the prompt asks nicely, this
module refuses.
"""
from __future__ import annotations

import re
import zlib
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from typing import Literal

from .schemas import (
    AgeBand,
    BreakMessage,
    BreakPeriod,
    BreakTask,
    Kid,
    Session,
    WatchState,
    now_iso,
    parse_iso,
)

# --- the numbers PROTOCOL.md fixes -------------------------------------------------

GAP_RESET_MINUTES = 10  # no session for this long and continuous watching starts over
HARD_INTERRUPT_MINUTES = 3  # wait this long for a natural moment, then interrupt anyway
MIN_TASK_SECONDS = 60
MAX_TASK_SECONDS = 180

Verdict = Literal["no", "wait_for_moment", "now"]


# --- how long one video may run -----------------------------------------------------
#
# The length ceiling used to exist only at screening time, tested against a
# length read off the YouTube watch page — and YouTube refuses that page to
# datacenter addresses. In production almost every video was screened with no
# length at all, and an unknown length is skipped rather than judged, so the
# ceiling and the parent's own "longest video" setting were both decorative: a
# two-hour-thirteen-minute film reached an eight-year-old with a 35-minute
# ceiling in force.
#
# This is the same limit applied where nothing can refuse us: on our own server,
# while the child is watching. It needs no length, no API key and no cooperation
# from YouTube.


def video_cap_seconds(kid: Kid, duration_s: int, unmeasured_cap_s: int) -> int:
    """How long this child may spend on this one video. 0 means no cap.

    Three cases, and the difference between them is who decided:

    * The parent set a number. Theirs wins outright — it is the setting that
      exists for exactly this, and it applies whether or not we ever managed to
      measure the video.
    * No number, and the length was known when it was screened. The ceiling
      already had its say then, and anything over it that is on the shelf is
      there because a parent put it there. Cutting it off now would overrule
      somebody who said yes.
    * No number, and the length was never known. This is the case that let the
      film through: the ceiling did not get a say, so it gets one here.
    """
    if kid.max_video_minutes:
        return kid.max_video_minutes * 60
    if duration_s:
        return 0
    return unmeasured_cap_s


def too_long_line(band: AgeBand) -> str:
    """What Gilli says when it stops a video for length.

    Never "you watched too much": the child did nothing wrong, and a stop that
    sounds like a telling-off makes the next one something to avoid rather than
    something normal. It is about the video being a long one.
    """
    if band == "4_6":
        return "That is a looong video! Let us stop there. Bye bye!"
    return "That is a long one — let us stop there for today. See you next time!"


def _utcnow() -> datetime:
    return datetime.now(UTC)


# --- continuous and daily accounting ----------------------------------------------


def _span(s: Session) -> tuple[datetime, datetime] | None:
    """(start, end) for one session. A session still running ends at its start
    plus what it has watched, which is 0 for one that has only just begun."""
    start = parse_iso(s.started_at)
    if start is None:
        return None
    end = parse_iso(s.ended_at) or start + timedelta(seconds=max(0, s.watched_sec))
    return start, max(start, end)


def _sitting(
    sessions: Sequence[Session],
    now: datetime,
    last_break_end: datetime | None = None,
) -> list[Session]:
    """The run of watching that is still going on: the sessions in it, oldest first.

    Walks the sessions in order and starts the run over whenever the child was
    away for `GAP_RESET_MINUTES` — including the gap between the last session
    and `now`, so a child who stopped twenty minutes ago is in no run at all.
    Sessions that finished before `last_break_end` are dropped, because the
    break already wiped them. Deliberately ignores dates: watching from 23:55
    to 00:10 is one sitting.
    """
    gap = timedelta(minutes=GAP_RESET_MINUTES)

    spans = [(span, s) for s in sessions if (span := _span(s)) is not None]
    spans.sort(key=lambda item: item[0][0])

    run: list[Session] = []
    prev_end: datetime | None = None
    for (start, end), s in spans:
        if end <= (last_break_end or datetime.min.replace(tzinfo=UTC)):
            continue  # finished before the last break; the break already wiped it
        if prev_end is not None and start - prev_end >= gap:
            run = []
        run.append(s)
        prev_end = end if prev_end is None else max(prev_end, end)

    if prev_end is not None and now - prev_end >= gap:
        return []
    return run


def minutes_today(
    sessions: Sequence[Session],
    day: str,
    extra_seconds: int = 0,
    now: datetime | None = None,
) -> int:
    """Minutes watched on `day` (YYYY-MM-DD), plus a live session's `extra_seconds`.

    Sessions carry the date they started on, so yesterday's watching rolls off
    at midnight without anything having to run at midnight — but it must not
    roll off underneath a child who is still watching. A sitting that began at
    23:30 would otherwise hand back the whole daily allowance at midnight,
    mid-video, which is the one moment the limit exists for. So the sitting that
    is still going on counts towards today whichever day its sessions started
    on, and drops off once the child has actually stopped for
    `GAP_RESET_MINUTES`. A movement break is not stopping: the carry-over
    deliberately ignores breaks, or five minutes on the rug would clear the day.
    """
    now = now or _utcnow()
    counted: dict[str, Session] = {s.id: s for s in sessions if s.date == day}
    if day == now.date().isoformat():
        counted.update({s.id: s for s in _sitting(sessions, now)})
    total = sum(max(0, s.watched_sec) for s in counted.values())
    return (total + max(0, extra_seconds)) // 60


def continuous_minutes(
    sessions: Sequence[Session],
    now: datetime | None = None,
    last_break_end: datetime | None = None,
    extra_seconds: int = 0,
) -> int:
    """Minutes of unbroken watching: since the last break, or since a 10-minute gap."""
    now = now or _utcnow()
    run = sum(max(0, s.watched_sec) for s in _sitting(sessions, now, last_break_end))
    return (run + max(0, extra_seconds)) // 60


def last_break_end(breaks: Sequence[BreakPeriod]) -> datetime | None:
    """When the most recent break finished. A parent override moves a break's
    `ends_at` to now, so overriding resets the count exactly like sitting it out."""
    ends = [dt for b in breaks if (dt := parse_iso(b.ends_at)) is not None]
    return max(ends) if ends else None


def active_break(breaks: Sequence[BreakPeriod], now: datetime | None = None) -> BreakPeriod | None:
    """The break still running, with `seconds_left` recomputed from the clock."""
    now = now or _utcnow()
    running = [b for b in breaks if b.is_active(now)]
    if not running:
        return None
    return max(running, key=lambda b: b.ends_at).at(now)


def build_state(
    kid: Kid,
    sessions: Sequence[Session],
    breaks: Sequence[BreakPeriod],
    now: datetime | None = None,
    extra_seconds: int = 0,
) -> WatchState:
    """The `WatchState` behind `GET /kids/{id}/state`.

    `extra_seconds` is the live session's time, which is not persisted until the
    session ends; without it a child could pass their limit mid-video.
    """
    now = now or _utcnow()
    running = active_break(breaks, now)
    today = now.date().isoformat()
    watched = minutes_today(sessions, today, extra_seconds, now)
    left = max(0, kid.daily_minutes - watched) if kid.daily_minutes > 0 else None
    state = WatchState(
        minutes_today=watched,
        minutes_left_today=left,
        continuous_minutes=continuous_minutes(sessions, now, last_break_end(breaks), extra_seconds),
        watching_allowed=True,
        blocked_reason=None,
        active_break=running,
    )
    if running is not None:
        state.watching_allowed = False
        state.blocked_reason = "break"
    elif left == 0:
        state.watching_allowed = False
        state.blocked_reason = "daily_limit"
    return state


def due(kid: Kid, state: WatchState, natural_moment: bool = False) -> Verdict:
    """Should a break fire now?

    `"wait_for_moment"` means the child is past their limit but is mid-sentence:
    hold until a question pause or the end of the video. After
    `HARD_INTERRUPT_MINUTES` more the answer becomes `"now"` whether or not a
    natural moment ever arrived (PROTOCOL.md).
    """
    if kid.break_after_minutes <= 0:  # 0 = never
        return "no"
    if state.active_break is not None:
        return "no"
    overdue = state.continuous_minutes - kid.break_after_minutes
    if overdue < 0:
        return "no"
    if natural_moment or overdue >= HARD_INTERRUPT_MINUTES:
        return "now"
    return "wait_for_moment"


def pick_message(kid: Kid, previous: Sequence[BreakPeriod] = ()) -> BreakMessage | None:
    """Which of the parent's lines Gilli says this time.

    Rotates through them so a child does not hear the same one every break. No
    messages is a valid, quiet break: Gilli says only that it is break time.
    """
    if not kid.break_messages:
        return None
    used = len([b for b in previous if b.message is not None])
    return kid.break_messages[used % len(kid.break_messages)]


def start_break(
    kid: Kid,
    message: BreakMessage | None = None,
    now: datetime | None = None,
) -> BreakPeriod:
    now = now or _utcnow()
    ends = now + timedelta(minutes=max(1, kid.break_minutes))
    return BreakPeriod(
        kid_id=kid.id,
        started_at=now.isoformat(timespec="seconds"),
        ends_at=ends.isoformat(timespec="seconds"),
        seconds_left=int((ends - now).total_seconds()),
        message=message,
        is_firm=kid.break_is_firm,
    )


def end_break_now(b: BreakPeriod) -> BreakPeriod:
    """A parent override: the break is over as of this moment. Expiry stays a
    property of the clock, so nothing else in the accounting has to know."""
    return b.model_copy(update={"ends_at": now_iso(), "seconds_left": 0})


# --- the safety gate ----------------------------------------------------------------
#
# One rule per line, each with the words that trip it and the reason a parent or
# a log would want to read. Word boundaries everywhere: "run" must not match
# "running water" only by accident, and must not match "grunt".

_RULES: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("climbing", (r"climb\w*", r"clamber\w*", r"scrambl\w* up", r"pull yourself up")),
    (
        "standing on or jumping off furniture",
        (r"sofa", r"couch", r"chair", r"table", r"\bbed\b", r"stool", r"counter\b", r"furniture",
         r"cushion", r"armchair", r"windowsill", r"ledge", r"\bshelf\b"),
    ),
    (
        "jumping off or onto something",
        (r"jump (?:off|on to|onto|from|down|over|across)", r"leap (?:off|from|onto|over)",
         r"\bdive\b", r"\bdiving\b", r"somersault", r"cartwheel", r"handstand", r"headstand",
         r"backflip", r"\bflip over\b"),
    ),
    ("running", (r"\brun\b", r"\bruns\b", r"\brunning\b", r"\bsprint\w*", r"\brace\b", r"\bracing\b",
                 r"\bchase\b", r"\bchasing\b", r"\bdash\b", r"\bjog\w*")),
    ("stairs", (r"\bstairs?\b", r"staircase", r"banister", r"\bstep (?:up|down) (?:the|a)\b", r"landing rail")),
    (
        "going outdoors",
        (r"\boutside\b", r"outdoors?", r"\bgarden\b", r"\byard\b", r"\bpark\b", r"balcony",
         r"\bstreet\b", r"\bbackyard\b", r"\bpavement\b", r"\bsidewalk\b", r"\bpatio\b", r"\bdriveway\b"),
    ),
    (
        "water",
        (r"\bwater\b", r"\bpool\b", r"\bbath\w*", r"\bsink\b", r"\bshower\b", r"\bbucket\b",
         r"\bpond\b", r"\bsea\b", r"\bhose\b", r"\bpuddle\b", r"\bglass of\b", r"\bdrink of\b"),
    ),
    (
        "the kitchen",
        (r"kitchen", r"\bstove\b", r"\boven\b", r"\bfridge\b", r"\bcook\w*", r"\bsaucepan\b",
         r"\bkettle\b", r"\bmicrowave\b", r"\bflour\b", r"baking soda", r"\bvinegar\b"),
    ),
    (
        "sharp or breakable objects",
        (r"\bknife\b", r"\bknives\b", r"scissors", r"\bblade\b", r"skewer", r"\bneedle\b",
         r"\bfork\b", r"\bglass\b", r"\bmatch(?:es|stick)\b", r"\bcandle\b", r"\blighter\b"),
    ),
    (
        "spinning fast",
        (r"spin\w* (?:really |very |super )?(?:fast|quickly)", r"(?:fast|quick) spin\w*",
         r"spin\w* round and round", r"as fast as you can", r"whirl\w*", r"\bdizzy\b",
         r"twirl\w* (?:fast|quickly)", r"\btornado\b"),
    ),
    (
        "needing an adult",
        (r"\badult\b", r"grown[ -]?up", r"\bparent\b", r"\bmum\b", r"\bmom\b", r"\bdad\b",
         r"\bcaregiver\b", r"supervis\w*", r"ask someone to help"),
    ),
    (
        "fetching equipment",
        (r"\bfetch\b", r"go (?:and )?(?:get|find|grab)", r"\bbring (?:me|a|an|your|the)\b",
         r"you will need a", r"you'll need a", r"\bpick up a\b"),
    ),
    (
        "framing the break as a punishment",
        (r"too much (?:screen|tv|telly|watching|youtube)", r"watched (?:too much|enough)",
         r"\bpunish\w*", r"you have to stop", r"no more (?:videos|watching)", r"\btime is up\b"),
    ),
)

# Band 4_6 is spoken and mimed: no reading, and one imitation rather than a
# sequence to remember.
_READING = (r"\bread\b", r"\breading\b", r"\bwrite\b", r"\bwriting\b", r"\bspell\w*", r"\bletters?\b",
            r"\bwords? on\b", r"\bbook\b", r"\bsign\b", r"\blist\b", r"\bcount the words\b")

# A sequence to remember, which a pre-reader cannot hold. "Crouch small and then
# erupt tall" is still one imitation, so a single "then" is allowed; an ordered
# recipe is not.
_SEQUENCE = (r"\bnext,", r"\bafter that\b", r"\bfirst,", r"\bsecond(?:ly)?,", r"\bthird(?:ly)?,",
             r"\bfinally\b", r"\blastly\b", r"\bstep \d", r"\b\d\)\s", r"\bin order\b",
             r"\brepeat the (?:whole|sequence|routine)\b")
_MAX_THENS = 1  # one "then" joins two halves of a mime; two is a routine


def _hit(patterns: tuple[str, ...], text: str) -> str | None:
    for p in patterns:
        m = re.search(p, text)
        if m:
            return m.group(0).strip()
    return None


def task_text(task: BreakTask) -> str:
    return " ".join([task.title, *task.steps, task.spoken]).lower()


def validate(task: BreakTask, band: AgeBand) -> str | None:
    """None if the task is safe to give a child; otherwise the reason it is not.

    The caller logs the reason and uses a fallback. Nothing here asks the model
    to behave: a task that trips any rule is gone whatever the prompt said.
    """
    if not task.title.strip() or not (task.steps or task.spoken.strip()):
        return "empty task"

    text = task_text(task)
    for reason, patterns in _RULES:
        if (found := _hit(patterns, text)) is not None:
            return f"mentions {reason} ({found!r})"

    if task.seconds < MIN_TASK_SECONDS:
        return f"only {task.seconds}s; a break is at least {MIN_TASK_SECONDS}s"
    if task.seconds > MAX_TASK_SECONDS:
        return f"{task.seconds}s; a break is at most {MAX_TASK_SECONDS}s"

    if band == "4_6":
        if len(task.steps) > 1:
            return f"band 4_6 needs one imitation, not {len(task.steps)} steps"
        if (found := _hit(_SEQUENCE, text)) is not None:
            return f"band 4_6 needs one imitation, not a sequence ({found!r})"
        thens = len(re.findall(r"\bthen\b", " ".join([task.title, *task.steps])))
        if thens > _MAX_THENS:
            return f"band 4_6 needs one imitation, not a sequence ({thens} steps joined by 'then')"
        if (found := _hit(_READING, text)) is not None:
            return f"band 4_6 cannot read ({found!r})"
        if not task.spoken.strip():
            return "band 4_6 needs a spoken line; there is no text on screen"

    return None


# --- built-in fallbacks -------------------------------------------------------------
#
# These ship with the app. A break never depends on a model call succeeding, so
# whenever generation fails or is rejected one of these is used instead. Each
# one is checked against `validate` by the test suite.

SAFE_FALLBACKS: dict[str, tuple[BreakTask, ...]] = {
    "4_6": (
        BreakTask(
            title="Be a tall tree",
            steps=["Stand tall and sway your arms like branches in the wind."],
            seconds=90,
            spoken="Let's be a taaall tree! Stand up tall and sway your branches. Sway, sway, sway!",
        ),
        BreakTask(
            title="Stomp like a dinosaur",
            steps=["Stomp your feet on the spot and give a big roar."],
            seconds=90,
            spoken="Let's be a big stompy dinosaur! Stomp, stomp, stomp, and ROAR!",
        ),
        BreakTask(
            title="Be a growing seed",
            steps=["Curl up teeny tiny and grow up tall with your arms wide open."],
            seconds=90,
            spoken="Curl up teeny tiny like a little seed. Grow, grow, grow up taaall! You're a flower!",
        ),
        BreakTask(
            title="Flap like a bird",
            steps=["Flap your arms slowly, like big wings."],
            seconds=90,
            spoken="Let's flap our wings! Slow big flaps. Flaaap. Flaaap. You're flying!",
        ),
    ),
    "7_8": (
        BreakTask(
            title="Volcano stretch",
            steps=[
                "Crouch down small, as low as you can go.",
                "Push up slowly and throw your arms wide for the eruption.",
                "Do it five times, a bit slower each time.",
            ],
            seconds=120,
            spoken="Time to be a volcano! Crouch down small, then erupt up tall. Five times!",
        ),
        BreakTask(
            title="Freeze frame",
            steps=[
                "March on the spot while you count to twenty.",
                "Freeze like a statue when you get there and hold it while you count to ten.",
            ],
            seconds=120,
            spoken="March on the spot to twenty, then freeze like a statue. Can you hold it?",
        ),
        BreakTask(
            title="Balance test",
            steps=[
                "Stand on one foot and hold it while you count to ten.",
                "Swap feet and do it again.",
                "Now try it with your eyes almost closed.",
            ],
            seconds=120,
            spoken="Stand on one foot and count to ten. Now the other foot. Wobbly?",
        ),
        BreakTask(
            title="Big shoulder rolls",
            steps=[
                "Roll your shoulders backwards ten times, nice and big.",
                "Reach up as high as you can, then hang down loose like a rag doll.",
            ],
            seconds=90,
            spoken="Roll those shoulders back ten times, reach up high, then flop down like a rag doll.",
        ),
    ),
    "9_11": (
        BreakTask(
            title="Wall push and stretch",
            steps=[
                "Press your palms flat against a wall and push for ten slow seconds.",
                "Stretch both arms up, then fold forward and let your head hang.",
                "Repeat the whole thing three times.",
            ],
            seconds=150,
            spoken="Push against the wall for ten seconds, stretch up, fold forward. Three rounds.",
        ),
        BreakTask(
            title="Slow-motion challenge",
            steps=[
                "Pick any movement you like and do it in the slowest slow motion you can manage.",
                "Keep it going for a full two minutes without stopping.",
            ],
            seconds=150,
            spoken="Two minutes of the slowest slow motion you can manage. Anything you like. Go.",
        ),
        BreakTask(
            title="Hold the plank",
            steps=[
                "Get into a plank on your forearms and hold it while you count to twenty.",
                "Rest for twenty, then do it twice more.",
            ],
            seconds=150,
            spoken="Plank on your forearms, count to twenty, rest, and go again. Three rounds.",
        ),
        BreakTask(
            title="Wall sit",
            steps=[
                "Lean your back on a wall and slide down until your knees are bent.",
                "Hold it while you count to thirty, then stand and shake your legs out.",
                "Do it twice more if you can.",
            ],
            seconds=120,
            spoken="Back on the wall, slide down, hold it for thirty. Then shake it out and go again.",
        ),
    ),
}


def fallback_task(band: AgeBand, seed: str = "") -> BreakTask:
    """A built-in task for this band. `seed` (a video title, a break id) just
    spreads the choice out so the same child does not always get the same one."""
    pool = SAFE_FALLBACKS.get(band) or SAFE_FALLBACKS["7_8"]
    return pool[zlib.crc32(seed.encode()) % len(pool)]


_MESSAGE_EXEMPT = frozenset({"needing an adult", "fetching equipment"})


def validate_message(message: BreakMessage, band: AgeBand) -> str | None:
    """`None` when this suggestion is safe to put in front of a parent, else why not.

    The same rule set as `validate`, reading a one-line message. It runs on
    *suggestions only*: a line a parent wrote themselves is theirs, and is never
    second-guessed here. Reading is allowed, unlike in a mimed task, because a
    parent may well want "go and read a page" — but for band 4_6 the line still
    has to be one instruction, not a routine to remember.
    """
    if not message.text.strip():
        return "empty"
    if len(message.text) > 140:
        return "too long for a parent to scan"

    text = f"{message.text} {message.spoken}".lower()
    for reason, patterns in _RULES:
        # Two rules invert between the designs. For a child miming alone on a
        # rug, needing an adult or fetching something was a hazard. For a break
        # message it is the whole point: "go and find a grown-up", "go and get
        # your Lego". Both are skipped here on purpose. Everything else still
        # applies, because a parent should not be handed stairs, water or a
        # kitchen to approve in a single tap.
        if reason in _MESSAGE_EXEMPT:
            continue
        if (found := _hit(patterns, text)) is not None:
            return f"mentions {reason} ({found!r})"

    if band == "4_6":
        if (found := _hit(_SEQUENCE, text)) is not None:
            return f"band 4_6 needs one instruction, not a sequence ({found!r})"
        if not message.spoken.strip():
            return "band 4_6 needs a spoken line; there is no text on screen"
    return None
