"""Pydantic v2 models: SPEC §10 data model + docs/PROTOCOL.md wire objects.

Everything the client parses, every structured output the agents return, and
every record the store persists is defined here so there is one vocabulary.
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

# --- enums (PROTOCOL.md "Enums") --------------------------------------------

AgeBand = Literal["4_6", "7_8", "9_11"]
Language = Literal["en", "ur"]
QuestionType = Literal[
    "name_it", "copy_it", "pick_it",  # 4_6
    "recall", "why", "predict",  # 7_8
    "explain", "compare", "apply", "opinion",  # 9_11
]
InputMode = Literal["voice", "pick", "copy"]
AnswerInput = Literal["voice", "pick", "copy", "none"]
Result = Literal["correct", "partial", "off_topic", "unclear", "silence"]
Gesture = Literal["idle", "stretch", "shrink", "spin", "point", "roar", "think", "cheer"]
QuestionFreq = Literal["normal", "gentle"]

TYPES_FOR_BAND: dict[str, tuple[str, ...]] = {
    "4_6": ("name_it", "copy_it", "pick_it"),
    "7_8": ("recall", "why", "predict"),
    "9_11": ("explain", "compare", "apply", "opinion"),
}


def band_for_age(age: int) -> AgeBand:
    if age <= 6:
        return "4_6"
    if age <= 8:
        return "7_8"
    return "9_11"


def new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def now_iso() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def parse_iso(ts: str | None) -> datetime | None:
    """A stored timestamp back as an aware datetime; None when it is missing or junk."""
    if not ts:
        return None
    try:
        dt = datetime.fromisoformat(ts)
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=UTC)


# --- household / kid ----------------------------------------------------------


class Kid(BaseModel):
    id: str = Field(default_factory=lambda: new_id("kid"))
    household_id: str
    nickname: str
    age: int = Field(ge=3, le=12)
    age_band: AgeBand | None = None
    languages: list[Language] = Field(default_factory=lambda: ["en"])
    avatar: str = "gilli"
    #: What the parent said this child likes, from the starter-channel screen.
    #: It used to filter that screen's suggestions and then be thrown away, so
    #: a parent who asked for science and was handed a science channel whose
    #: latest uploads are motivational-quote compilations got them approved
    #: without anything noticing they were not what was asked for.
    topics: list[str] = Field(default_factory=list)
    question_freq: QuestionFreq = "normal"

    # Time limits (PROTOCOL.md "Time limits and movement breaks"). All four are
    # optional with defaults so kids stored before this feature existed still
    # load; a parent edits them through PATCH /kids/{id}/limits.
    daily_minutes: int = Field(default=60, ge=0, description="Total watching per day; 0 = no limit")
    break_after_minutes: int = Field(default=25, ge=0, description="Continuous watching before a break; 0 = never")
    break_minutes: int = Field(default=5, ge=1, description="How long a movement break lasts")
    max_video_minutes: int = Field(default=0, ge=0, description="Longest single video offered; 0 = no limit")
    break_is_firm: bool = Field(default=True, description="True: the timer must run out. False: the child may return early")
    break_messages: list[BreakMessage] = Field(
        default_factory=list,
        description="What Gilli says during a break. Parent-authored; empty is a valid, quiet break.",
    )
    #: Prompt ids from `question_bank` this household has turned off for this
    #: child. Opt-out: empty means every prompt written for their band is
    #: allowed, so a parent who never opens the screen still gets a working
    #: app. Ids are kept even when they name a prompt that no longer exists —
    #: a household outlives any one release.
    disabled_prompts: list[str] = Field(
        default_factory=list,
        description="question_bank prompt ids this child is not asked",
    )
    search_enabled: bool = Field(
        default=False,
        description=(
            "Whether the child may search. Off by default, and it never reaches "
            "YouTube: it filters the videos already approved for this kid. A "
            "search box that could return anything would undo the allowlist."
        ),
    )

    @model_validator(mode="after")
    def _derive_band(self) -> Kid:
        if self.age_band is None:
            self.age_band = band_for_age(self.age)
        if self.age_band == "4_6":
            self.question_freq = "gentle"  # SPEC §7.3: gentle, cannot be raised
        if not self.languages:
            self.languages = ["en"]
        return self


class Channel(BaseModel):
    id: str  # YouTube channel id (UC...)
    title: str
    thumb_url: str = ""
    approved: bool = True
    last_checked: str | None = None


class GoogleLink(BaseModel):
    """The parent's Google sign-in for one household (PROTOCOL.md "Google sign-in
    and subscription import"). One per household, never one per child.

    `refresh_token` is a credential: until the parent revokes it, it grants
    read-only access to their YouTube subscriptions. A real deployment encrypts
    it at rest (KMS-backed field encryption or Secrets Manager keyed by
    household) and rotates the store's own key; for the hackathon it lives in
    the same local JSON store as everything else. See README "Data safety".
    It is never returned by any endpoint and never logged.

    `email` is the only personal field kept about the parent, and nothing about
    the child is stored here at all (SPEC §12).
    """

    email: str = ""
    google_sub: str = ""  # stable Google account id; survives an email change
    refresh_token: str = ""
    access_token: str = ""
    access_expires_at: str | None = None
    linked_at: str = Field(default_factory=now_iso)

    def is_fresh(self, skew_s: int = 60) -> bool:
        """True while the cached access token is still usable `skew_s` from now."""
        if not self.access_token or not self.access_expires_at:
            return False
        try:
            expires = datetime.fromisoformat(self.access_expires_at)
        except ValueError:
            return False
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=UTC)
        return expires > datetime.now(UTC) + timedelta(seconds=skew_s)


class AuthSession(BaseModel):
    """PROTOCOL.md `Session` as returned by `POST /auth/google`.

    Not to be confused with `Session` below, which is one child watching one
    video; this object only ever appears as an auth response.
    """

    token: str
    household_id: str
    email: str = ""
    youtube_linked: bool = False


class Subscription(BaseModel):
    """PROTOCOL.md `Subscription`: one channel the parent follows on YouTube,
    marked with the kids it is already approved for."""

    channel_id: str
    title: str = ""
    thumb_url: str = ""
    approved_for: list[str] = Field(default_factory=list)


# --- Takeout import (PROTOCOL.md "Takeout import: the children's own profiles") ---
#
# Google's Takeout export is the only route to a YouTube Kids profile's
# subscriptions. Only the subscription CSVs are ever read; watch and search
# history are never opened, stored or sent to a model (SPEC §12).


class TakeoutChannel(BaseModel):
    channel_id: str
    title: str = ""
    url: str = ""


class TakeoutProfile(BaseModel):
    """One YouTube Kids profile folder. `name` is the folder name, which is the
    child's profile name — the only child-supplied string here, and it is
    returned to the parent rather than stored."""

    name: str
    channel_count: int = 0
    channels: list[TakeoutChannel] = Field(default_factory=list)


class TakeoutParentList(BaseModel):
    """The signed-in account's own subscriptions from `subscriptions/`."""

    channel_count: int = 0
    channels: list[TakeoutChannel] = Field(default_factory=list)


