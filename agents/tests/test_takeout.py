"""Takeout zip parsing (PROTOCOL.md "Takeout import"), offline.

Every fixture here is invented: made-up channel ids and titles in the real
Takeout layout. The user's own export is never copied into the repo.
"""
from __future__ import annotations

import io
import zipfile

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway
from heygilli_agents.takeout import (
    MAX_ZIP_BYTES,
    TakeoutError,
    parse_subscriptions_csv,
    parse_takeout_dir,
    parse_takeout_zip,
)

HEADER = "Channel ID,Channel URL,Channel title\n"
ID_A = "UCaaaaaaaaaaaaaaaaaaaaaa"
ID_B = "UCbbbbbbbbbbbbbbbbbbbbbb"
ID_C = "UCcccccccccccccccccccccc"
ID_D = "UCdddddddddddddddddddddd"


def row(channel_id: str, title: str) -> str:
    quoted = f'"{title}"' if "," in title else title
    return f"{channel_id},http://www.youtube.com/channel/{channel_id},{quoted}\n"


def csv_bytes(*rows: str, bom: bool = False, crlf: bool = False) -> bytes:
    text = HEADER + "".join(rows)
    if crlf:
        text = text.replace("\n", "\r\n")
    return (b"\xef\xbb\xbf" if bom else b"") + text.encode("utf-8")


