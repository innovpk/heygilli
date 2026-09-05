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
for role in ("CURATOR", "PLANNER", "BUDDY", "DIGEST"):
    os.environ[f"HEYGILLI_MODEL_{role}"] = "fake:"
os.environ.pop("GOOGLE_API_KEY", None)

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
def no_network(monkeypatch: pytest.MonkeyPatch):
    """Any accidental HTTP call fails loudly instead of hitting YouTube or AWS."""
    import httpx

    def _boom(*_a, **_k):
        raise AssertionError("network call attempted in an offline test")

    # Real sockets live in the transports; FastAPI's TestClient uses its own ASGI transport.
    monkeypatch.setattr(httpx.HTTPTransport, "handle_request", _boom)
    monkeypatch.setattr(httpx.AsyncHTTPTransport, "handle_async_request", _boom)
    yield