class TakeoutPreview(BaseModel):
    profiles: list[TakeoutProfile] = Field(default_factory=list)
    parent: TakeoutParentList | None = None


# --- watch history (PROTOCOL.md "Watch history: opt-in, aggregate, discarded") ---
#
# The default is unchanged: history never leaves the phone. A parent may opt in
# for one import, and then the terms are narrow — the file is parsed to counts,
# the counts are written, and the file and every video title in it are dropped.
#
# That promise is a property of these shapes. There is nowhere in `HistoryAggregate`
# or `HistoryInsight` to put a video title or a video id, so no later mistake can
# persist one. `tests/test_history.py` watches every store write to prove it.


def _hours() -> list[int]:
    return [0] * 24


class HistoryChannelCount(BaseModel):
    """Internal: one channel and how many of this child's watches came from it.

    The channel id is kept only long enough to work out which channels the child
    actually follows; it never reaches the parent's screen shape below.
    """

    channel_id: str
    title: str = ""
    videos: int = 0


class HistoryAggregate(BaseModel):
    """What a watch-history file is reduced to while it is still being read."""

    videos: int = 0
    attributed: int = 0  # videos whose channel could be read (a removed video has none)
    first_watched: str | None = None  # YYYY-MM-DD
    last_watched: str | None = None
    by_hour: list[int] = Field(default_factory=_hours)
    channels: list[HistoryChannelCount] = Field(default_factory=list)


