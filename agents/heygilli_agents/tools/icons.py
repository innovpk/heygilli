"""Icon library lookup. The Planner may only use ids that exist in shared/icons.json."""
from __future__ import annotations

import difflib
import json
import os
from functools import lru_cache
from pathlib import Path

from strands import tool

_DEFAULT_PATH = Path(__file__).resolve().parents[3] / "shared" / "icons.json"


@lru_cache(maxsize=1)
def library() -> list[dict]:
    path = Path(os.getenv("HEYGILLI_ICONS_PATH", _DEFAULT_PATH))
    return json.loads(path.read_text(encoding="utf-8"))


@lru_cache(maxsize=1)
def icon_ids() -> frozenset[str]:
    return frozenset(i["id"] for i in library())


def label_for(icon_id: str, language: str = "en") -> str:
    for i in library():
        if i["id"] == icon_id:
            return i.get(language) or i["en"]
    return icon_id


def find_icon(concept: str, cutoff: float = 0.72) -> dict | None:
    """Exact match on id/concept/en/ur first, then fuzzy on the English fields."""
    c = concept.strip().lower()
    if not c:
        return None
    c = c.removeprefix("icon_")
    for i in library():
        if c in (i["id"][5:], i["concept"].lower(), i["en"].lower(), i["ur"]):
            return i
    names = {i["en"].lower(): i for i in library()}
    names.update({i["concept"].lower(): i for i in library()})
    # Fuzzy on the whole phrase first ("giraff"), then per word ("purple colour", "a big lion").
    for candidate in [c, *c.split()]:
        best = difflib.get_close_matches(candidate, list(names), n=1, cutoff=cutoff)
        if best:
            return names[best[0]]
    return None


@tool
def icon_lookup(concept: str) -> dict:
    """Find the kid-safe icon for a concept so a pick-it option can show a picture.

    Args:
        concept: one English word such as "giraffe", "red", "three" or "happy".

    Returns:
        {"found": bool, "icon_id": str | None, "en": str, "ur": str}
    """
    hit = find_icon(concept)
    if not hit:
        return {"found": False, "icon_id": None, "en": concept, "ur": ""}
    return {"found": True, "icon_id": hit["id"], "en": hit["en"], "ur": hit["ur"]}


@tool
def list_icons() -> list[str]:
    """List every icon id that a pick-it option is allowed to use."""
    return sorted(icon_ids())
