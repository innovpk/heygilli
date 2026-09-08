"""FastAPI gateway implementing docs/PROTOCOL.md.

    uv run uvicorn heygilli_agents.gateway:app --port 8080

REST for auth, kids, channels, home, sessions, digest, parent inbox; one
WebSocket per session that drives the Buddy loop. Dev auth: a signed token per
household; one household per token is all the hackathon needs.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import logging
import os
import time
from datetime import UTC, datetime
from typing import Annotated, Literal

from dotenv import load_dotenv
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    File,
    Form,
    Header,
    HTTPException,
    UploadFile,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

from . import breaks, coach, drift, history, question_bank, revisit, words
from . import starter_channels as starter_channels_data
from .analytics import DEFAULT_DAYS, run_analytics
from .buddy import SessionEngine
from .curator import run_curator
from .digest import run_digest
from .google_auth import (
    GoogleAuthError,
    GoogleNeedsRelink,
    GoogleNotConfigured,
    GoogleNotLinked,
    link_household,
)
from .planner import ensure_plan, fallback_plan
from .reviewer import review_channel
from .schemas import (
    AuthSession,
    BreakMessage,
    BreakPeriod,
    Channel,
    ChannelDrift,
    ChannelReview,
    ClientAnswer,
    ClientMessage,
    Kid,
    Language,
    ParentPrompt,
    Policy,
    PolicyAnswer,
    ServerBreak,
    ServerError,
    ServerPause,
    ServerResume,
    Session,
    Video,
    WatchState,
    new_id,
    wire,
)
from .store import get_store
from .takeout import (
    MAX_ZIP_BYTES,
    TakeoutError,
    parse_takeout_zip,
    parse_takeout_zip_with_history,
)
from .tools import transcript as transcript_sources
from .tools.screening import prescreen
from .tools.tts import TTS_DIR, synthesize
from .tools.youtube import (
    SearchUnavailable,
    fetch_video_meta,
    resolve_channel_url,
)
from .tools.youtube import search_channels as search_youtube_channels
from .tools.youtube import search_key_source as youtube_search_key_source

load_dotenv()
log = logging.getLogger("heygilli.gateway")
logging.basicConfig(level=os.getenv("HEYGILLI_LOG", "INFO"))


class _DropHealthChecks(logging.Filter):
    """Keep the platform's liveness probe out of the access log.

    Render polls /healthz every few seconds forever, which buries every real
    request. Dropped at the access logger rather than by lowering the log level,
    so a genuine 4xx/5xx on any other route is still visible.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        return "/healthz" not in record.getMessage()


logging.getLogger("uvicorn.access").addFilter(_DropHealthChecks())

SECRET = os.getenv("HEYGILLI_SECRET", "dev-secret-change-me").encode()
ANSWER_GRACE_MS = 1500  # PROTOCOL: listen_ms + 1500 ms -> input "none"
PREREADER_ECHO_WAIT_S = 3.0  # SPEC §7.4: "Can you say giraffe?" then 3 s, then resume regardless

app = FastAPI(title="HeyGilli gateway", version="1.0")
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"], allow_credentials=False
)
TTS_DIR.mkdir(parents=True, exist_ok=True)
app.mount("/tts", StaticFiles(directory=str(TTS_DIR)), name="tts")


# --- auth -----------------------------------------------------------------------------------------