class HistoryChannel(BaseModel):
    """PROTOCOL.md `top_channels`: a name and a count, never a video."""

    title: str
    videos: int = 0
    subscribed: bool = False


class HistoryInsight(BaseModel):
    kid_id: str
    generated_at: str = Field(default_factory=now_iso)
    source: Literal["takeout"] = "takeout"
    videos: int = 0
    first_watched: str | None = None
    last_watched: str | None = None
    top_channels: list[HistoryChannel] = Field(default_factory=list)
    unsubscribed_share: float = Field(default=0.0, ge=0.0, le=1.0)
    by_hour: list[int] = Field(default_factory=_hours)
    summary: str = ""


# --- channel reviews (PROTOCOL.md "Channel reviews") ------------------------
#
# A review is a property of the channel, not of a kid, so it is cached globally.
# It is advice about what a channel publishes, never a judgement on a creator.

ReviewVerdict = Literal["good", "mixed", "concern", "unknown"]
ReviewFlagKind = Literal[
    "ads_or_merch", "consumerism", "scary", "mature_language",
    "low_quality", "off_topic", "not_for_kids", "unclear",
]


class ReviewFlag(BaseModel):
    kind: ReviewFlagKind
    note: str = Field(default="", description="One short factual line about what was seen")


class ChannelReviewDraft(BaseModel):
    """What the reviewer model returns. Everything a parent must be able to
    audit — `sample_titles`, `reviewed_at`, `model` — is filled in by code, so
    the model cannot claim to have read something it was not given."""

    verdict: ReviewVerdict
    summary: str = Field(description="One or two sentences on what this channel actually publishes")
    flags: list[ReviewFlag] = Field(default_factory=list)
    good_for: list[AgeBand] = Field(default_factory=list)


class ChannelReview(BaseModel):
    channel_id: str
    title: str = ""
    thumb_url: str = ""
    verdict: ReviewVerdict = "unknown"
    summary: str = ""
    flags: list[ReviewFlag] = Field(default_factory=list)
    good_for: list[AgeBand] = Field(default_factory=list)
    sample_titles: list[str] = Field(default_factory=list)
    reviewed_at: str = Field(default_factory=now_iso)
    model: str = ""


# --- household policy (PROTOCOL.md "Household policy: what this family actually wants") ---
#
# "Is this all right for a child" has no general answer. Without asking, the
# Curator applies someone else's taste and the parent corrects it one video at a
# time forever. These few answers are how a household says what it wants.
#
# Questions are proposed by the Coach; the answers are the parent's alone, and an
# unanswered question simply never appears in `answers`, so it carries no weight.

PolicyChoice = Literal["fine", "sometimes", "rather_not"]
POLICY_OPTIONS: list[PolicyChoice] = ["fine", "sometimes", "rather_not"]

# How far an answer actually travels, which is what `weight` reports. It is not a
# knob a parent or a model sets: `rather_not` is enforced in code (a video the
# Curator attributes to it goes to the parent rather than being decided
# silently), while the other two only reach the model as context.
POLICY_WEIGHTS: dict[str, float] = {"rather_not": 1.0, "sometimes": 0.5, "fine": 0.5}


