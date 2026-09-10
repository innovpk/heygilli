"""What the agents did, what went wrong, and what was done about it.

Three jobs, over data the gateway already keeps:

- `record` writes one event per agent call (the role, what came back, how
  long it took, whether a guardrail fired and whether the retry fixed it) and
  an incident for every guardrail that fired. Each event points at its trace.
- `audit_household` looks back over what the agents already did and fixes
  what the rules now say was wrong. A Curator approval of a video that breaks
  a safety rule is hidden; one that should have gone to the parent goes back
  to them; a cached question plan with something a child must not hear is
  dropped, so the next play writes a new one. An agent that keeps failing is
  reported. It never touches a decision a parent made.
- `report` puts it together for a parent, and `ops_report` across every
  household for whoever runs the service.
"""
from __future__ import annotations

import json
import logging
from datetime import UTC, datetime, timedelta
from typing import Any

log = logging.getLogger(__name__)

KEEP_DAYS = 14
DEGRADED_MIN_CALLS = 5
DEGRADED_RATE = 0.3

OUTCOME_TEXT = {
    "fixed": "fixed: the agent corrected its answer when told what was wrong",
    "blocked": "fallback: the answer was not used, the safe built-in was",
    "warned": "flagged: used, but worth a look",
}


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds")


def _since(days: float) -> str:
    return (datetime.now(UTC) - timedelta(days=days)).isoformat(timespec="milliseconds")


def _incident(household: str, key: str, incident: dict[str, Any]) -> dict[str, Any]:
    from .store import GLOBAL, get_store

    store = get_store()
    store.put(household or GLOBAL, "agent_incident", key, incident)
    # Mirrored across households for the operator, who has no other way to
    # see every household's incidents at once.
    store.put(GLOBAL, "agent_incident_all", f"{household}_{key}", {**incident, "household": household})
    log.warning("agent_incident %s", json.dumps({**incident, "household": household}, ensure_ascii=False))
    return incident


def record(
    *,
    role: str,
    output: str,
    outcome: str,
    violations: list,
    ms: int,
    trace_id: str,
    household: str,
    kid_id: str,
) -> None:
    """One agent call: an event always, an incident when a guardrail fired."""
    from .store import GLOBAL, get_store

    at = _now()
    # The whole trace id: two calls can end in the same millisecond.
    key = f"{at}_{trace_id}"
    event = {
        "at": at,
        "role": role,
        "output": output,
        "outcome": outcome,
        "ms": ms,
        "kid_id": kid_id,
        "trace_id": trace_id,
        "rules": [v.rule for v in violations],
    }
    log.info("agent_event %s", json.dumps({**event, "household": household}))
    try:
        get_store().put(household or GLOBAL, "agent_event", key, event)
        if violations:
            _incident(household, key, {
                "at": at,
                "kind": "guardrail",
                "role": role,
                "kid_id": kid_id,
                "rules": [v.rule for v in violations],
                "detail": "; ".join(v.detail for v in violations),
                "outcome": OUTCOME_TEXT.get(outcome, outcome),
                "trace_id": trace_id,
            })
    except Exception as e:  # noqa: BLE001 - recording must never break the call it records
        log.warning("could not record agent event: %s", e)


# --- looking back -------------------------------------------------------------------------------------


def audit_household(household: str) -> list[dict[str, Any]]:
    """Find what the agents got wrong in this household, fix it, and say so."""
    from . import guardrails
    from .schemas import QuestionPlan
    from .store import GLOBAL, get_store
    from .tools.screening import ASK_WORDS, _hits, blocked_for_everyone

    store = get_store()
    fixes: list[dict[str, Any]] = []
    for kid in store.list_kids(household):
        band = kid.age_band or "7_8"
        language = kid.languages[0] if kid.languages else "en"
        for vid, entry in store.list_kid_videos(household, kid.id).items():
            if entry.get("status") != "approve":
                continue
            video = store.get_video(vid)
            if video is None:
                continue
            # Only what an agent decided. A parent who allowed something has
            # made the call this audit exists to protect.
            if entry.get("decided_by") not in ("parent", "audit"):
                blocked = blocked_for_everyone(video)
                asks = [] if blocked else _hits(f"{video.title} {video.description}", ASK_WORDS)
                if blocked or asks:
                    fixes.append(_fix_approval(household, kid, video, blocked.reason if blocked else "", asks))
                    continue
            key = QuestionPlan.key(vid, band, language)
            plan = store.get_plan(vid, band, language)
            if plan and (bad := guardrails.blocking(guardrails.check("QuestionPlan", plan))):
                store.delete(GLOBAL, "plan", key)
                fixes.append(_incident(household, f"plan_{key}", {
                    "at": _now(),
                    "kind": "audit",
                    "role": "planner",
                    "kid_id": kid.id,
                    "video_id": vid,
                    "rules": [b.rule for b in bad],
                    "detail": f"questions for \"{video.title}\": " + "; ".join(b.detail for b in bad),
                    "outcome": "fixed: the questions were dropped and are written again the next time it is played",
                    "trace_id": "",
                }))
    fixes += _degraded(household)
    _prune(household)
    return fixes


