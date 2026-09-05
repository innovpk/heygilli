"""Pydantic v2 models: SPEC §10 data model + docs/PROTOCOL.md wire objects.

Everything the client parses, every structured output the agents return, and
every record the store persists is defined here so there is one vocabulary.
"""
from __future__ import annotations

import uuid
from datetime import UTC, datetime
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


# --- household / kid ----------------------------------------------------------


class Kid(BaseModel):
    id: str = Field(default_factory=lambda: new_id("kid"))
    household_id: str
    nickname: str
    age: int = Field(ge=3, le=12)
    age_band: AgeBand | None = None
    languages: list[Language] = Field(default_factory=lambda: ["en"])
    avatar: str = "gilli"
    question_freq: QuestionFreq = "normal"
    daily_minutes: int = 60

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


class ParentPrompt(BaseModel):
    id: str = Field(default_factory=lambda: new_id("pp"))
    household_id: str
    kid_id: str
    video: Video
    reason: str
    created_at: str = Field(default_factory=now_iso)
    decision: Literal["approve", "hide"] | None = None

    def public(self) -> dict:
        return {
            "id": self.id,
            "kid_id": self.kid_id,
            "video": self.video.public(),
            "reason": self.reason,
            "created_at": self.created_at,
        }


class CuratorDecision(BaseModel):
    decision: Literal["approve", "hide", "ask_parent"]
    reason: str = Field(description="One line a parent can read")
    topics: list[str] = Field(default_factory=list)


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


class ServerResume(BaseModel):
    t: Literal["resume"] = "resume"


class ServerEnd(BaseModel):
    t: Literal["end"] = "end"
    summary_tts_url: str = ""
    summary_text: str | None = None  # on-device TTS fallback when summary_tts_url is empty
    words_said: list[str] = Field(default_factory=list)


class ServerError(BaseModel):
    t: Literal["error"] = "error"
    message: str


def wire(msg: BaseModel) -> dict:
    """Serialise a server message, dropping None fields (text omitted for 4_6)."""
    return msg.model_dump(exclude_none=True)