class PolicyQuestion(BaseModel):
    """One question worth asking THIS parent. `why` names the channels that
    prompted it, so the parent can see it was not a guess."""

    id: str
    question: str
    why: str = ""
    options: list[PolicyChoice] = Field(default_factory=lambda: list(POLICY_OPTIONS))


class PolicyQuestionDraft(BaseModel):
    """What the model returns. The id is assigned in code from the question text,
    so the same question keeps the same id across re-asks and an answer given
    last month still lines up with it."""

    question: str
    why: str = ""


class SuggestedPolicyQuestions(BaseModel):
    questions: list[PolicyQuestionDraft] = Field(default_factory=list)


class PolicyAnswer(BaseModel):
    id: str
    question: str = ""
    choice: PolicyChoice
    weight: float = Field(default=0.5, ge=0.0, le=1.0)

    @model_validator(mode="after")
    def _weight_from_choice(self) -> PolicyAnswer:
        # Derived, never accepted from the wire: `weight` is a report of what the
        # server does with this answer, so a client cannot inflate its own.
        self.weight = POLICY_WEIGHTS[self.choice]
        return self


class Policy(BaseModel):
    """An empty policy is valid and means the Curator falls back to age-band
    defaults (PROTOCOL.md)."""

    kid_id: str
    updated_at: str = Field(default_factory=now_iso)
    answers: list[PolicyAnswer] = Field(default_factory=list)
    notes: str = ""

    def rather_not(self) -> dict[str, PolicyAnswer]:
        """The answers that are enforced in code, by question id."""
        return {a.id: a for a in self.answers if a.choice == "rather_not"}

    def is_empty(self) -> bool:
        return not self.answers and not self.notes.strip()


# --- channel drift (PROTOCOL.md "Channel drift: a channel is not what it was") ---
#
# A review is a snapshot. Channels change hands, chase trends, and start running
# gambling ads two years after a parent approved them. A drift is information:
# it raises an entry in the parent's inbox and stops there. HeyGilli never
# removes a channel by itself.


class ChannelSnapshot(BaseModel):
    """One review as it stood, reduced to what a comparison turns on."""

    verdict: ReviewVerdict = "unknown"
    flags: list[ReviewFlag] = Field(default_factory=list)
    reviewed_at: str = ""


class ChannelDrift(BaseModel):
    channel_id: str
    title: str = ""
    was: ChannelSnapshot = Field(default_factory=ChannelSnapshot)
    now: ChannelSnapshot = Field(default_factory=ChannelSnapshot)
    worse: bool = False
    what_changed: str = ""
    sample_titles: list[str] = Field(default_factory=list)


class DriftNote(BaseModel):
    """Model output: the one sentence naming the difference."""

    what_changed: str = Field(description="One sentence naming what changed, not restating the review")


class Screening(BaseModel):
    age_ok: list[AgeBand] = Field(default_factory=list)
    topics: list[str] = Field(default_factory=list)
    reason: str = ""


class Video(BaseModel):
    id: str  # YouTube video id
    channel_id: str = ""
    title: str = ""
    duration_s: int = 0
    thumb_url: str = ""
    age_ok: bool = False
    plan_ready: bool = False
    description: str = ""
    published_at: str | None = None
    transcript_source: str | None = None
    screening: Screening = Field(default_factory=Screening)
    ingested_at: str | None = None

    def public(self) -> dict:
        """The PROTOCOL.md `Video` object (client never sees screening internals)."""
        return self.model_dump(
            include={"id", "channel_id", "title", "duration_s", "thumb_url", "age_ok", "plan_ready"}
        )


# --- question plan -------------------------------------------------------------


class Option(BaseModel):
    icon_id: str
    label: str
    correct: bool = False


