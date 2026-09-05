"""End-to-end smoke against a running gateway: REST setup, then one WebSocket turn.

    uv run uvicorn heygilli_agents.gateway:app --port 8080 &
    uv run python scripts/smoke_gateway.py --video 0jKoOUZ1GBM --channel https://www.youtube.com/@SciShowKids

Prints every response with its latency. Exit code 0 when the WS turn completed
(hello -> ready -> pause -> ask -> answer -> reply -> resume -> end).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time

import httpx
import websockets


def step(name: str, t0: float, payload) -> None:
    print(f"[{int((time.perf_counter() - t0) * 1000):>6} ms] {name}: {json.dumps(payload, ensure_ascii=False)[:400]}")


RECV_TIMEOUT_S = 60.0  # a Bedrock call plus Polly; anything slower is a failure worth seeing


async def recv(ws) -> dict:
    return json.loads(await asyncio.wait_for(ws.recv(), RECV_TIMEOUT_S))


async def ws_turn(base: str, session_id: str, token: str, ask_at: float, transcript: str, pick: int) -> bool:
    url = base.replace("http", "ws", 1) + f"/sessions/{session_id}/ws?token={token}"
    async with websockets.connect(url) as ws:
        t0 = time.perf_counter()
        await ws.send(json.dumps({"t": "hello"}))
        ready = await recv(ws)
        step("ready", t0, ready)
        await ws.send(json.dumps({"t": "position", "seconds": ask_at}))
        print(f"sent position {ask_at}s (plan has {ready.get('plan_questions')} questions)")
        pause = await recv(ws)
        step("pause", t0, pause)
        t1 = time.perf_counter()
        ask = await recv(ws)
        step("ask", t1, ask)
        if ask.get("t") != "ask":
            return False
        if ask["input"] == "pick":
            answer = {"t": "answer", "q": ask["q"], "input": "pick", "option": pick}
        elif ask["input"] == "copy":
            answer = {"t": "answer", "q": ask["q"], "input": "copy"}
        else:
            answer = {"t": "answer", "q": ask["q"], "input": "voice", "transcript": transcript}
        await ws.send(json.dumps(answer))
        t2 = time.perf_counter()
        reply = await recv(ws)
        step("reply", t2, reply)
        resume = await recv(ws)
        step("resume", t2, resume)
        await ws.send(json.dumps({"t": "bye"}))
        end = await recv(ws)
        step("end", t0, end)
        return reply.get("t") == "reply" and resume.get("t") == "resume" and end.get("t") == "end"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8080")
    ap.add_argument("--video", default="0jKoOUZ1GBM")
    ap.add_argument("--channel", default="https://www.youtube.com/@SciShowKids")
    ap.add_argument("--age", type=int, default=8)
    ap.add_argument("--transcript", default="because the lava was really hot and it came out of the ground")
    ap.add_argument("--pick", type=int, default=0)
    ap.add_argument("--plan-wait", type=float, default=90, help="seconds to wait for plan_ready")
    a = ap.parse_args()

    c = httpx.Client(base_url=a.base, timeout=60)
    t0 = time.perf_counter()
    auth = c.post("/auth/dev", json={"name": "smoke parent"}).json()
    step("POST /auth/dev", t0, auth)
    h = {"Authorization": f"Bearer {auth['token']}"}

    t0 = time.perf_counter()
    kid = c.post("/kids", json={"nickname": "Smoke", "age": a.age, "languages": ["en"]}, headers=h).json()
    step("POST /kids", t0, kid)

    t0 = time.perf_counter()
    r = c.post(f"/kids/{kid['id']}/channels", json={"url": a.channel}, headers=h)
    step(f"POST /kids/{{id}}/channels -> {r.status_code}", t0, r.json())

    t0 = time.perf_counter()
    home = c.get(f"/kids/{kid['id']}/home", headers=h).json()
    step("GET /kids/{id}/home", t0, home)

    t0 = time.perf_counter()
    ses = c.post("/sessions", json={"kid_id": kid["id"], "video_id": a.video, "device": "tv"}, headers=h).json()
    step("POST /sessions", t0, ses)

    deadline = time.perf_counter() + a.plan_wait
    plan_ready = ses.get("plan_ready", False)
    while not plan_ready and time.perf_counter() < deadline:
        time.sleep(2)
        again = c.post("/sessions", json={"kid_id": kid["id"], "video_id": a.video, "device": "tv"}, headers=h).json()
        plan_ready = again["plan_ready"]
        if plan_ready:
            ses = again
            step("POST /sessions (plan ready)", deadline - a.plan_wait, ses)
    if not plan_ready:
        print("plan not ready in time; the WS turn will use the generic fallback plan")

    # Ask position: read the plan's first t_sec from the store when local, else jump near the end.
    ask_at = float(ses["video"].get("duration_s") or 600) - 2
    try:
        from heygilli_agents.store import get_store

        plan = get_store().get_plan(a.video, kid["age_band"], "en")
        if plan and plan.questions:
            ask_at = plan.questions[0].t_sec + 0.5
    except Exception as e:  # noqa: BLE001 - store may not be local; jump to the end instead
        print(f"(no local plan lookup: {e})")

    ok = asyncio.run(ws_turn(a.base, ses["session_id"], auth["token"], ask_at, a.transcript, a.pick))
    t0 = time.perf_counter()
    step("POST /sessions/{id}/end", t0, c.post(f"/sessions/{ses['session_id']}/end", headers=h).json())
    t0 = time.perf_counter()
    step("GET /kids/{id}/digest", t0, c.get(f"/kids/{kid['id']}/digest", headers=h).json())
    print("WS turn", "OK" if ok else "FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
