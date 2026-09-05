from __future__ import annotations

import json

from heygilli_agents.tools.icons import (
    _DEFAULT_PATH,
    find_icon,
    icon_ids,
    icon_lookup,
    label_for,
    list_icons,
)


def test_library_matches_shared_icons_json() -> None:
    raw = json.loads(_DEFAULT_PATH.read_text(encoding="utf-8"))
    assert icon_ids() == frozenset(i["id"] for i in raw)
    assert all(i["id"].startswith("icon_") and i["en"] and i["ur"] for i in raw)


def test_exact_and_fuzzy_lookup() -> None:
    assert find_icon("giraffe")["id"] == "icon_giraffe"
    assert find_icon("icon_giraffe")["id"] == "icon_giraffe"
    assert find_icon("Giraff")["id"] == "icon_giraffe"  # typo
    assert find_icon("purple colour")["id"] == "icon_purple"  # per-word fallback
    assert find_icon("زرافہ")["id"] == "icon_giraffe"  # Urdu label
    assert find_icon("quasar") is None
    assert find_icon("") is None


def test_tool_wrappers_are_directly_callable() -> None:
    assert icon_lookup("giraffe") == {"found": True, "icon_id": "icon_giraffe", "en": "giraffe", "ur": "زرافہ"}
    assert icon_lookup("quasar")["found"] is False
    assert "icon_red" in list_icons()
    assert label_for("icon_red", "ur") and label_for("icon_red") == "red"
    assert label_for("icon_nope") == "icon_nope"