class RevisitTag(BaseModel):
    """Bookkeeping for the parent's screen, never for the child's.

    A child noticing they are being retested is the failure mode this whole
    feature has to avoid, so this tag says a question is a revisit while nothing
    in the question's own `text` refers to the past — and it is not on
    `ServerAsk`, so it never reaches the device at all.
    """

    concept: str
    last_seen: str = ""  # YYYY-MM-DD, when this concept was last asked about


class Question(BaseModel):
    t_sec: int = Field(ge=0)
    type: QuestionType
    input: InputMode
    text: str
    expected: str = ""
    variants: list[str] = Field(default_factory=list)
    model_line: str = ""
    followup: str = ""
    gesture: Gesture = "idle"
    options: list[Option] = Field(default_factory=list)
    revisit: RevisitTag | None = None  # null on all but at most one question per plan
    word: WordTag | None = None  # null on all but at most one question per plan


class RevisitDraft(BaseModel):
    """What the model returns for a revisit: one question about the earlier
    concept, asked of the video the child is watching now.

    An empty `text` is a valid answer and means "this video gives me no way to
    ask about that". Leaving the escape hatch open is what stops the model
    forcing a question about volcanoes into a video about giraffes.
    """

    text: str = Field(description="The question, or empty if this video cannot carry it")
    expected: str = Field(default="", description="The gist of a good answer")
    variants: list[str] = Field(default_factory=list)
    followup: str = Field(default="", description="One extra fact to share after a correct answer")


class WordTag(BaseModel):
    """A word Gilli is offering, or asking back for (PROTOCOL.md "Bilingual word
    seeding").

    `term` is always a word from the curated icon library, never something a
    model translated: this is the one place the product teaches rather than
    checks, and a wrong word taught confidently is worse than no word at all.
    """

    term: str  # the word in the second language
    language: Language = "ur"
    gloss: str = ""  # what it means, in the language the child is watching in
    first_heard: bool = False  # true when Gilli is modelling it for the first time


class WordSeed(BaseModel):
    """One second-language word this child has met. `times_said == 0` is exactly
    what the parent's analytics screen calls an `emerging` word."""

    kid_id: str
    term: str
    language: Language = "ur"
    gloss: str = ""
    times_heard: int = 0
    times_said: int = 0
    first_heard: str = ""  # YYYY-MM-DD
    last_heard: str = ""


class RevisitConcept(BaseModel):
    """`GET /kids/{kid_id}/revisits`: what the parent sees."""

    concept: str
    times_shaky: int = 0
    last_seen: str = ""
    asked_again: int = 0


class RevisitRecord(BaseModel):
    """What was actually asked again, and when. The counter is what enforces
    "nothing is ever asked a third time"."""

    kid_id: str
    concept: str
    asked_again: int = 0
    last_asked_at: str = ""
    last_session_id: str = ""


class QuestionPlan(BaseModel):
    video_id: str
    age_band: AgeBand
    language: Language
    questions: list[Question] = Field(default_factory=list)
    created_at: str = Field(default_factory=now_iso)

    @staticmethod
    def key(video_id: str, age_band: str, language: str) -> str:
        return f"{video_id}#{age_band}#{language}"


class PlanDraft(BaseModel):
    """What the Planner model returns; rules are enforced in code afterwards."""

    questions: list[Question]


# --- live session -----------------------------------------------------------------


class Session(BaseModel):
    id: str = Field(default_factory=lambda: new_id("ses"))
    household_id: str
    kid_id: str
    device: str = "tv"
    video_id: str
    age_band: AgeBand
    language: Language = "en"
    started_at: str = Field(default_factory=now_iso)
    ended_at: str | None = None
    watched_sec: int = 0
    date: str = Field(default_factory=lambda: datetime.now(UTC).date().isoformat())


def _cap_words(text: str, limit: int = 10) -> str:
    words = text.split()
    return " ".join(words[:limit])