def make_zip(files: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in files.items():
            z.writestr(name, data)
    return buf.getvalue()


def takeout_zip(top: str = "Takeout", yt: str = "YouTube and YouTube Music") -> bytes:
    """A realistic export: two child profiles, the parent's own list, and the
    history files that must never be opened."""
    return make_zip(
        {
            f"{top}/{yt}/subscriptions/subscriptions.csv": csv_bytes(
                row(ID_A, "Parent Follows This"), bom=True
            ),
            f"{top}/{yt}/children/Ayaan/subscriptions.csv": csv_bytes(
                row(ID_A, "Sprout Science"),
                row(ID_B, "Blocks, Bricks and Bots"),  # a comma inside a quoted title
                row(ID_A, "Sprout Science"),  # a duplicate row
                crlf=True,
            ),
            f"{top}/{yt}/children/Zara/subscriptions.csv": csv_bytes(
                row(ID_C, "Paper Planet"), row(ID_D, "Tiny Chef Club")
            ),
            f"{top}/{yt}/children/Ayaan/watch-history.html": b"<html>SECRET WATCH HISTORY</html>",
            f"{top}/{yt}/children/Ayaan/search-history.html": b"<html>SECRET SEARCHES</html>",
            f"{top}/archive_browser.html": b"<html>index</html>",
        }
    )


# --- the CSV itself ---------------------------------------------------------


def test_csv_tolerates_bom_crlf_quoted_commas_and_dedupes() -> None:
    channels = parse_subscriptions_csv(
        csv_bytes(row(ID_A, "Sprout Science"), row(ID_B, "Blocks, Bricks and Bots"),
                  row(ID_A, "Sprout Science"), bom=True, crlf=True)
    )
    assert [c.channel_id for c in channels] == [ID_A, ID_B]
    assert channels[1].title == "Blocks, Bricks and Bots"
    assert channels[0].url == f"http://www.youtube.com/channel/{ID_A}"


def test_csv_skips_header_blank_lines_and_junk() -> None:
    raw = (HEADER + "\n" + row(ID_A, "Keep") + "not-a-channel,x,y\n" + "\n").encode()
    assert [c.channel_id for c in parse_subscriptions_csv(raw)] == [ID_A]


def test_csv_without_a_title_column_falls_back_to_the_id() -> None:
    channels = parse_subscriptions_csv(f"{ID_A}\n".encode())
    assert channels[0].title == ID_A
    assert channels[0].url == f"https://www.youtube.com/channel/{ID_A}"


# --- the zip ----------------------------------------------------------------


def test_preview_shape_from_a_realistic_zip() -> None:
    preview = parse_takeout_zip(takeout_zip())
    assert [p.name for p in preview.profiles] == ["Ayaan", "Zara"]
    ayaan, zara = preview.profiles
    assert ayaan.channel_count == 2 == len(ayaan.channels)
    assert [c.title for c in ayaan.channels] == ["Sprout Science", "Blocks, Bricks and Bots"]
    assert zara.channel_count == 2
    assert preview.parent is not None
    assert preview.parent.channel_count == 1
    assert preview.parent.channels[0].title == "Parent Follows This"
    # The exact wire shape the Flutter client parses.
    assert set(preview.model_dump()) == {"profiles", "parent"}
    assert set(preview.model_dump()["profiles"][0]) == {"name", "channel_count", "channels"}
    assert set(preview.model_dump()["profiles"][0]["channels"][0]) == {"channel_id", "title", "url"}


@pytest.mark.parametrize(
    ("top", "yt"),
    [("Takeout", "YouTube and YouTube Music"), ("Takeout 2", "YouTube und YouTube Music"),
     ("", "YouTube y YouTube Music")],
)
def test_nested_folder_names_and_locales_do_not_matter(top: str, yt: str) -> None:
    data = takeout_zip(top=top or "export", yt=yt)
    preview = parse_takeout_zip(data)
    assert [p.name for p in preview.profiles] == ["Ayaan", "Zara"]
    assert preview.parent is not None and preview.parent.channel_count == 1


def test_a_fully_localised_export_parses() -> None:
    """A French export renames every part of the path, the CSV included. The
    own-list file (`abonnements/abonnements.csv`) is what names the locale's word
    for "subscriptions", and the per-profile files then follow."""
    data = make_zip({
        "Takeout/YouTube et YouTube Music/abonnements/abonnements.csv": csv_bytes(row(ID_A, "Parent")),
        "Takeout/YouTube et YouTube Music/enfants/Ayaan/abonnements.csv": csv_bytes(row(ID_B, "Kid")),
        "Takeout/YouTube et YouTube Music/enfants/Ayaan/historique-de-visionnage.html": b"<html>no</html>",
    })
    preview = parse_takeout_zip(data)
    assert [(p.name, p.channel_count) for p in preview.profiles] == [("Ayaan", 1)]
    assert preview.parent is not None and preview.parent.channels[0].title == "Parent"


def test_history_files_are_never_opened(monkeypatch: pytest.MonkeyPatch) -> None:
    """SPEC §12: watch and search history are the most sensitive files in the
    export. Nothing here reads them, so nothing can leak them."""
    data = takeout_zip()  # built before the spy: writestr opens members too
    opened: list[str] = []
    real_open = zipfile.ZipFile.open

    def spy(self, name, *a, **k):
        opened.append(name.filename if hasattr(name, "filename") else str(name))
        return real_open(self, name, *a, **k)

    monkeypatch.setattr(zipfile.ZipFile, "open", spy)
    parse_takeout_zip(data)

    assert opened, "the parse read nothing at all"
    assert all(o.endswith("subscriptions.csv") for o in opened), opened
    assert not any("history" in o for o in opened)


def test_a_zip_that_is_not_a_takeout_export_is_refused() -> None:
    with pytest.raises(TakeoutError, match="no subscriptions.csv"):
        parse_takeout_zip(make_zip({"holiday/photo.jpg": b"\xff\xd8\xff", "notes.txt": b"hi"}))


def test_a_file_that_is_not_a_zip_is_refused() -> None:
    with pytest.raises(TakeoutError, match="not a zip"):
        parse_takeout_zip(b"PK-not-really" + b"\x00" * 100)
    with pytest.raises(TakeoutError, match="empty"):
        parse_takeout_zip(b"")


def test_zip_slip_member_is_refused() -> None:
    data = make_zip({
        "Takeout/YT/subscriptions/subscriptions.csv": csv_bytes(row(ID_A, "Fine")),
        "../../../../etc/cron.d/pwn": b"* * * * * root sh",
    })
    with pytest.raises(TakeoutError, match="unsafe path"):
        parse_takeout_zip(data)


def test_absolute_member_path_is_refused() -> None:
    data = make_zip({"/etc/passwd": b"root:x:0:0", "T/subscriptions/subscriptions.csv": csv_bytes()})
    with pytest.raises(TakeoutError, match="unsafe path"):
        parse_takeout_zip(data)


def test_oversize_upload_is_refused_before_it_is_parsed() -> None:
    with pytest.raises(TakeoutError, match="the limit is"):
        parse_takeout_zip(b"x" * (MAX_ZIP_BYTES + 1))


def test_too_many_entries_is_refused() -> None:
    from heygilli_agents import takeout

    data = make_zip({f"T/f{i}.txt": b"x" for i in range(30)})
    monkey_limit = 10
    old = takeout.MAX_ZIP_ENTRIES
    takeout.MAX_ZIP_ENTRIES = monkey_limit
    try:
        with pytest.raises(TakeoutError, match="not a Takeout export"):
            parse_takeout_zip(data)
    finally:
        takeout.MAX_ZIP_ENTRIES = old


def test_parse_takeout_dir_matches_the_zip(tmp_path) -> None:
    with zipfile.ZipFile(io.BytesIO(takeout_zip())) as z:
        z.extractall(tmp_path)
    preview = parse_takeout_dir(tmp_path)
    assert [p.name for p in preview.profiles] == ["Ayaan", "Zara"]
    assert preview.parent is not None and preview.parent.channel_count == 1


# --- the endpoint -----------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def hdr(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Takeout Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}"}


def test_import_takeout_endpoint_returns_the_preview(client: TestClient, hdr: dict) -> None:
    r = client.post("/import/takeout", files={"file": ("takeout.zip", takeout_zip(), "application/zip")},
                    headers=hdr)
    assert r.status_code == 200
    body = r.json()
    assert [p["name"] for p in body["profiles"]] == ["Ayaan", "Zara"]
    assert body["parent"]["channel_count"] == 1


def test_import_takeout_needs_auth_and_rejects_junk(client: TestClient, hdr: dict) -> None:
    assert client.post("/import/takeout", files={"file": ("t.zip", b"x", "application/zip")}).status_code == 401
    r = client.post("/import/takeout", files={"file": ("t.zip", b"not a zip at all", "application/zip")},
                    headers=hdr)
    assert r.status_code == 400 and "not a zip" in r.json()["detail"]


def test_import_takeout_persists_nothing(client: TestClient, hdr: dict, store) -> None:
    client.post("/import/takeout", files={"file": ("takeout.zip", takeout_zip(), "application/zip")},
                headers=hdr)
    assert client.get("/kids", headers=hdr).json() == []
    assert not any(p.is_file() for p in store.root.rglob("*.json"))


# --- pacing the caption fetches ------------------------------------------------------------------


def test_captions_are_spaced_out_so_youtube_does_not_cut_us_off(monkeypatch) -> None:
    """A 148-channel household tripped YouTube's rate limit about thirty
    requests in, and curation stopped a fifth of the way through. Being slow
    costs a parent nothing; being cut off costs them the whole screening."""
    from heygilli_agents.tools import transcript

    slept: list[float] = []
    monkeypatch.setattr(transcript, "CAPTION_INTERVAL_S", 2.0)
    monkeypatch.setattr(transcript.time, "sleep", slept.append)
    monkeypatch.setattr(transcript.time, "monotonic", lambda: 0.0)
    monkeypatch.setattr(transcript, "_last_caption_at", 0.0)

    transcript._wait_turn()
    transcript._wait_turn()

    assert slept, "requests went out back to back"
    # Jittered, never less than the interval: evenly spaced requests read as a
    # script even when they are slow.
    assert all(2.0 <= s <= 3.0 for s in slept), slept


def test_the_throttle_can_be_turned_off(monkeypatch) -> None:
    from heygilli_agents.tools import transcript

    slept: list[float] = []
    monkeypatch.setattr(transcript, "CAPTION_INTERVAL_S", 0.0)
    monkeypatch.setattr(transcript.time, "sleep", slept.append)
    transcript._wait_turn()
    assert slept == [], "a disabled throttle still slept"


def test_the_caption_path_actually_waits_its_turn(monkeypatch) -> None:
    """The wiring, not the helper.

    Testing `_wait_turn` in isolation says nothing about whether the caption
    code calls it: deleting both calls left every other test in this file
    green. This one drives `_from_captions` and asserts the throttle was
    reached before each network step.
    """
    from heygilli_agents.tools import transcript

    waits: list[str] = []
    monkeypatch.setattr(transcript, "_wait_turn", lambda: waits.append("wait"))

    class _Transcript:
        language_code = "en"
        is_generated = True

        def fetch(self):
            waits.append("fetch")
            return []

    class _Listing:
        def find_manually_created_transcript(self, langs):
            raise transcript_errors().NoTranscriptFound("v", langs, {})

        def find_generated_transcript(self, langs):
            return _Transcript()

        def __iter__(self):
            return iter([_Transcript()])

    class _Api:
        def __init__(self, proxy_config=None):
            self.proxy_config = proxy_config

        def list(self, video_id: str):
            waits.append("list")
            return _Listing()

    import youtube_transcript_api

    monkeypatch.setattr(youtube_transcript_api, "YouTubeTranscriptApi", _Api)
    transcript._from_captions("vid123")

    # A throttle before the listing and again before the fetch: both are
    # requests, and it was the sheer number of them that got us cut off.
    assert waits == ["wait", "list", "wait", "fetch"], waits


def transcript_errors():
    import youtube_transcript_api._errors as e

    return e
