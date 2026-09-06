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

import httpx
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

from . import breaks, coach, drift, history
from .analytics import DEFAULT_DAYS, run_analytics
from .buddy import SessionEngine
from .curator import run_curator
from .digest import run_digest
from .google_auth import (
    GoogleAuthError,
    GoogleNeedsRelink,
    GoogleNotConfigured,
    GoogleNotLinked,
    google_access_token,
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
    Subscription,
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
from .tools.tts import TTS_DIR
from .tools.youtube import fetch_video_meta, list_subscriptions, resolve_channel_url

load_dotenv()
log = logging.getLogger("heygilli.gateway")
logging.basicConfig(level=os.getenv("HEYGILLI_LOG", "INFO"))

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
    """Server auth code from the Android client -> a household token.

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
        hid, link = link_household(body.server_auth_code, get_store(), started_in)
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


@app.get("/me/youtube/subscriptions")
def me_youtube_subscriptions(hid: str = Depends(household)) -> dict:
    """The parent's own YouTube subscriptions, each marked with the kids that
    already have it.

    `linked: false` with an empty list is a normal state, not an error: the
    household has no Google link yet, or the grant was just revoked. These are
    the *parent's* subscriptions — a list to tick through, never an approved
    catalogue (PROTOCOL.md).
    """
    store = get_store()
    try:
        access_token = google_access_token(hid, store)
    except (GoogleNotLinked, GoogleNeedsRelink):
        return {"linked": False, "subscriptions": []}  # a revoked link was just cleared
    except GoogleAuthError as e:
        raise _google_http(e) from e

    try:
        subs = list_subscriptions(access_token)
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 401:  # the grant died between refresh and call
            store.clear_google_link(hid)
            log.info("youtube rejected the access token for household %s; link cleared", hid)
            return {"linked": False, "subscriptions": []}
        raise HTTPException(502, f"YouTube Data API returned {e.response.status_code}") from e
    except httpx.HTTPError as e:
        raise HTTPException(502, f"could not reach the YouTube Data API: {type(e).__name__}") from e

    # Cache titles and thumbnails so an import needs no second API call.
    store.cache_put("youtube_subs", hid, {"items": subs})
    approved = _approved_by_channel(hid)
    return {
        "linked": True,
        "subscriptions": [
            Subscription(**s, approved_for=approved.get(s["channel_id"], [])).model_dump() for s in subs
        ],
    }


# --- kids -----------------------------------------------------------------------------------------------


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
    return {"questions": [q.model_dump() for q in questions]}


# --- time limits and movement breaks (PROTOCOL.md) -----------------------------------------------


class LimitsIn(BaseModel):
    """Every field optional: a parent changing one limit does not reset the rest."""

    daily_minutes: int | None = Field(default=None, ge=0)
    break_after_minutes: int | None = Field(default=None, ge=0)
    break_minutes: int | None = Field(default=None, ge=1)
    max_video_minutes: int | None = Field(default=None, ge=0)
    break_is_firm: bool | None = None


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
def add_channel(kid_id: str, body: ChannelIn, hid: str = Depends(household)) -> dict:
    _kid(hid, kid_id)
    try:
        info = resolve_channel_url(body.url)
    except Exception as e:
        raise HTTPException(400, f"could not resolve channel: {e}") from e
    return _approve_channel(hid, kid_id, info).model_dump()


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


def _channel_info(channel_id: str, known: dict[str, dict]) -> dict:
    """Title and thumbnail for one channel id: from the cached subscription list
    when possible, else resolved like a pasted URL. An unresolvable channel is
    still imported under its id rather than failing the whole import."""
    if channel_id in known:
        return known[channel_id]
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
    cached = store.cache_get("youtube_subs", hid) or {}
    known = {s["channel_id"]: s for s in cached.get("items", [])}

    added: list[dict] = []
    already: list[str] = []
    for channel_id in dict.fromkeys(c.strip() for c in body.channel_ids if c.strip()):
        if channel_id in have:
            already.append(channel_id)
            continue
        added.append(_approve_channel(hid, kid_id, _channel_info(channel_id, known)).model_dump())
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
    the kids' approved channels and the cached subscription list. Saves the
    Reviewer a page fetch, and is the only source of an avatar (RSS has none)."""
    store = get_store()
    hints: dict[str, dict] = {}
    for s in (store.cache_get("youtube_subs", hid) or {}).get("items", []):
        hints[s["channel_id"]] = {"title": s.get("title", ""), "thumb_url": s.get("thumb_url", "")}
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
def home(kid_id: str, hid: str = Depends(household)) -> dict:
    """The rows, plus whether watching is allowed at all right now.

    A video longer than `max_video_minutes` is not offered: the limit is about
    what a child is handed, so it is applied where the choosing happens rather
    than as a refusal after they have picked something.
    """
    kid = _kid(hid, kid_id)
    store = get_store()
    cap_s = kid.max_video_minutes * 60
    approved: list[Video] = []
    for vid, entry in store.list_kid_videos(hid, kid_id).items():
        if entry.get("status") != "approve":
            continue
        v = store.get_video(vid)
        if v is None or (cap_s and v.duration_s > cap_s):
            continue
        v.plan_ready = store.get_plan(v.id, kid.age_band or "7_8", kid.languages[0]) is not None
        approved.append(v)
    approved.sort(key=lambda v: v.published_at or "", reverse=True)
    rows = [{"title": "New for you", "videos": [v.public() for v in approved[:12]]}]
    if len(approved) > 12:
        rows.append({"title": "More to watch", "videos": [v.public() for v in approved[12:]]})

    state = _watch_state(hid, kid)
    return {
        "rows": rows,
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


class CuratorIn(BaseModel):
    kid_id: str


@app.post("/curator/run")
def curator_run(body: CuratorIn, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, body.kid_id)
    return run_curator(kid, get_store()).model_dump()


@app.get("/parent/inbox")
def parent_inbox(hid: str = Depends(household)) -> list[dict]:
    return [p.public() for p in get_store().list_parent_prompts(hid)]


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
        await ws.send_json(wire(ask))

        answer = await _await_answer(ws, idx, ask.listen_ms + ANSWER_GRACE_MS)
        if answer is None:  # client went away
            return
        reply = await asyncio.to_thread(engine.answer, answer)
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


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True, "id": new_id("gw")}