class Score(BaseModel):
    """The only thing kept from what a child said (SPEC §7.4, §10)."""

    result: Result
    paraphrase: str = ""
    word_said: str | None = None

    @field_validator("paraphrase", mode="before")
    @classmethod
    def _cap(cls, v: str | None) -> str:
        return _cap_words(v or "")


class ScoredReply(Score):
    """Model output for 7_8 / 9_11 voice answers: a score plus the spoken reply."""

    reply_text: str = Field(description="What the buddy says back, one or two short sentences")


class Answer(BaseModel):
    id: str = Field(default_factory=lambda: new_id("ans"))
    session_id: str
    question_idx: int
    input_used: AnswerInput
    result: Result
    paraphrase: str = ""
    word_said: str | None = None
    latency_ms: int = 0
    created_at: str = Field(default_factory=now_iso)

    @field_validator("paraphrase", mode="before")
    @classmethod
    def _cap(cls, v: str | None) -> str:
        return _cap_words(v or "")


# --- time limits and movement breaks (PROTOCOL.md) --------------------------------------
#
# A break is a physical activity built from what the child just watched. It is
# generated by the Coach agent but every field below is checked in code
# (`breaks.validate`) before a child ever hears it: a wrong task here is an
# adult telling a six-year-old to climb something.


class BreakMessage(BaseModel):
    """One line a parent wants Gilli to say when watching pauses.

    Parent-authored. The model may propose these in the parent app, but nothing
    reaches a child until the parent saves it, so by the time a break starts
    every word Gilli can say was written or approved by a parent.
    """

    id: str = Field(default_factory=lambda: new_id("msg"))
    text: str = Field(description="Shown to bands 7_8 and 9_11")
    spoken: str = Field(default="", description="What Gilli says aloud; the whole message for band 4_6")

    def say(self) -> str:
        return self.spoken.strip() or self.text.strip()


class SuggestedMessages(BaseModel):
    """What the coach hands the parent to choose from."""

    messages: list[BreakMessage] = Field(default_factory=list)


class BreakTask(BaseModel):
    """What Gilli asks the child to do. Also the Coach agent's structured output."""

    title: str = Field(description="Three or four words a parent could read at a glance")
    steps: list[str] = Field(
        default_factory=list,
        description="What to do, one line each. Exactly one line for band 4_6.",
    )
    seconds: int = Field(default=90, description="How long it should take, 60 to 180")
    spoken: str = Field(default="", description="What Gilli says out loud; the whole task for band 4_6")


class BreakPeriod(BaseModel):
    """One break, running from `started_at` to `ends_at`.

    The clock ends it, not the child: `acked` records only that they say they
    did it. A parent override ends one early by moving `ends_at` to now, which
    is also what resets the continuous-watching count.
    """

    id: str = Field(default_factory=lambda: new_id("brk"))
    kid_id: str
    started_at: str = Field(default_factory=now_iso)
    ends_at: str
    seconds_left: int = 0
    message: BreakMessage | None = None
    is_firm: bool = True
    acked: bool = False

    def remaining(self, now: datetime | None = None) -> int:
        ends = parse_iso(self.ends_at)
        if ends is None:
            return 0
        now = now or datetime.now(UTC)
        return max(0, int((ends - now).total_seconds()))

    def is_active(self, now: datetime | None = None) -> bool:
        return self.remaining(now) > 0

    def at(self, now: datetime | None = None) -> BreakPeriod:
        """A copy with `seconds_left` recomputed, so the client never sees a stale count."""
        return self.model_copy(update={"seconds_left": self.remaining(now)})


BlockedReason = Literal["daily_limit", "break"]


class WatchState(BaseModel):
    """`GET /kids/{id}/state`: what the client checks before offering anything.

    `minutes_left_today` is null when the kid has no daily limit
    (`daily_minutes = 0`); `watching_allowed` is always the real gate.
    """

    minutes_today: int = 0
    minutes_left_today: int | None = None
    continuous_minutes: int = 0
    watching_allowed: bool = True
    blocked_reason: BlockedReason | None = None
    active_break: BreakPeriod | None = None


