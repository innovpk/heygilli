"""Feedback from parents, and the admins' list of it.

A parent writes a line or two from the parent side of the app; nothing in kid
mode reaches this. It is stored with the household, so it goes when the
household does, and only the service's admins read it (see admin.py).
"""
from __future__ import annotations

from typing import Any

from .schemas import new_id, now_iso
from .store import Store

MAX_TEXT = 2000
MAX_CONTACT = 200

#: A parent with a lot to say can say it; a script cannot fill the table.
PER_DAY = 10


class FeedbackLimit(Exception):
    pass


def send(store: Store, household: str, text: str, contact: str = "", where: str = "") -> dict[str, Any]:
    today = now_iso()[:10]
    sent_today = sum(
        1 for f in store.list(household, "feedback") if str(f.get("created_at", ""))[:10] == today
    )
    if sent_today >= PER_DAY:
        raise FeedbackLimit(f"{PER_DAY} a day is the most; thank you, and try again tomorrow")
    item = {
        "id": new_id("fb"),
        "text": text.strip()[:MAX_TEXT],
        "contact": contact.strip()[:MAX_CONTACT],
        "where": where.strip()[:60],
        "created_at": now_iso(),
        "done": False,
    }
    store.put(household, "feedback", item["id"], item)
    return item


def _public(doc: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in doc.items() if k != "_id"}


def all_feedback(store: Store) -> list[dict[str, Any]]:
    """Every household's feedback, newest first, each tagged with its household."""
    rows = [{**_public(doc), "household": hid} for hid, _, doc in store.scan({"feedback"})]
    rows.sort(key=lambda f: str(f.get("created_at", "")), reverse=True)
    return rows


def set_done(store: Store, household: str, feedback_id: str, done: bool) -> dict[str, Any] | None:
    item = store.get(household, "feedback", feedback_id)
    if item is None:
        return None
    item = {**_public(item), "done": done}
    store.put(household, "feedback", feedback_id, item)
    return item
