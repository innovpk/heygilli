"""Offline test setup: fake model for every role, TTS off, a temp-dir store.

Environment is pinned *before* any heygilli_agents import because store.py and
gateway.py read env at import time.
"""
from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest

_TMP_ROOT = Path(tempfile.mkdtemp(prefix="heygilli-tests-"))
os.environ["HEYGILLI_DATA_DIR"] = str(_TMP_ROOT / "data")
os.environ["HEYGILLI_TTS"] = "off"
os.environ["HEYGILLI_STORE"] = "local"
for role in ("CURATOR", "PLANNER", "BUDDY", "DIGEST", "REVIEWER", "COACH"):
    os.environ[f"HEYGILLI_MODEL_{role}"] = "fake:"
os.environ.pop("GOOGLE_API_KEY", None)
# Same for the YouTube key. The Curator now looks up video lengths through
# `videos.list` on every run, so a key left in the environment would have the
# suite quietly calling YouTube for real — burning a live quota and making the
# tests depend on the network.
os.environ.pop("HEYGILLI_YOUTUBE_API_KEY", None)
# Blank, not absent: gateway.py calls load_dotenv() at import, and python-dotenv
# leaves a key that already exists alone. Tests that need Google sign-in set
# their own values (tests/test_google_auth.py).
os.environ["GOOGLE_CLIENT_ID"] = ""
os.environ["GOOGLE_CLIENT_SECRET"] = ""

from heygilli_agents.store import LocalStore, set_store  # env must be set first

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture(autouse=True)
def store(tmp_path: Path) -> LocalStore:
    """Every test gets its own empty LocalStore wired in as the process store."""
    s = LocalStore(tmp_path / "store")
    set_store(s)
    yield s
    set_store(None)


@pytest.fixture(autouse=True)
def no_caption_throttle(monkeypatch: pytest.MonkeyPatch):
    """The caption throttle is a real sleep. Tests must not serve it."""
    from heygilli_agents.tools import transcript

    monkeypatch.setattr(transcript, "CAPTION_INTERVAL_S", 0.0)


@pytest.fixture(autouse=True)
def no_network(monkeypatch: pytest.MonkeyPatch):
    """Any accidental HTTP call fails loudly instead of hitting YouTube or AWS."""
    import httpx

    def _boom(*_a, **_k):
        raise AssertionError("network call attempted in an offline test")

    # Real sockets live in the transports; FastAPI's TestClient uses its own ASGI transport.
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _boom)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", _boom)
    yield