# --- digest / parent ------------------------------------------------------------------


class Digest(BaseModel):
    kid_id: str
    date: str
    minutes: int = 0
    videos: int = 0
    asked: int = 0
    answered: int = 0
    understood: list[str] = Field(default_factory=list)
    shaky: list[str] = Field(default_factory=list)
    words_said: list[str] = Field(default_factory=list)
    words_heard: list[str] = Field(default_factory=list)
    dinner_prompt: str = ""
    kind: Literal["prereader", "older"] = "older"
    notify: bool = False


class DigestNarrative(BaseModel):
    """Model output; counts are computed in code, the model writes the words."""

    understood: list[str] = Field(default_factory=list)
    shaky: list[str] = Field(default_factory=list)
    words_heard: list[str] = Field(default_factory=list)
    dinner_prompt: str
    notify: bool = False
    notify_reason: str = ""


# --- parent analytics (PROTOCOL.md "Analytics") -----------------------------------------------


class AnalyticsTotals(BaseModel):
    minutes: int = 0
    videos: int = 0
    sessions: int = 0
    asked: int = 0
    answered: int = 0
    answer_rate: float = Field(default=0.0, ge=0.0, le=1.0)


class AnalyticsDay(BaseModel):
    date: str
    minutes: int = 0
    videos: int = 0
    asked: int = 0
    answered: int = 0


class VocabWord(BaseModel):
    word: str
    times_said: int = 0
    first_said: str  # YYYY-MM-DD


class EmergingWord(BaseModel):
    """Gilli asked for the word; the child has not said it back yet."""

    word: str
    times_heard: int = 0


class AnalyticsVocabulary(BaseModel):
    total_said: int = 0
    new_this_week: int = 0
    said: list[VocabWord] = Field(default_factory=list)
    emerging: list[EmergingWord] = Field(default_factory=list)


class ConceptStat(BaseModel):
    concept: str
    asked: int = 0
    understood: int = 0
    shaky: int = 0
    last_seen: str


class NeedsAnotherLook(BaseModel):
    concept: str
    times_shaky: int = 0
    last_seen: str


class ChannelStat(BaseModel):
    channel_id: str
    title: str = ""
    minutes: int = 0
    videos: int = 0


class AnalyticsNote(BaseModel):
    """One or two sentences from the Digest agent; also the model's structured output."""

    kind: Literal["praise", "suggestion", "watch", "quiet"] = "quiet"
    text: str = Field(default="", description="One or two plain sentences for the parent")


class Analytics(BaseModel):
    kid_id: str
    band: AgeBand
    days: int
    generated_at: str = Field(default_factory=now_iso)
    totals: AnalyticsTotals = Field(default_factory=AnalyticsTotals)
    daily: list[AnalyticsDay] = Field(default_factory=list)
    vocabulary: AnalyticsVocabulary = Field(default_factory=AnalyticsVocabulary)
    concepts: list[ConceptStat] = Field(default_factory=list)
    needs_another_look: list[NeedsAnotherLook] = Field(default_factory=list)
    channels: list[ChannelStat] = Field(default_factory=list)
    note: AnalyticsNote = Field(default_factory=AnalyticsNote)