def sign(household_id: str) -> str:
    mac = hmac.new(SECRET, household_id.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{household_id}.{mac}"


def verify(token: str) -> str:
    household_id, _, mac = token.partition(".")
    if not household_id or not hmac.compare_digest(sign(household_id), f"{household_id}.{mac}"):
        raise HTTPException(401, "bad token")
    return household_id


def household(authorization: str = Header(default="")) -> str:
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() != "bearer" or not token:
        raise HTTPException(401, "missing bearer token")
    return verify(token)


class DevAuthIn(BaseModel):
    name: str = "parent"


@app.post("/auth/dev")
def auth_dev(body: DevAuthIn) -> dict:
    """Kept as a fallback: it needs no Google project and no network."""
    hid = "hh_" + hashlib.sha1(body.name.strip().lower().encode()).hexdigest()[:10]
    return {"token": sign(hid), "household_id": hid}


# --- Google sign-in (PROTOCOL.md "Google sign-in and subscription import") ----------------------


class GoogleAuthIn(BaseModel):
    server_auth_code: str
    #: What the code was minted against: "" from a phone, "postmessage" from a
    #: browser popup. PROTOCOL "Google sign-in and subscription import".
    redirect_uri: str = ""


def _google_http(e: GoogleAuthError) -> HTTPException:
    """Turn a Google failure into something the parent can act on. Never a 500."""
    if isinstance(e, GoogleNotConfigured):
        return HTTPException(503, str(e))
    if isinstance(e, GoogleNeedsRelink):
        return HTTPException(401, f"needs re-linking: {e}")
    if isinstance(e, GoogleNotLinked):
        return HTTPException(409, str(e))
    return HTTPException(502, str(e))


@app.post("/auth/google")
def auth_google(body: GoogleAuthIn, authorization: str = Header(default="")) -> dict:
    """Server auth code from any client -> a household token.

    The client sends the *server auth code*, never an access token: the refresh
    token is minted here and stays here. An optional bearer token attaches
    Google to the household the parent is already using (they started on
    `/auth/dev`); without one the household is derived from the Google account,
    so signing in again lands in the same household.
    """
    started_in: str | None = None
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() == "bearer" and token:
        with contextlib.suppress(HTTPException):
            started_in = verify(token)
    try:
        hid, link = link_household(
            body.server_auth_code, get_store(), started_in, body.redirect_uri
        )
    except GoogleAuthError as e:
        raise _google_http(e) from e
    return AuthSession(
        token=sign(hid), household_id=hid, email=link.email, youtube_linked=True
    ).model_dump()


@app.get("/me/youtube")
def me_youtube(hid: str = Depends(household)) -> dict:
    """`{linked, email}`. `email` is null when no Google account is linked."""
    link = get_store().get_google_link(hid)
    return {"linked": link is not None, "email": link.email if link else None}


def _approved_by_channel(hid: str) -> dict[str, list[str]]:
    """channel id -> the kid ids it is already approved for (`approved_for`)."""
    store = get_store()
    out: dict[str, list[str]] = {}
    for kid in store.list_kids(hid):
        for ch in store.list_channels(hid, kid.id):
            if ch.approved:
                out.setdefault(ch.id, []).append(kid.id)
    return out


class KidIn(BaseModel):
    nickname: str
    age: int = Field(ge=3, le=12)
    languages: list[Language] = Field(default_factory=lambda: ["en"])


def _kid(hid: str, kid_id: str) -> Kid:
    kid = get_store().get_kid(hid, kid_id)
    if not kid:
        raise HTTPException(404, "kid not found")
    return kid


@app.post("/kids")
def create_kid(body: KidIn, hid: str = Depends(household)) -> dict:
    kid = Kid(household_id=hid, **body.model_dump())
    get_store().put_kid(kid)
    return kid.model_dump()


@app.get("/kids")
def list_kids(hid: str = Depends(household)) -> list[dict]:
    return [k.model_dump() for k in get_store().list_kids(hid)]


@app.get("/starter-channels")
def starter_channels(band: str = "7_8", topics: str = "") -> dict:
    """Channels to offer a household with none yet, for this band and these
    topics.

    Setting up used to require bringing channels from elsewhere — a Google
    account to read subscriptions from, or a Takeout export the parent had to
    request and wait for. A parent with neither had an empty app.

    `topics` is a comma-separated subset of `TOPICS`; empty means "no
    preference" and returns everything written for the band, because "I do not
    know yet" is the commonest answer during setup.

    Suggestions only. Nothing here is approved until the parent says so, and
    being on this list buys a channel nothing at screening time: the Curator
    still reads every upload against this household's own answers.
    """
    if band not in ("4_6", "7_8", "9_11"):
        raise HTTPException(422, f"unknown band {band!r}")
    wanted = [t.strip() for t in topics.split(",") if t.strip()]
    return {
        "topics": [{"id": t, "label": label} for t, label in starter_channels_data.TOPICS],
        "channels": [
            {
                "channel_id": c.channel_id,
                "title": c.title,
                "blurb": c.blurb,
                "topics": list(c.topics),
            }
            for c in starter_channels_data.suggest(band, wanted)
        ],
    }


@app.get("/channels/search")
def search_channels_endpoint(
    q: str, hid: str = Depends(household)
) -> dict:
    """Channels on YouTube matching what the parent typed.

    Behind the household token, because it spends a shared daily allowance:
    `search.list` costs 100 quota units of a default 10,000, so this is a
    hundred searches a day across every household. Nothing calls it
    automatically for that reason.

    A parent searching is not a child searching. The result is a suggestion
    they then approve, and every upload from an approved channel is still read
    against their answers — the allowlist is untouched. A child's own home has
    no path to YouTube at all.
    """
    already = _approved_by_channel(hid)
    try:
        found = search_youtube_channels(q)
    except SearchUnavailable as e:
        # A setup or quota problem is not an empty result: a parent retyping
        # their query would never fix it, so say what happened.
        raise HTTPException(503, str(e)) from e
    return {
        "query": q.strip(),
        "channels": [
            {**c, "approved_for": already.get(c["channel_id"], [])} for c in found
        ],
    }


@app.delete("/kids/{kid_id}")
def delete_kid(kid_id: str, confirm: str = "", hid: str = Depends(household)) -> dict:
    """Remove one child and everything about them.

    Irreversible and not undoable anywhere, so the client has to name the
    child back: `?confirm=<nickname>`. A stray DELETE, a retried request or a
    mis-tapped row cannot take a child's history with it.

    Their siblings are untouched, and so are the shared video, plan and
    channel-review caches — those are keyed by video and belong to every
    household, not to this one.
    """
    kid = _kid(hid, kid_id)
    if confirm.strip().casefold() != kid.nickname.strip().casefold():
        raise HTTPException(
            400,
            f"To delete {kid.nickname}, send ?confirm={kid.nickname}. "
            "This removes everything about them and cannot be undone.",
        )
    get_store().delete_kid(hid, kid_id)
    log.info("deleted kid %s and everything about them", kid_id)
    return {"deleted": kid_id}


@app.delete("/me")
def delete_household(confirm: str = "", hid: str = Depends(household)) -> dict:
    """Remove this household: every child, every channel, every session.

    The account and everything in it, with nothing kept behind — the promise
    a parent is owed when they ask to be forgotten. `?confirm=DELETE` is
    required, so this cannot happen by a mistyped URL.

    The shared caches survive: video metadata, question plans and channel
    reviews are keyed by video or channel and belong to every household. What
    goes is everything that says anything about *this* family.
    """
    if confirm != "DELETE":
        raise HTTPException(
            400,
            "To delete this household and everything in it, send "
            "?confirm=DELETE. This cannot be undone.",
        )
    store = get_store()
    kids = len(store.list_kids(hid))
    store.delete_household(hid)
    log.info("deleted household %s (%d kids)", hid, kids)
    return {"deleted": hid, "kids": kids}


@app.get("/avatars")
def list_avatars() -> dict:
    """The faces a child may choose from. Named here so the app cannot offer
    one the server would reject, and so the list can grow without a release."""
    return {"avatars": list(AVATAR_ICONS)}


@app.get("/kids/{kid_id}/prompts")
def get_prompts(kid_id: str, hid: str = Depends(household)) -> dict:
    """Every question written for this child's band, and whether it is on.

    The band decides the list: a four-year-old is asked to make a sound or name
    something they can see, an eleven-year-old what they would tell a friend.
    Change the child's age and this list changes with it, which is the point.

    On by default. A parent who has never opened this screen still gets a
    working app, and turning one off is a fact stored about their household
    rather than an edit to the bank.
    """
    kid = _kid(hid, kid_id)
    band = kid.age_band or "7_8"
    off = set(kid.disabled_prompts)
    return {
        "age_band": band,
        "prompts": [
            {
                "id": p.id,
                "label": p.label or p.text["en"],
                "text": p.text,
                "type": p.type,
                "input": p.input,
                "enabled": p.id not in off,
            }
            for p in question_bank.for_band(band)
        ],
    }


class PromptsIn(BaseModel):
    """The ids the parent turned OFF. Sent whole, so unticking the last one is
    telling us something rather than sending nothing."""

    disabled: list[str] = Field(default_factory=list)


@app.put("/kids/{kid_id}/prompts")
def set_prompts(kid_id: str, body: PromptsIn, hid: str = Depends(household)) -> dict:
    """Replace what this child is not asked.

    Ids that name nothing in the bank are kept rather than rejected: a
    household outlives a release, and a prompt that comes back later must come
    back still switched off.

    Existing plans are left alone. They were built for the old list and are
    cached per video; the next video screened uses the new one, and a parent
    who wants the old ones gone can say so by other means rather than having
    this quietly rewrite what their child has already been asked.
    """
    kid = _kid(hid, kid_id)
    kid = kid.model_copy(update={"disabled_prompts": list(dict.fromkeys(body.disabled))})
    get_store().put_kid(kid)
    log.info("kid %s has %d prompts turned off", kid_id, len(kid.disabled_prompts))
    return get_prompts(kid_id, hid)


#: Icons a child may wear. A subset of the icon library — creatures and things
#: a child would pick, not colours, numbers or feelings, which are answers to
#: questions and would read as a score rather than a face.
AVATAR_ICONS: tuple[str, ...] = (
    "cat", "dog", "duck", "frog", "lion", "monkey",
    "elephant", "giraffe", "bird", "butterfly", "fish", "cow",
    "squirrel", "rocket", "star", "sun", "moon", "flower",
    "boat", "train", "tree", "mango",
)


class KidEditIn(BaseModel):
    """What a parent may correct about a child. Every field optional: this is a
    correction, not a re-registration."""

    nickname: str | None = None
    age: int | None = Field(default=None, ge=3, le=12)
    languages: list[Language] | None = None
    #: An icon id from `AVATAR_ICONS`, or "" to go back to their initial.
    #: Checked against the list rather than taken as given: this string is
    #: rendered as an asset path, and a child picking their own face is the one
    #: place a client sends something a child chose.
    avatar: str | None = None


@app.patch("/kids/{kid_id}")
def edit_kid(kid_id: str, body: KidEditIn, hid: str = Depends(household)) -> dict:
    """Correct a child's name, age or languages.

    There was no way to do this at all: a child entered with the wrong age was
    stuck with it, and age is not cosmetic — it sets the age band, which is
    what the Curator screens against and what decides whether the child is
    read to or shown text.

    Changing the age re-derives the band rather than keeping the old one, which
    is the whole point of the edit. Nothing already screened is re-screened
    here: those decisions were made for the old band and the parent can ask for
    a fresh run themselves, which is a slow job and their choice to start.
    """
    kid = _kid(hid, kid_id)
    updates = {k: v for k, v in body.model_dump().items() if v is not None}
    avatar = updates.get("avatar")
    if avatar and avatar not in AVATAR_ICONS:
        raise HTTPException(422, f"unknown avatar {avatar!r}")
    if "age" in updates and updates["age"] != kid.age:
        updates["age_band"] = None  # re-derived from the new age by Kid's validator
    kid = Kid(**{**kid.model_dump(), **updates})
    get_store().put_kid(kid)
    log.info("kid %s edited: %s", kid_id, updates or "unchanged")
    return kid.model_dump()


# --- household policy (PROTOCOL.md "Household policy: what this family actually wants") ----------


class PolicyIn(BaseModel):
    """What the parent saves. `weight` is not accepted from the wire: it reports
    what the server does with an answer, so it is derived in `PolicyAnswer`."""

    answers: list[PolicyAnswer] = Field(default_factory=list)
    notes: str = ""


@app.get("/kids/{kid_id}/policy")
def get_policy(kid_id: str, hid: str = Depends(household)) -> dict:
    """A kid who was never asked has an empty policy, not a 404: nothing is
    wrong, this family simply has not said anything yet and the Curator falls
    back to age-band defaults."""
    kid = _kid(hid, kid_id)
    policy = get_store().get_policy(hid, kid.id) or Policy(kid_id=kid.id)
    return policy.model_dump()


@app.put("/kids/{kid_id}/policy")
def put_policy(kid_id: str, body: PolicyIn, hid: str = Depends(household)) -> dict:
    """Replace this kid's policy. The answers are the parent's alone.

    An id answered twice keeps the last one, because the parent's most recent
    tap is what they meant.
    """
    kid = _kid(hid, kid_id)
    deduped = {a.id: a for a in body.answers if a.id.strip()}
    policy = Policy(kid_id=kid.id, answers=list(deduped.values()), notes=body.notes)
    get_store().put_policy(hid, policy)
    log.info("policy for kid %s: %d answer(s), notes %s", kid_id, len(policy.answers),
             "set" if policy.notes.strip() else "empty")
    return policy.model_dump()


@app.post("/kids/{kid_id}/policy/questions")
def policy_questions(kid_id: str, hid: str = Depends(household)) -> dict:
    """Questions worth asking THIS parent, drawn from what this child watches.

    Parent-facing only: nothing here is ever shown to a child, and asking again
    is free — an id is derived from the question text, so a question the parent
    has already answered comes back under the same id.
    """
    kid = _kid(hid, kid_id)
    store = get_store()
    channels = [c.title for c in store.list_channels(hid, kid.id) if c.approved]
    titles = _video_titles(store, [s.video_id for s in store.list_sessions(hid, kid.id)])
    questions = coach.suggest_policy_questions(kid, channels, titles)
    # Whether there was anything to draw on. A child with no channels yet gets
    # the common questions every family is asked, and the screen must be able
    # to say so: claiming a question came from this child's own channels when
    # it did not is the kind of small lie that costs a parent's trust in the
    # rest of the page.
    return {
        "questions": [q.model_dump() for q in questions],
        "based_on": channels[:6],
    }


# --- time limits and movement breaks (PROTOCOL.md) -----------------------------------------------


class LimitsIn(BaseModel):
    """Every field optional: a parent changing one limit does not reset the rest."""

    daily_minutes: int | None = Field(default=None, ge=0)
    break_after_minutes: int | None = Field(default=None, ge=0)
    break_minutes: int | None = Field(default=None, ge=1)
    max_video_minutes: int | None = Field(default=None, ge=0)
    break_is_firm: bool | None = None
    #: Whether this child may search their own approved videos. Never YouTube.
    search_enabled: bool | None = None


def _watch_state(hid: str, kid: Kid, extra_seconds: int = 0) -> WatchState:
    store = get_store()
    return breaks.build_state(
        kid, store.list_sessions(hid, kid.id), store.list_breaks(hid, kid.id), extra_seconds=extra_seconds
    )


def _blocked(state: WatchState) -> HTTPException:
    """409 with the whole `WatchState`, so one shape answers both "a break is
    running" and "the day is spent" (PROTOCOL.md)."""
    return HTTPException(409, detail={"error": state.blocked_reason, "state": state.model_dump()})


def _active_break(hid: str, kid: Kid) -> BreakPeriod | None:
    return breaks.active_break(get_store().list_breaks(hid, kid.id))


@app.patch("/kids/{kid_id}/limits")
def set_limits(kid_id: str, body: LimitsIn, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, kid_id)
    updates = {k: v for k, v in body.model_dump().items() if v is not None}
    kid = kid.model_copy(update=updates)
    get_store().put_kid(kid)
    log.info("limits for kid %s: %s", kid_id, updates or "unchanged")
    return kid.model_dump()


class SpeechIn(BaseModel):
    """One line for Gilli to say, from a screen the client draws itself."""

    #: Capped because this mints Polly requests. Every real caller is one or two
    #: short sentences; anything longer is a bug or an abuse, not a buddy line.
    text: str = Field(max_length=300)
    language: str = "en"
    slow: bool = False


@app.post("/tts")
def speech(body: SpeechIn, hid: str = Depends(household)) -> dict:
    """A line the client wrote -> `{url}` for the same cached mp3 the session
    uses, or `{"url": ""}` when Polly cannot serve it.

    Session lines already arrive with a `tts_url`, but several screens are
    composed on the device — the end of the day, an empty shelf, the break
    lines a parent typed — and those were falling through to on-device TTS.
    On a phone that is passable; in a browser it is the OS robot voice, and it
    is the first thing anyone says about the app. Same voice everywhere now.

    An empty url is not an error: the client speaks it itself, exactly as it
    did before, so no screen goes silent because Polly is down.
    """
    return {"url": synthesize(body.text, body.language, body.slow)}


@app.get("/kids/{kid_id}/state")
def watch_state(kid_id: str, hid: str = Depends(household)) -> dict:
    """What the client checks before offering anything to watch."""
    return _watch_state(hid, _kid(hid, kid_id)).model_dump()


@app.post("/kids/{kid_id}/break/ack")
def break_ack(kid_id: str, hid: str = Depends(household)) -> dict:
    """The child says they are done.

    Whether that ends the break is the parent's call, not ours: with
    `break_is_firm` the timer still decides and this only records the tap, so
    the button must not pretend otherwise in the UI.
    """
    kid = _kid(hid, kid_id)
    running = _active_break(hid, kid)
    if running is None:
        raise HTTPException(404, "no break is running")
    running.acked = True
    if not kid.break_is_firm:
        running = breaks.end_break_now(running)
        log.info("kid %s ended a soft break early", kid_id)
    get_store().put_break(hid, running)
    return running.at().model_dump()


class MessagesIn(BaseModel):
    messages: list[BreakMessage] = Field(default_factory=list)


@app.put("/kids/{kid_id}/break-messages")
def set_break_messages(kid_id: str, body: MessagesIn, hid: str = Depends(household)) -> dict:
    """Replace what Gilli says during a break. Parent-authored, and the only
    source of those words: nothing a model wrote reaches a child unsaved."""
    # A blank id is a new line the parent just typed, so it gets one here.
    # Identity is the server's to hand out: without it an edit would look
    # like a delete plus an insert, and the rotation would restart every save.
    saved = [m if m.id.strip() else m.model_copy(update={"id": new_id("msg")}) for m in body.messages]
    kid = _kid(hid, kid_id).model_copy(update={"break_messages": saved})
    get_store().put_kid(kid)
    log.info("kid %s now has %d break message(s)", kid_id, len(body.messages))
    return kid.model_dump()


@app.post("/kids/{kid_id}/break-messages/suggest")
def suggest_break_messages(kid_id: str, hid: str = Depends(household)) -> dict:
    """Lines for the PARENT to edit, keep or discard. Never shown to a child."""
    kid = _kid(hid, kid_id)
    store = get_store()
    today = datetime.now(UTC).date().isoformat()
    titles = _video_titles(store, [s.video_id for s in store.list_sessions(hid, kid.id, today)])
    if not titles:
        titles = [v.title for v in (store.get_video(s.video_id) for s in store.list_sessions(hid, kid.id))
                  if v and v.title][:6]
    suggestions, rejected = coach.suggest_messages(kid, titles)
    return {
        "suggestions": [m.model_dump() for m in suggestions],
        "rejected": rejected,
        "based_on": titles[:6],
    }


class OverrideIn(BaseModel):
    pin_ok: bool = False


@app.post("/kids/{kid_id}/break/override")
def break_override(kid_id: str, body: OverrideIn, hid: str = Depends(household)) -> dict:
    """A parent ends a break early, behind the PIN the client already gates on."""
    kid = _kid(hid, kid_id)
    if not body.pin_ok:
        raise HTTPException(403, "parent PIN required")
    running = _active_break(hid, kid)
    if running is None:
        return {"cleared": False}  # nothing was running; the parent got what they wanted
    get_store().put_break(hid, breaks.end_break_now(running))
    log.info("parent ended break %s for kid %s early", running.id, kid_id)
    return {"cleared": True}


# --- channels and home ----------------------------------------------------------------------------------


class ChannelIn(BaseModel):
    url: str


def _approve_channel(hid: str, kid_id: str, info: dict) -> Channel:
    """The one place a channel becomes approved for a kid, so a channel imported
    from the parent's subscriptions behaves exactly like a pasted one."""
    ch = Channel(
        id=info["channel_id"], title=info.get("title") or info["channel_id"],
        thumb_url=info.get("thumb_url", ""), approved=True,
    )
    get_store().put_channel(hid, kid_id, ch)
    return ch


@app.post("/kids/{kid_id}/channels")
def add_channel(
    kid_id: str, body: ChannelIn, tasks: BackgroundTasks, hid: str = Depends(household)
) -> dict:
    """Approve one pasted channel for one kid, and screen its uploads.

    The screening is the point: without it a parent pastes a channel, is told
    it was added, and the child's home stays empty for ever. The bulk import
    next door has always curated; a channel added one at a time did not.
    """
    kid = _kid(hid, kid_id)
    try:
        info = resolve_channel_url(body.url)
    except Exception as e:
        raise HTTPException(400, f"could not resolve channel: {e}") from e
    channel = _approve_channel(hid, kid_id, info)
    tasks.add_task(_curate_in_background, kid)
    return channel.model_dump()


@app.post("/kids/{kid_id}/curate")
def curate_now(kid_id: str, tasks: BackgroundTasks, hid: str = Depends(household)) -> dict:
    """Screen this kid's approved channels again, in the background.

    Curation used to happen only when channels were imported, so a run that
    found nothing — the machine could not read a transcript, the model was
    briefly down — left the household with an empty home and no way at all to
    ask again. This is that way.
    """
    kid = _kid(hid, kid_id)
    tasks.add_task(_curate_in_background, kid)
    return {"started": True}


class ImportChannelsIn(BaseModel):
    channel_ids: list[str] = Field(default_factory=list)
    profile: str = Field(
        default="",
        description="The Takeout profile these channels came from. Present only when the parent "
                    "opted history in for that import; it is what says this profile is this kid.",
    )


_curating: set[str] = set()  # kid ids with a Curator run in flight


def _curate_in_background(kid: Kid) -> None:
    """Fill the kid's home after an import without holding up the response.

    The Curator screens the new channels' recent uploads exactly as it does on a
    scheduled run: an import approves *channels*, never videos.
    """
    if kid.id in _curating:
        return
    _curating.add(kid.id)
    try:
        run_curator(kid, get_store())
    except Exception as e:  # noqa: BLE001 - background job; the import itself already succeeded
        log.warning("background curation failed for kid %s: %s", kid.id, e)
    finally:
        _curating.discard(kid.id)


def _channel_info(channel_id: str) -> dict:
    """Title and thumbnail for one channel id, resolved like a pasted URL.

    It used to prefer a cached copy of the parent's own subscription list.
    That list is no longer read — HeyGilli does not ask for access to a
    parent's YouTube account — so every channel is resolved the same way,
    whichever door it came in through. An unresolvable one is still imported
    under its id rather than failing the whole batch.
    """
    try:
        return resolve_channel_url(channel_id)
    except Exception as e:  # noqa: BLE001 - one odd channel must not sink the batch
        log.warning("could not resolve imported channel %s: %s", channel_id, e)
        return {"channel_id": channel_id, "title": channel_id, "thumb_url": ""}


@app.post("/kids/{kid_id}/channels/import")
def import_channels(
    kid_id: str, body: ImportChannelsIn, tasks: BackgroundTasks, hid: str = Depends(household)
) -> dict:
    """Approve several subscribed channels for one kid in a single call.

    Returns the channels it added and the ids that were already approved.
    Importing does not auto-approve any video: the Curator still screens each
    upload (PROTOCOL.md), which is kicked off in the background so the response
    does not wait on it.

    `profile` names the Takeout profile these channels came from. It is the
    parent saying "this profile is this child", which is the only moment the
    server can attach a watch-history aggregate to a kid, since Takeout carries
    no age and no identity of its own.
    """
    kid = _kid(hid, kid_id)
    store = get_store()
    have = {c.id for c in store.list_channels(hid, kid_id) if c.approved}
    added: list[dict] = []
    already: list[str] = []
    for channel_id in dict.fromkeys(c.strip() for c in body.channel_ids if c.strip()):
        if channel_id in have:
            already.append(channel_id)
            continue
        added.append(_approve_channel(hid, kid_id, _channel_info(channel_id)).model_dump())
        have.add(channel_id)

    if added:
        tasks.add_task(_curate_in_background, kid)
    if body.profile.strip():
        _attach_history(hid, kid, body.profile.strip(), tasks)
    return {"added": added, "already": already}


@app.get("/kids/{kid_id}/channels")
def list_channels(kid_id: str, hid: str = Depends(household)) -> list[dict]:
    _kid(hid, kid_id)
    return [c.model_dump() for c in get_store().list_channels(hid, kid_id)]


@app.delete("/kids/{kid_id}/channels/{channel_id}")
def remove_channel(kid_id: str, channel_id: str, hid: str = Depends(household)) -> dict:
    """Take a channel away from ONE kid.

    A sibling who has the same channel keeps it, and the global review cache is
    untouched — a review is a property of the channel, not of a child, and the
    parent may well want to see it again. Removing something that is not there
    is not an error: the parent asked for it gone and it is gone.
    """
    _kid(hid, kid_id)
    get_store().delete_channel(hid, kid_id, channel_id)
    return {"removed": True}


# --- Takeout import (PROTOCOL.md "Takeout import: the children's own profiles") -------------------


async def _read_capped(file: UploadFile, limit: int) -> bytes:
    """Read the upload, refusing anything past `limit` instead of buffering it all."""
    chunks: list[bytes] = []
    total = 0
    while chunk := await file.read(1024 * 1024):
        total += len(chunk)
        if total > limit:
            raise HTTPException(
                413, f"the file is larger than {limit // (1024 * 1024)} MB. In Takeout, export "
                     "only 'YouTube and YouTube Music'."
            )
        chunks.append(chunk)
    return b"".join(chunks)


@app.post("/import/takeout")
async def import_takeout(
    file: Annotated[UploadFile, File()],
    include_history: Annotated[bool, Form()] = False,
    hid: str = Depends(household),
) -> dict:
    """A Takeout zip in, a `TakeoutPreview` out. No video title is persisted.

    This is the only route to a YouTube Kids profile's subscriptions; no API
    exposes them. By default only the subscription CSVs are read — watch and
    search history are never opened, stored or sent to a model (SPEC §12). The
    parent maps each profile to a kid afterwards, through the existing per-kid
    import, and that is what writes.

    `include_history=true` is the parent opting in for this one import
    (PROTOCOL.md "Watch history"). Even then, search history is never opened,
    and the watch history is reduced to counts here and dropped: what is kept is
    one aggregate per profile, waiting for the parent to say which kid it
    belongs to. Nothing about the zip survives this request otherwise.
    """
    data = await _read_capped(file, MAX_ZIP_BYTES)
    try:
        if include_history:
            preview, histories = await asyncio.to_thread(parse_takeout_zip_with_history, data)
        else:
            preview, histories = await asyncio.to_thread(parse_takeout_zip, data), {}
    except TakeoutError as e:
        raise HTTPException(400, str(e)) from e

    store = get_store()
    for profile, aggregate in histories.items():
        store.put_pending_history(hid, profile, aggregate)
    log.info(
        "takeout preview for household %s: %d profiles, %d parent channels, history for %d",
        hid, len(preview.profiles), preview.parent.channel_count if preview.parent else 0,
        len(histories),
    )
    return preview.model_dump()


# --- watch history (PROTOCOL.md "Watch history: opt-in, aggregate, discarded") --------------------


def _summarise_history(hid: str, kid: Kid) -> None:
    """Upgrade a kid's history summary from the numbers-only one to the model's.

    Runs after the response, because the counts are the substance and they are
    already saved: a parent who opens the screen before this finishes reads the
    plain summary, which is true, rather than a spinner.
    """
    store = get_store()
    insight = store.get_history(hid, kid.id)
    if insight is None:
        return
    insight.summary = history.write_summary(insight, kid)
    store.put_history(hid, insight)


def _attach_history(hid: str, kid: Kid, profile: str, tasks: BackgroundTasks) -> bool:
    """Turn the profile's pending aggregate into this kid's `HistoryInsight`.

    Done here, after the channels are approved, because `subscribed` and
    `unsubscribed_share` only mean anything once we know what this child follows.
    """
    store = get_store()
    aggregate = store.get_pending_history(hid, profile)
    if aggregate is None:
        return False
    subscribed = {c.id for c in store.list_channels(hid, kid.id) if c.approved}
    store.put_history(hid, history.build_insight(kid.id, aggregate, subscribed))
    store.delete_pending_history(hid, profile)
    tasks.add_task(_summarise_history, hid, kid)
    log.info("watch history attached to kid %s from profile %r", kid.id, profile)
    return True


@app.get("/kids/{kid_id}/history")
def get_history(kid_id: str, hid: str = Depends(household)) -> dict:
    """404 when this household never opted in, which is the normal case."""
    kid = _kid(hid, kid_id)
    insight = get_store().get_history(hid, kid.id)
    if insight is None:
        raise HTTPException(404, "no watch history has been imported for this kid")
    return insight.model_dump()


@app.delete("/kids/{kid_id}/history")
def delete_history(kid_id: str, hid: str = Depends(household)) -> dict:
    """One call, and it is gone. `false` means there was nothing to delete."""
    kid = _kid(hid, kid_id)
    store = get_store()
    existed = store.get_history(hid, kid.id) is not None
    store.delete_history(hid, kid.id)
    log.info("watch history for kid %s deleted (existed: %s)", kid.id, existed)
    return {"deleted": existed}


# --- channel reviews (PROTOCOL.md "Channel reviews") ----------------------------------------------

REVIEW_CONCURRENCY = 4  # 153 channels must not stampede Bedrock or block the loop
_reviewing: set[str] = set()  # channel ids with a review in flight


def _channel_hints(hid: str) -> dict[str, dict]:
    """Title and avatar per channel id, from what this household already has:
    the kids' approved channels. Saves the Reviewer a page fetch, and is the
    only source of an avatar (RSS has none)."""
    store = get_store()
    hints: dict[str, dict] = {}
    for kid in store.list_kids(hid):
        for ch in store.list_channels(hid, kid.id):
            hints.setdefault(ch.id, {"title": ch.title, "thumb_url": ch.thumb_url})
    return hints


def _review_one(channel_id: str, hint: dict) -> ChannelReview:
    return review_channel(
        channel_id, get_store(),
        title_hint=hint.get("title", ""), thumb_url=hint.get("thumb_url", ""),
    )


async def _review_in_background(channel_ids: list[str], hints: dict[str, dict]) -> None:
    """Review the pending channels a few at a time; the client polls for them.

    Each review is a blocking model call, so it runs in a worker thread and the
    semaphore bounds how many are in flight at once.
    """
    gate = asyncio.Semaphore(REVIEW_CONCURRENCY)

    async def one(channel_id: str) -> None:
        async with gate:
            try:
                await asyncio.to_thread(_review_one, channel_id, hints.get(channel_id, {}))
            except Exception as e:  # noqa: BLE001 - one bad channel must not stop the batch
                log.warning("background review failed for %s: %s", channel_id, e)
            finally:
                _reviewing.discard(channel_id)

    try:
        await asyncio.gather(*(one(c) for c in channel_ids))
    finally:
        # A cancelled batch must not leave ids marked in-flight forever: they would
        # sit in `pending` on every later poll with nothing working on them.
        for channel_id in channel_ids:
            _reviewing.discard(channel_id)


class ChannelReviewsIn(BaseModel):
    channel_ids: list[str] = Field(default_factory=list)


@app.post("/channels/reviews")
def channel_reviews(
    body: ChannelReviewsIn, tasks: BackgroundTasks, hid: str = Depends(household)
) -> dict:
    """Cached reviews now, the rest in `pending` with the work started.

    The client polls this same endpoint until `pending` is empty. Ids already
    being reviewed by an earlier poll stay in `pending` without starting a
    second run.
    """
    store = get_store()
    hints = _channel_hints(hid)
    reviews: list[dict] = []
    pending: list[str] = []
    to_start: list[str] = []

    for channel_id in dict.fromkeys(c.strip() for c in body.channel_ids if c.strip()):
        cached = store.get_channel_review(channel_id)
        if cached:
            reviews.append(ChannelReview.model_validate(cached).model_dump())
            continue
        pending.append(channel_id)
        if channel_id not in _reviewing:
            _reviewing.add(channel_id)
            to_start.append(channel_id)

    if to_start:
        tasks.add_task(_review_in_background, to_start, hints)
    return {"reviews": reviews, "pending": pending}


@app.get("/channels/{channel_id}/review")
def channel_review(channel_id: str, refresh: bool = False, hid: str = Depends(household)) -> dict:
    """One review, waiting for it if it is not cached. `refresh=true` re-reviews."""
    hint = _channel_hints(hid).get(channel_id, {})
    try:
        review = review_channel(
            channel_id, get_store(),
            title_hint=hint.get("title", ""), thumb_url=hint.get("thumb_url", ""), refresh=refresh,
        )
    except Exception as e:  # never a 500 on a parent-facing screen
        log.warning("review failed for %s: %s", channel_id, e)
        raise HTTPException(502, f"could not review this channel: {type(e).__name__}") from e
    return review.model_dump()


# --- channel drift (PROTOCOL.md "Channel drift: a channel is not what it was") --------------------

MAX_RECHECKS_PER_CALL = 10  # a re-review is a feed fetch and a model call each


def _kids_with_channel(hid: str, channel_id: str) -> list[str]:
    store = get_store()
    return [
        kid.id for kid in store.list_kids(hid)
        if any(c.id == channel_id and c.approved for c in store.list_channels(hid, kid.id))
    ]


def _raise_drift_prompts(hid: str, d: ChannelDrift) -> int:
    """One inbox entry per kid who actually has this channel.

    Nothing is removed here and nothing can be: the entry says what changed and
    the parent decides (PROTOCOL.md). A channel with an entry still open does
    not get a second one, because a weekly re-check must not stack up cards
    about the same change.
    """
    store = get_store()
    raised = 0
    for kid_id in _kids_with_channel(hid, d.channel_id):
        open_already = any(
            p.kind == "channel_drift" and p.drift and p.drift.channel_id == d.channel_id
            and p.kid_id == kid_id
            for p in store.list_parent_prompts(hid)
        )
        if open_already:
            continue
        store.put_parent_prompt(ParentPrompt(
            household_id=hid, kid_id=kid_id, kind="channel_drift", drift=d,
            reason=f"{d.title or d.channel_id} has changed. {d.what_changed}",
        ))
        raised += 1
    return raised


def _recheck(hid: str, channel_id: str, was: ChannelReview) -> ChannelDrift | None:
    """Re-read one channel and compare. Blocking: a feed fetch and a model call."""
    store = get_store()
    drift.mark_checked(channel_id, store)  # the limit holds whatever comes of this
    hint = _channel_hints(hid).get(channel_id, {})
    now = review_channel(
        channel_id, store, title_hint=hint.get("title", "") or was.title,
        thumb_url=hint.get("thumb_url", "") or was.thumb_url, refresh=True,
    )
    if now.verdict == "unknown" and was.verdict != "unknown":
        # The channel could not be read today. That is a gap in what we know,
        # not a change in what it publishes, so the parent keeps the review they
        # had rather than watching a good channel decay into "unknown".
        store.put_channel_review(channel_id, was.model_dump())
        log.info("drift check for %s came back unknown; the earlier review stands", channel_id)
        return None
    d = drift.compare(was, now)
    if not d.worse:
        return d
    d.what_changed = drift.write_note(d)
    return d


@app.post("/channels/drift/check")
def channels_drift_check(body: ChannelReviewsIn, hid: str = Depends(household)) -> dict:
    """Re-review channels that are due, and report the ones that got worse.

    `checked` is how many were actually re-read rather than answered from cache:
    a channel reviewed in the last week is not re-read at all. Only `worse`
    drifts come back — a channel that improved is not something anyone needs to
    be interrupted about — and each one raises an entry in the parent's inbox.
    """
    store = get_store()
    drifted: list[dict] = []
    checked = 0

    for channel_id in dict.fromkeys(c.strip() for c in body.channel_ids if c.strip()):
        cached = store.get_channel_review(channel_id)
        was = ChannelReview.model_validate(cached) if cached else None
        if was is None or not drift.due_for_recheck(was, store):
            continue  # never reviewed, or read recently enough already
        if checked >= MAX_RECHECKS_PER_CALL:
            break  # the rest stay due; the client can ask again
        checked += 1
        try:
            d = _recheck(hid, channel_id, was)
        except Exception as e:  # noqa: BLE001 - one bad channel must not sink the batch
            log.warning("drift check failed for %s: %s", channel_id, e)
            continue
        if d is None or not d.worse:
            continue
        drifted.append(d.model_dump())
        _raise_drift_prompts(hid, d)

    return {"drifted": drifted, "checked": checked}


@app.get("/kids/{kid_id}/home")
def home(kid_id: str, q: str = "", hid: str = Depends(household)) -> dict:
    """The rows, plus whether watching is allowed at all right now.

    A video longer than `max_video_minutes` is not offered: the limit is about
    what a child is handed, so it is applied where the choosing happens rather
    than as a refusal after they have picked something.

    `q` is the child's search, and it never leaves this list: it filters the
    videos already approved for them. Searching YouTube would hand back the
    open internet and undo the allowlist the whole product is built on, so
    there is no code path here that could. It is only honoured when the parent
    turned `search_enabled` on for this child.
    """
    kid = _kid(hid, kid_id)
    store = get_store()
    cap_s = kid.max_video_minutes * 60
    unknown_length = 0
    approved: list[Video] = []
    for vid, entry in store.list_kid_videos(hid, kid_id).items():
        if entry.get("status") != "approve":
            continue
        v = store.get_video(vid)
        if v is None:
            continue
        # The safety rules as they are now, not as they were the day this was
        # screened. Screening happens once per video, so a rule added later
        # never reached anything already approved — a live football match
        # stayed on an eight-year-old's shelf because it was let through
        # before live streams were understood.
        #
        # Only the `hide` rules, and deliberately not `ask_parent`: those are
        # the judgement calls, and this video being here means the parent
        # already made one. Re-applying them would quietly overrule a person
        # who said yes. A `hide` was never theirs to make.
        if prescreen(v).verdict == "hide":
            continue
        # A length of 0 means "we could not find out", never "instant".
        #
        # Both readings of that have been wrong. Comparing it as a number let
        # every unmeasured video through a limit it had never been measured
        # against — twenty minutes set, thirty offered. Withholding it instead
        # emptied the shelf completely, because the only source of a length is
        # the parent's own Google grant and a household without one can never
        # learn a single one: the child was left with nothing at all, which is
        # a worse answer to "this video might be long" than showing it.
        #
        # So it is offered, and `unknown_length` says how many were offered
        # that way. The limit is a real setting where lengths are known and an
        # unkeepable promise where they are not, and the parent is told which
        # they have rather than left to find out from an empty screen.
        if cap_s and v.duration_s and v.duration_s > cap_s:
            continue
        if cap_s and not v.duration_s:
            unknown_length += 1
        v.plan_ready = store.get_plan(v.id, kid.age_band or "7_8", kid.languages[0]) is not None
        approved.append(v)
    approved.sort(key=lambda v: v.published_at or "", reverse=True)

    query = q.strip().lower() if (q and kid.search_enabled) else ""
    if query:
        hits = [v for v in approved if query in f"{v.title} {v.description}".lower()]
        rows = [{"title": f"Found {len(hits)}", "videos": [v.public() for v in hits[:24]]}]
    else:
        rows = [{"title": "New for you", "videos": [v.public() for v in approved[:12]]}]
        if len(approved) > 12:
            rows.append({"title": "More to watch", "videos": [v.public() for v in approved[12:]]})

    state = _watch_state(hid, kid)
    return {
        "rows": rows,
        #: How many of these are offered without a known length, while a length
        #: limit is set. Zero when no limit is set: nothing is being let past.
        "unknown_length": unknown_length,
        "searchable": kid.search_enabled,
        "watching_allowed": state.watching_allowed,
        "blocked_reason": state.blocked_reason,
        "active_break": state.active_break.model_dump() if state.active_break else None,
    }


# --- sessions ---------------------------------------------------------------------------------------------------


class SessionIn(BaseModel):
    kid_id: str
    video_id: str
    device: str = "tv"


_planning: set[str] = set()  # (video, band, language) keys with a Planner call in flight


def _plan_in_background(video: Video, band: str, language: str) -> None:
    key = f"{video.id}#{band}#{language}"
    if key in _planning:
        return  # a second POST /sessions for the same video must not start a second Planner call
    _planning.add(key)
    try:
        ensure_plan(video, band, language)
    except Exception as e:  # noqa: BLE001 - background job; the session falls back to a generic plan
        log.warning("background planning failed for %s: %s", video.id, e)
    finally:
        _planning.discard(key)


@app.post("/sessions")
def create_session(body: SessionIn, tasks: BackgroundTasks, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, body.kid_id)
    state = _watch_state(hid, kid)
    if not state.watching_allowed:  # a break is running, or the day is spent
        raise _blocked(state)
    store = get_store()
    video = store.get_video(body.video_id)
    if not video:
        meta = fetch_video_meta(body.video_id)
        video = Video(**{k: meta[k] for k in ("id", "title", "thumb_url", "channel_id", "duration_s")})
        store.put_video(video)
    band = kid.age_band or "7_8"
    language = kid.languages[0]
    plan = store.get_plan(video.id, band, language)
    if plan is None:
        tasks.add_task(_plan_in_background, video, band, language)
    session = Session(household_id=hid, kid_id=kid.id, device=body.device, video_id=video.id,
                      age_band=band, language=language)
    store.put_session(session)
    video.plan_ready = plan is not None
    return {"session_id": session.id, "video": video.public(), "plan_ready": plan is not None}


@app.post("/sessions/{session_id}/end")
def end_session(session_id: str, hid: str = Depends(household)) -> dict:
    store = get_store()
    s = store.get_session(hid, session_id)
    if not s:
        raise HTTPException(404, "session not found")
    s.ended_at = datetime.now(UTC).isoformat(timespec="seconds")
    store.put_session(s)
    return {"ok": True}


# --- digest, curator, parent inbox ---------------------------------------------------------------------------------


@app.get("/kids/{kid_id}/digest")
def get_digest(kid_id: str, date: str | None = None, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, kid_id)
    date = date or datetime.now(UTC).date().isoformat()
    d = get_store().get_digest(hid, kid_id, date)
    if d is None:
        d = run_digest(kid, date, get_store())
    return d.model_dump()


@app.post("/kids/{kid_id}/digest/run")
def run_digest_now(kid_id: str, date: str | None = None, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, kid_id)
    date = date or datetime.now(UTC).date().isoformat()
    return run_digest(kid, date, get_store()).model_dump()


@app.get("/kids/{kid_id}/analytics")
def kid_analytics(
    kid_id: str,
    days: int = DEFAULT_DAYS,
    refresh: bool = False,
    hid: str = Depends(household),
) -> dict:
    """PROTOCOL.md "Analytics". `days` is clamped to 7-90; a kid with no history gets
    zeros, empty lists and a `quiet` note rather than an error."""
    kid = _kid(hid, kid_id)
    return run_analytics(kid, days, get_store(), refresh=refresh).model_dump()


@app.get("/kids/{kid_id}/revisits")
def kid_revisits(kid_id: str, hid: str = Depends(household)) -> dict:
    """The concepts still worth another look, and how often one already was.

    Parent-facing. A concept the child has since got right twice, or that has
    already been asked again twice, is not here: nothing is ever asked a third
    time (PROTOCOL.md).
    """
    kid = _kid(hid, kid_id)
    return {"concepts": [c.model_dump() for c in revisit.candidates(kid, get_store())]}


@app.get("/kids/{kid_id}/words")
def kid_words(kid_id: str, hid: str = Depends(household)) -> dict:
    """Every second-language word this child has met, most recent first.

    The same data the analytics screen shows as vocabulary: a word with
    `times_said == 0` is exactly what that screen calls `emerging`.
    """
    kid = _kid(hid, kid_id)
    return {"words": [w.model_dump() for w in get_store().list_word_seeds(hid, kid.id)]}


class CuratorIn(BaseModel):
    kid_id: str


@app.post("/curator/run")
def curator_run(body: CuratorIn, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, body.kid_id)
    return run_curator(kid, get_store()).model_dump()


@app.get("/parent/inbox")
def parent_inbox(hid: str = Depends(household)) -> list[dict]:
    """What is waiting, each entry naming the channel it came from.

    A parent working through this is not deciding about videos one at a time
    so much as about a channel: five borderline uploads in a row are usually
    five from the same place, and the answer to all five is the same answer.
    The video carries a channel id and nothing a person can read, so the title
    is attached here — the server already knows it and the client would
    otherwise have to fetch every kid's channel list to find out.
    """
    store = get_store()
    titles: dict[str, str] = {}
    for kid in store.list_kids(hid):
        for channel in store.list_channels(hid, kid.id):
            if channel.title:
                titles.setdefault(channel.id, channel.title)

    out: list[dict] = []
    for prompt in store.list_parent_prompts(hid):
        entry = prompt.public()
        channel_id = (entry.get("video") or {}).get("channel_id") or ""
        # Falls back to the id rather than to nothing: an unnamed group is
        # still a group, and a channel added by id has no title yet.
        entry["channel_title"] = titles.get(channel_id, "") or channel_id
        out.append(entry)
    return out


class DecisionIn(BaseModel):
    decision: Literal["approve", "hide"]


@app.post("/parent/inbox/{prompt_id}")
def parent_decide(prompt_id: str, body: DecisionIn, hid: str = Depends(household)) -> dict:
    store = get_store()
    p = store.get_parent_prompt(hid, prompt_id)
    if not p:
        raise HTTPException(404, "prompt not found")
    p.decision = body.decision
    store.put_parent_prompt(p)
    if p.kind == "channel_drift" or p.video is None:
        # A drift is information. Whichever way the parent answers, the channel
        # stays exactly as it is: HeyGilli never removes one, and removal is a
        # DELETE the parent makes themselves (PROTOCOL.md "Channel drift").
        log.info("parent read the drift card %s for kid %s", p.id, p.kid_id)
        return {"ok": True}
    store.set_kid_video(hid, p.kid_id, p.video.id, body.decision, "parent decided")
    if body.decision == "approve":
        video = store.get_video(p.video.id) or p.video
        video.age_ok = True
        store.put_video(video)
        kid = store.get_kid(hid, p.kid_id)
        if kid:
            for language in kid.languages:
                ensure_plan(video, kid.age_band or "7_8", language, store, freq=kid.question_freq)
    return {"ok": True}


# --- WebSocket: the Buddy loop ------------------------------------------------------------------------------------------

_client_msg = TypeAdapter(ClientMessage)



class BreakGuard:
    """Decides, during one session, when a break fires.

    Counting is wall-clock from the moment the socket opens, because that is
    what the child actually sat through; the video's own position can be
    scrubbed. The stored sessions and breaks are read once here and never again,
    so the check on every position tick is pure arithmetic.

    There is no model in this path. What Gilli says during a break is one of the
    parent's own lines, so firing a break is instant and cannot fail: no
    generation, no timeout, no fallback, and no child left watching a frozen
    frame while something thinks.
    """

    def __init__(self, hid: str, kid: Kid, store, session_titles: list[str], today_titles: list[str]) -> None:
        self.hid = hid
        self.kid = kid
        self.store = store
        self.session_titles = session_titles
        self.today_titles = today_titles
        self._sessions = store.list_sessions(hid, kid.id)
        self._breaks = store.list_breaks(hid, kid.id)
        self._started = time.monotonic()

    def state(self) -> WatchState:
        elapsed = int(time.monotonic() - self._started)
        return breaks.build_state(self.kid, self._sessions, self._breaks, extra_seconds=elapsed)

    def verdict(self, natural_moment: bool) -> breaks.Verdict:
        """`"now"` means send the break."""
        return breaks.due(self.kid, self.state(), natural_moment)

    async def fire(self) -> BreakPeriod:
        brk = breaks.start_break(self.kid, breaks.pick_message(self.kid, self._breaks))
        self.store.put_break(self.hid, brk)
        log.info(
            "break for kid %s: %s",
            self.kid.id,
            "quiet" if brk.message is None else repr(brk.message.text),
        )
        return brk.at()


def _video_titles(store, video_ids) -> list[str]:
    titles = []
    for vid in dict.fromkeys(video_ids):
        v = store.get_video(vid)
        if v and v.title:
            titles.append(v.title)
    return titles


def _make_guard(hid: str, kid: Kid | None, session: Session, store) -> BreakGuard | None:
    if kid is None:
        return None
    today = datetime.now(UTC).date().isoformat()
    session_titles = _video_titles(store, [session.video_id])
    earlier = [s.video_id for s in store.list_sessions(hid, kid.id, today) if s.id != session.id]
    return BreakGuard(hid, kid, store, session_titles, _video_titles(store, earlier))


@app.websocket("/sessions/{session_id}/ws")
async def session_ws(ws: WebSocket, session_id: str, token: str | None = None) -> None:
    await ws.accept()
    store = get_store()
    hid = None
    if token:
        with contextlib.suppress(HTTPException):
            hid = verify(token)
    session = None
    if hid:
        session = store.get_session(hid, session_id)
    else:  # no token on the socket: find the session across households (dev convenience)
        for kid_hh in store.list("_index", "households"):
            session = store.get_session(kid_hh["_id"], session_id)
            if session:
                break
        session = session or _find_session(session_id)
    if session is None:
        await ws.send_json(wire(ServerError(message="unknown session")))
        await ws.close()
        return

    kid = store.get_kid(session.household_id, session.kid_id)
    video = store.get_video(session.video_id) or Video(id=session.video_id)
    plan = store.get_plan(video.id, session.age_band, session.language) or fallback_plan(
        video, session.age_band, session.language
    )
    if kid is not None:
        # For this session only: the cached plan is shared by every household and
        # a revisit belongs to one child (PROTOCOL.md "Revisiting a shaky concept").
        plan = await asyncio.to_thread(revisit.seed, plan, kid, store, video, session.id)
        # A second-language word for something this child already has, for a
        # household that asked for one (PROTOCOL.md "Bilingual word seeding").
        plan = await asyncio.to_thread(words.seed, plan, kid, store, session.language)
    engine = SessionEngine(session, plan, kid, store)  # type: ignore[arg-type]
    guard = _make_guard(session.household_id, kid, session, store)

    try:
        first = _client_msg.validate_python(await ws.receive_json())
        if first.t != "hello":
            await ws.send_json(wire(ServerError(message="expected hello")))
        await ws.send_json(wire(engine.ready()))
        await _loop(ws, engine, guard)
    except (WebSocketDisconnect, ValidationError) as e:
        log.info("session %s closed: %s", session_id, type(e).__name__)
    finally:
        session.watched_sec = int(engine.position_s)
        session.ended_at = session.ended_at or datetime.now(UTC).isoformat(timespec="seconds")
        store.put_session(session)


def _find_session(session_id: str) -> Session | None:
    """Scan households for a session id (local store only; small data)."""
    store = get_store()
    from .store import LocalStore

    if not isinstance(store, LocalStore):
        return None
    for hh_dir in store.root.iterdir():
        if hh_dir.is_dir() and not hh_dir.name.startswith("_"):
            s = store.get_session(hh_dir.name, session_id)
            if s:
                return s
    return None


async def _loop(ws: WebSocket, engine: SessionEngine, guard: BreakGuard | None = None) -> None:
    """pause -> ask -> (answer | timeout) -> reply -> resume, until the client says bye.

    A due break interrupts this loop at the next natural moment — a question
    pause or the end of the video — or three minutes later whether or not one
    arrived. The session then ends: nothing plays again until the break's clock
    runs out (PROTOCOL.md).
    """
    while True:
        msg = _client_msg.validate_python(await ws.receive_json())
        if msg.t == "bye":
            if guard is not None and guard.verdict(natural_moment=True) == "now":
                await _send_break(ws, guard)
            await ws.send_json(wire(engine.end()))
            return
        if msg.t != "position":
            continue
        idx = engine.due_question(msg.seconds)
        # A question pause is a natural moment; a plain tick is not, so on a tick
        # only the three-minute hard interrupt fires.
        if guard is not None and guard.verdict(natural_moment=idx is not None) == "now":
            await _send_break(ws, guard)
            await ws.send_json(wire(engine.end()))
            return
        if idx is None:
            continue

        await ws.send_json(wire(ServerPause()))
        ask = await asyncio.to_thread(engine.ask, idx)
        # The tag is bookkeeping for the parent's screen and is deliberately not
        # on `ask`: nothing the child receives says this is a second attempt.
        tag = engine.questions[idx].revisit
        if tag is not None and engine.kid is not None:
            revisit.record_asked(engine.kid, engine.store, tag, engine.session.id)
        await ws.send_json(wire(ask))

        answer = await _await_answer(ws, idx, ask.listen_ms + ANSWER_GRACE_MS)
        if answer is None:  # client went away
            return
        reply = await asyncio.to_thread(engine.answer, answer)
        if engine.kid is not None:
            reply = words.after_answer(reply, engine.questions[idx], engine.kid, engine.store)
        await ws.send_json(wire(reply))
        if engine.band == "4_6" and reply.result in ("silence", "unclear"):
            await asyncio.sleep(PREREADER_ECHO_WAIT_S)
        await ws.send_json(wire(ServerResume()))


async def _send_break(ws: WebSocket, guard: BreakGuard) -> None:
    """`{t: "break", break: BreakPeriod}`. The client stops playback here."""
    brk = await guard.fire()
    await ws.send_json(wire(ServerBreak(brk=brk)))
    log.info("break %s sent to kid %s", brk.id, guard.kid.id)


async def _await_answer(ws: WebSocket, idx: int, timeout_ms: int) -> ClientAnswer | None:
    """Wait for the answer to question `idx`; a timeout becomes input "none"."""
    deadline = asyncio.get_event_loop().time() + timeout_ms / 1000
    while True:
        remaining = deadline - asyncio.get_event_loop().time()
        if remaining <= 0:
            return ClientAnswer(t="answer", q=idx, input="none")
        try:
            raw = await asyncio.wait_for(ws.receive_json(), timeout=remaining)
        except TimeoutError:
            return ClientAnswer(t="answer", q=idx, input="none")
        except WebSocketDisconnect:
            return None
        try:
            msg = _client_msg.validate_python(raw)
        except ValidationError:
            await ws.send_json(wire(ServerError(message="bad message")))
            continue
        if msg.t == "answer" and msg.q == idx:
            return msg
        if msg.t == "bye":
            return None
        # position ticks while paused, "resumed", or a stale answer: ignore and keep listening


@app.get("/debug/transcript")
def debug_transcript(
    video_id: str,
    reset: bool = False,
    model: str = "",
    hid: str = Depends(household),
) -> dict:
    """Run the transcript chain for one video and report what each source said.

    The Curator swallows a failed transcript on purpose — one unreadable video
    must not sink a run — so from outside, "screened on title alone" and
    "screened on the spoken words" look identical, and the only account of why
    is a log line on a host whose logs are not in front of whoever is asking.
    This runs the same chain and hands back the reason.

    Behind household auth: it costs a model call and names which sources this
    deployment has.
    """
    out: dict = {"video_id": video_id}
    if reset:
        # Otherwise the answer to "why did this fail" is "we did not try",
        # which is the standing-down working, not a diagnosis.
        transcript_sources.clear_cooldowns()
    # Free-tier quota is counted per model, so "we are out of quota" is a fact
    # about one model name and not about the key. Trying another one is the
    # only way to find out which, and it is a question worth being able to ask
    # from outside the host.
    was = os.environ.get("HEYGILLI_GEMINI_MODEL")
    if model:
        os.environ["HEYGILLI_GEMINI_MODEL"] = model
        out["model"] = model
    try:
        got = transcript_sources.fetch_transcript(video_id)
        out["source"] = got.get("source")
        segments = got.get("segments") or []
        out["segments"] = len(segments)
        out["first"] = segments[0] if segments else None
    except Exception as e:  # noqa: BLE001 - reporting the failure IS the endpoint
        out["source"] = "none"
        out["error"] = f"{type(e).__name__}: {e}"
    finally:
        if model:
            if was is None:
                os.environ.pop("HEYGILLI_GEMINI_MODEL", None)
            else:
                os.environ["HEYGILLI_GEMINI_MODEL"] = was
    return out


@app.get("/debug/gemini-models")
def debug_gemini_models(hid: str = Depends(household)) -> dict:
    """Model names this key can actually call, and the one we ask for.

    A retired or misspelled model answers 404, which reads exactly like a dead
    key. This says which it is without anyone pasting a key anywhere.
    """
    want = os.getenv("HEYGILLI_GEMINI_MODEL", "gemini-3.5-flash-lite")
    try:
        from google import genai  # type: ignore

        client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
        names = [m.name for m in client.models.list()]
    except Exception as e:  # noqa: BLE001 - reporting the failure IS the endpoint
        return {"want": want, "error": f"{type(e).__name__}: {e}"}
    return {"want": want, "usable": [n for n in names if "flash" in n or "pro" in n]}


@app.get("/healthz")
def healthz() -> dict:
    """Alive, and which transcript sources this deployment actually has.

    The commit and the two booleans are here because a deploy that had not
    landed and a deploy that had landed but could not read a transcript
    produced exactly the same symptom — an empty home and one log line — and
    telling them apart meant guessing. Names only: no key or proxy address is
    ever reported.
    """
    return {
        "ok": True,
        "id": new_id("gw"),
        "commit": os.getenv("RENDER_GIT_COMMIT", "")[:7],
        "transcripts": {
            "gemini": transcript_sources.gemini_available(),
            "proxy": transcript_sources.proxy_configured(),
        },
        # Which key searching would reach for. "google-fallback" means the
        # dedicated variable never arrived and it is about to try the Gemini
        # key, which the YouTube Data API refuses — indistinguishable from a
        # bad key when read from outside.
        "search_key": youtube_search_key_source(),
    }
