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
from datetime import UTC, datetime
from typing import Literal

import httpx
from dotenv import load_dotenv
from fastapi import (
    BackgroundTasks,
    Depends,
    FastAPI,
    Header,
    HTTPException,
    WebSocket,
    WebSocketDisconnect,
)
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

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
from .schemas import (
    AuthSession,
    Channel,
    ClientAnswer,
    ClientMessage,
    Kid,
    Language,
    ServerError,
    ServerPause,
    ServerResume,
    Session,
    Subscription,
    Video,
    new_id,
    wire,
)
from .store import get_store
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
    return {"added": added, "already": already}


@app.get("/kids/{kid_id}/channels")
def list_channels(kid_id: str, hid: str = Depends(household)) -> list[dict]:
    _kid(hid, kid_id)
    return [c.model_dump() for c in get_store().list_channels(hid, kid_id)]


@app.get("/kids/{kid_id}/home")
def home(kid_id: str, hid: str = Depends(household)) -> dict:
    kid = _kid(hid, kid_id)
    store = get_store()
    approved: list[Video] = []
    for vid, entry in store.list_kid_videos(hid, kid_id).items():
        if entry.get("status") != "approve":
            continue
        v = store.get_video(vid)
        if v:
            v.plan_ready = store.get_plan(v.id, kid.age_band or "7_8", kid.languages[0]) is not None
            approved.append(v)
    approved.sort(key=lambda v: v.published_at or "", reverse=True)
    rows = [{"title": "New for you", "videos": [v.public() for v in approved[:12]]}]
    if len(approved) > 12:
        rows.append({"title": "More to watch", "videos": [v.public() for v in approved[12:]]})
    return {"rows": rows}


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

    try:
        first = _client_msg.validate_python(await ws.receive_json())
        if first.t != "hello":
            await ws.send_json(wire(ServerError(message="expected hello")))
        await ws.send_json(wire(engine.ready()))
        await _loop(ws, engine)
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


async def _loop(ws: WebSocket, engine: SessionEngine) -> None:
    """pause -> ask -> (answer | timeout) -> reply -> resume, until the client says bye."""
    while True:
        msg = _client_msg.validate_python(await ws.receive_json())
        if msg.t == "bye":
            await ws.send_json(wire(engine.end()))
            return
        if msg.t != "position":
            continue
        idx = engine.due_question(msg.seconds)
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