class ParentPrompt(BaseModel):
    """Something the parent is being asked to decide.

    Two kinds now. `video` is the original: the Curator could not settle an
    upload alone. `channel_drift` is a channel that is no longer what it was
    when the parent approved it; it carries a `ChannelDrift` instead of a video,
    and deciding on it never removes anything (PROTOCOL.md "Channel drift").
    Both keys are always present on the wire, one of them null, so a client can
    switch on `kind` without guessing.
    """

    id: str = Field(default_factory=lambda: new_id("pp"))
    household_id: str
    kid_id: str
    kind: Literal["video", "channel_drift"] = "video"
    video: Video | None = None
    drift: ChannelDrift | None = None
    reason: str
    created_at: str = Field(default_factory=now_iso)
    decision: Literal["approve", "hide"] | None = None

    def public(self) -> dict:
        return {
            "id": self.id,
            "kid_id": self.kid_id,
            "kind": self.kind,
            "video": self.video.public() if self.video else None,
            "drift": self.drift.model_dump() if self.drift else None,
            "reason": self.reason,
            "created_at": self.created_at,
        }


class CuratorDecision(BaseModel):
    decision: Literal["approve", "hide", "ask_parent"]
    reason: str = Field(description="One line a parent can read")
    topics: list[str] = Field(default_factory=list)
    policy_id: str = Field(
        default="",
        description="If this decision turns on one of the household's own policy answers, "
                    "that answer's id; otherwise empty.",
    )


# --- WebSocket messages (PROTOCOL.md) ------------------------------------------------------


class ClientHello(BaseModel):
    t: Literal["hello"]


class ClientPosition(BaseModel):
    t: Literal["position"]
    seconds: float


class ClientAnswer(BaseModel):
    t: Literal["answer"]
    q: int
    input: AnswerInput
    transcript: str | None = None
    option: int | None = Field(default=None, ge=0, le=2)


class ClientResumed(BaseModel):
    t: Literal["resumed"]


class ClientBye(BaseModel):
    t: Literal["bye"]


ClientMessage = Annotated[
    ClientHello | ClientPosition | ClientAnswer | ClientResumed | ClientBye,
    Field(discriminator="t"),
]


class ServerReady(BaseModel):
    t: Literal["ready"] = "ready"
    plan_questions: int
    age_band: AgeBand
    language: Language


class ServerPause(BaseModel):
    t: Literal["pause"] = "pause"


class ServerAsk(BaseModel):
    t: Literal["ask"] = "ask"
    q: int
    type: QuestionType
    input: InputMode
    text: str | None = None  # omitted for band 4_6
    speak: str | None = None  # what on-device TTS says when tts_url is empty (needed for 4_6)
    tts_url: str = ""
    listen_ms: int
    options: list[Option] | None = None
    gesture: Gesture = "idle"


class ServerReply(BaseModel):
    t: Literal["reply"] = "reply"
    text: str | None = None
    tts_url: str = ""
    result: Result
    gesture: Gesture = "idle"
    model_word: str | None = None
    # The second-language word Gilli is offering, sent apart from `text` because
    # Polly has no Urdu voice: the client speaks it with the device's own voice,
    # or leaves it out entirely when the device has no such voice installed
    # (PROTOCOL.md "Bilingual word seeding" and "TTS").
    word: WordTag | None = None


class ServerResume(BaseModel):
    t: Literal["resume"] = "resume"


class ServerEnd(BaseModel):
    t: Literal["end"] = "end"
    summary_tts_url: str = ""
    summary_text: str | None = None  # on-device TTS fallback when summary_tts_url is empty
    words_said: list[str] = Field(default_factory=list)


class ServerBreak(BaseModel):
    """`{t: "break", break: BreakPeriod}`. The client stops playback on this
    message; nothing plays again until the break's clock runs out."""

    t: Literal["break"] = "break"
    brk: BreakPeriod = Field(serialization_alias="break")

    model_config = {"populate_by_name": True}


class ServerError(BaseModel):
    t: Literal["error"] = "error"
    message: str


def wire(msg: BaseModel) -> dict:
    """Serialise a server message, dropping None fields (text omitted for 4_6).

    `by_alias` is what turns `ServerBreak.brk` into the wire's `break`, which
    cannot be a Python attribute name.
    """
    return msg.model_dump(exclude_none=True, by_alias=True)
