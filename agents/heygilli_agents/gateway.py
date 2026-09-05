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
from .planner import ensure_plan, fallback_plan
from .schemas import (
    Channel,
    ClientAnswer,
    ClientMessage,
    Kid,
    Language,
    ServerError,
    ServerPause,
    ServerResume,
    Session,
    Video,
    new_id,
    wire,
)
from .store import get_store
from .tools.tts import TTS_DIR
from .tools.youtube import fetch_video_meta, resolve_channel_url

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
    hid = "hh_" + hashlib.sha1(body.name.strip().lower().encode()).hexdigest()[:10]
    return {"token": sign(hid), "household_id": hid}


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


@app.post("/kids/{kid_id}/channels")
def add_channel(kid_id: str, body: ChannelIn, hid: str = Depends(household)) -> dict:
    _kid(hid, kid_id)
    try:
        info = resolve_channel_url(body.url)
    except Exception as e:
        raise HTTPException(400, f"could not resolve channel: {e}") from e
    ch = Channel(id=info["channel_id"], title=info["title"], thumb_url=info["thumb_url"], approved=True)
    get_store().put_channel(hid, kid_id, ch)
    return ch.model_dump()


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