def _fix_approval(household: str, kid, video, blocked_reason: str, asks: list[str]) -> dict[str, Any]:
    from .store import get_store

    store = get_store()
    if blocked_reason:
        status = "hide"
        reason = f"Hidden by a later check: {blocked_reason}"
        outcome = "fixed: hidden from the shelf"
    else:
        status = "ask_parent"
        reason = f"Gilli had approved this, but it mentions {', '.join(asks)}, so it is back with you to decide."
        outcome = "fixed: taken off the shelf and sent back to the parent"
        try:
            from .tools.notify import notify_parent

            notify_parent(household, kid.id, video, reason)
        except Exception as e:  # noqa: BLE001 - the status change is the fix; the card is a courtesy
            log.warning("could not tell the parent about %s: %s", video.id, e)
    store.set_kid_video(household, kid.id, video.id, status, reason, decided_by="audit")
    return _incident(household, f"approval_{kid.id}_{video.id}", {
        "at": _now(),
        "kind": "audit",
        "role": "curator",
        "kid_id": kid.id,
        "video_id": video.id,
        "rules": ["approved_unsafe" if blocked_reason else "approved_without_asking"],
        "detail": f"\"{video.title}\" was approved, {reason[0].lower()}{reason[1:]}",
        "outcome": outcome,
        "trace_id": "",
    })


def _degraded(household: str) -> list[dict[str, Any]]:
    """An agent whose answers keep ending in the fallback is reported, once a day."""
    from .store import get_store

    since = _since(1)
    counts: dict[str, list[int]] = {}
    for e in get_store().list(household, "agent_event"):
        if e.get("at", "") < since:
            continue
        c = counts.setdefault(e["role"], [0, 0])
        c[0] += 1
        c[1] += e.get("outcome") in ("blocked", "model_error")
    out = []
    today = _now()[:10]
    for role, (n, bad) in counts.items():
        if n >= DEGRADED_MIN_CALLS and bad / n >= DEGRADED_RATE:
            out.append(_incident(household, f"degraded_{role}_{today}", {
                "at": _now(),
                "kind": "degraded",
                "role": role,
                "kid_id": "",
                "rules": ["fallback_rate"],
                "detail": f"{bad} of the {role}'s last {n} answers in a day ended in the fallback",
                "outcome": "reported: the safe built-in answered for those calls; check the model and the traces",
                "trace_id": "",
            }))
    return out


def _prune(household: str) -> None:
    from .store import get_store

    store = get_store()
    cutoff = _since(KEEP_DAYS)
    for e in store.list(household, "agent_event"):
        if e.get("at", "") < cutoff:
            store.delete(household, "agent_event", e["_id"])
            if e.get("trace_id"):
                store.delete(household, "trace", e["trace_id"])


# --- reports -------------------------------------------------------------------------------------------


def _summary(events: list[dict]) -> dict[str, dict[str, Any]]:
    agents: dict[str, dict[str, Any]] = {}
    for e in events:
        a = agents.setdefault(e["role"], {
            "calls": 0, "ok": 0, "warned": 0, "fixed": 0, "blocked": 0, "model_error": 0, "avg_ms": 0,
        })
        a["calls"] += 1
        a[e.get("outcome", "ok")] = a.get(e.get("outcome", "ok"), 0) + 1
        a["avg_ms"] += e.get("ms", 0)
    for a in agents.values():
        a["avg_ms"] = round(a["avg_ms"] / a["calls"]) if a["calls"] else 0
    return agents


def report(household: str, kid_id: str = "", days: int = 7) -> dict[str, Any]:
    from .store import get_store

    store = get_store()
    since = _since(days)

    def mine(d: dict) -> bool:
        return d.get("at", "") >= since and (not kid_id or d.get("kid_id") in (kid_id, ""))

    events = sorted((e for e in store.list(household, "agent_event") if mine(e)),
                    key=lambda e: e["at"], reverse=True)
    incidents = sorted((i for i in store.list(household, "agent_incident") if mine(i)),
                       key=lambda i: i["at"], reverse=True)
    return {
        "days": days,
        "calls": len(events),
        "agents": _summary(events),
        "incidents": incidents[:50],
        "recent": events[:30],
    }


def ops_report(days: int = 7) -> dict[str, Any]:
    from .store import GLOBAL, get_store

    store = get_store()
    since = _since(days)
    incidents = sorted((i for i in store.list(GLOBAL, "agent_incident_all") if i.get("at", "") >= since),
                       key=lambda i: i["at"], reverse=True)
    by_kind: dict[str, int] = {}
    for i in incidents:
        by_kind[i["kind"]] = by_kind.get(i["kind"], 0) + 1
    return {"days": days, "incidents": incidents[:200], "by_kind": by_kind,
            "households": len({i.get("household") for i in incidents})}
