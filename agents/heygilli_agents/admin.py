"""The operator's overview: who has tried HeyGilli, and how far they got.

Read-only, and only for the service's own admins. An admin is a Google
account, matched on the SHA-256 of its email so that the address itself is not
in a public repo. `HEYGILLI_ADMIN_EMAILS` (comma-separated) adds more without a
release.

Nothing here returns an email, a token, or anything a child said: a household
is a short id, whether it signed in with Google, its children's nicknames and
ages (nicknames by design, never real names), and how much it has watched.
"""
from __future__ import annotations

import hashlib
import os
import re
from collections import Counter, defaultdict
from typing import Any

from .store import Store

#: SHA-256 of each admin's lowercased email.
ADMIN_EMAIL_SHA256 = frozenset(
    {"f4165d1fc1bdede618443e807e6e1a05a0de5d1c3ff8ba3b352f12d43509b581"}
)

#: Nicknames the team's own checks use. A household is flagged, never hidden:
#: the flag is a guess, and the admin sees the row either way.
_TEST_NAME = re.compile(
    r"^(ver|verify\w*|diag|live|btn|fin|repro\w*|probe|reg|exist|one|why|chk|"
    r"sear|fix|mix|run|new|abc|kid|test.*|\w+kid)$",
    re.IGNORECASE,
)


def _digest(email: str) -> str:
    return hashlib.sha256(email.strip().lower().encode()).hexdigest()


def is_admin_email(email: str) -> bool:
    if not email.strip():
        return False
    extra = {
        e.strip().lower()
        for e in os.getenv("HEYGILLI_ADMIN_EMAILS", "").split(",")
        if e.strip()
    }
    return _digest(email) in ADMIN_EMAIL_SHA256 or email.strip().lower() in extra


def is_admin(store: Store, household: str) -> bool:
    """Only a household signed in with an admin's Google account. Signing in
    without Google is never enough: that name is chosen by the browser."""
    link = store.get_google_link(household)
    return bool(link and is_admin_email(link.email))


def overview(store: Store, admin_household: str | None = None) -> dict[str, Any]:
    """Every household, newest activity first, with totals and sessions per day."""
    hh: dict[str, dict[str, Any]] = defaultdict(
        lambda: {"kids": [], "google": False, "times": [], "sessions": 0, "watched_sec": 0}
    )
    per_day: Counter[str] = Counter()
    feedback_open = 0
    for hid, entity, doc in store.scan({"kid", "google_link", "session", "policy", "feedback"}):
        if entity == "feedback":
            feedback_open += not doc.get("done")
            continue
        h = hh[hid]
        if entity == "kid":
            h["kids"].append({"nickname": doc.get("nickname", ""), "age": doc.get("age")})
        elif entity == "google_link":
            h["google"] = True
            if doc.get("linked_at"):
                h["times"].append(doc["linked_at"])
        elif entity == "session":
            h["sessions"] += 1
            h["watched_sec"] += int(doc.get("watched_sec") or 0)
            if doc.get("started_at"):
                h["times"].append(doc["started_at"])
            if doc.get("date"):
                per_day[doc["date"]] += 1
        elif entity == "policy" and doc.get("updated_at"):
            h["times"].append(doc["updated_at"])

    households = []
    for hid, h in hh.items():
        # A test is a household whose every child has a test's name and that
        # never watched anything. A real family that named a child "Kid" and
        # watched a video is counted as real.
        likely_test = (
            bool(h["kids"])
            and not h["sessions"]
            and all(_TEST_NAME.match(k["nickname"] or "") for k in h["kids"])
        )
        households.append(
            {
                "id": hid,
                "first_seen": min(h["times"]) if h["times"] else None,
                "last_active": max(h["times"]) if h["times"] else None,
                "google": h["google"],
                "kids": h["kids"],
                "sessions": h["sessions"],
                "minutes_watched": round(h["watched_sec"] / 60),
                "likely_test": likely_test,
                "you": hid == admin_household,
            }
        )
    households.sort(key=lambda r: r["last_active"] or "", reverse=True)
    real = [r for r in households if not r["likely_test"] and not r["you"]]
    return {
        "totals": {
            "households": len(households),
            "google": sum(r["google"] for r in households),
            "with_kid": sum(bool(r["kids"]) for r in households),
            "watched": sum(r["sessions"] > 0 for r in households),
            "sessions": sum(r["sessions"] for r in households),
            "likely_tests": sum(r["likely_test"] for r in households),
            "real": len(real),
            "real_watched": sum(r["sessions"] > 0 for r in real),
            "feedback_open": feedback_open,
        },
        "sessions_per_day": [
            {"date": d, "sessions": n} for d, n in sorted(per_day.items())
        ],
        "households": households,
    }
