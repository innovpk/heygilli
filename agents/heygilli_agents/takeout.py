"""Parse a Google Takeout export into a `TakeoutPreview` (PROTOCOL.md).

Takeout is the only route to a YouTube Kids profile's subscriptions: no API
exposes them. A parent exports **YouTube and YouTube Music** and uploads the
zip; this module reads the subscription CSVs out of it and returns a preview
the parent can map onto their kids.

Two things it deliberately does not do:

- It never opens `search-history.html`, and it opens `watch-history.html` only
  when the parent has ticked the box for that one import (PROTOCOL.md "Watch
  history: opt-in, aggregate, discarded"). By default both are filtered out by
  name before anything is read (SPEC §12, and
  `tests/test_takeout.py::test_history_files_are_never_opened` pins it). The
  opt-in path is `parse_takeout_zip_with_history`, a different function from the
  default one, so reading history is something a caller has to ask for by name.
- It never persists anything. `POST /import/takeout` is a pure function of the
  upload; only the per-kid import the parent makes afterwards writes.

Locale and layout. Google localises folder names, and the top-level folder may
be `Takeout`, `Takeout 2`, or missing entirely, so nothing is matched by a fixed
path. A member is a candidate when it is a `.csv` AND either

    its file name is `subscriptions.csv`          (the English export)
    or its stem equals its parent folder's name   (`abonnements/abonnements.csv`)

and the two shapes in PROTOCOL.md are then told apart by that same second test:

    .../subscriptions/subscriptions.csv        -> the signed-in account's own list
    .../children/<Profile name>/<subs>.csv     -> one YouTube Kids profile

where `<subs>` is whatever the own-list file was called, so a French export
(`enfants/Rayan/abonnements.csv`) parses exactly like an English one. A
candidate whose rows are not channel ids simply contributes nothing.

An `.html` can never be a candidate, which is what makes "history is never
opened" a property of the code rather than a promise.
"""
from __future__ import annotations

import csv
import io
import logging
import re
import zipfile
from pathlib import Path, PurePosixPath

from .history import parse_watch_history
from .schemas import (
    HistoryAggregate,
    TakeoutChannel,
    TakeoutParentList,
    TakeoutPreview,
    TakeoutProfile,
)

log = logging.getLogger(__name__)

# Guards. A real YouTube export with history is tens of megabytes; the CSVs
# themselves are kilobytes. These bound a hostile upload, not a real one.
MAX_ZIP_BYTES = 50 * 1024 * 1024  # the upload itself
MAX_ZIP_ENTRIES = 20_000  # a zip with more members than this is not a Takeout
MAX_CSV_BYTES = 4 * 1024 * 1024  # one subscriptions.csv, uncompressed
MAX_CHANNELS_PER_LIST = 5_000
MAX_PROFILES = 50

SUBSCRIPTIONS_CSV = "subscriptions.csv"
WATCH_HISTORY_HTML = "watch-history.html"
MAX_HISTORY_BYTES = 32 * 1024 * 1024  # one profile's watch history, uncompressed
_CHANNEL_ID = re.compile(r"^UC[A-Za-z0-9_-]{22}$")


class TakeoutError(ValueError):
    """The upload is not a usable Takeout export. The message is shown to the parent."""


# --- member classification ----------------------------------------------------


def _is_own_list(name: str) -> bool:
    """`subscriptions/subscriptions.csv`: the folder is named after the file."""
    p = PurePosixPath(name)
    return bool(p.parent.name) and p.parent.name.casefold() == p.stem.casefold()


def _is_subscriptions_csv(name: str, stems: set[str] | None = None) -> bool:
    """A candidate subscription CSV. See the module docstring for the rule."""
    p = PurePosixPath(name)
    if p.suffix.casefold() != ".csv":
        return False
    return p.name.casefold() == SUBSCRIPTIONS_CSV or _is_own_list(name) or (
        p.stem.casefold() in (stems or set())
    )


def _candidates(names: list[str]) -> list[str]:
    """The members that may be opened, in a stable order.

    Two passes so a localised export works: the first finds the own-list files
    (`<X>/<X>.csv`), which name the locale's word for "subscriptions"; the second
    admits the per-profile files that use that same word.
    """
    csvs = [n for n in names if PurePosixPath(n).suffix.casefold() == ".csv"]
    stems = {PurePosixPath(n).stem.casefold() for n in csvs if _is_own_list(n)}
    return sorted(n for n in csvs if _is_subscriptions_csv(n, stems))


def _profile_name(name: str) -> str:
    """`children/<Profile name>/subscriptions.csv` -> the profile name."""
    return PurePosixPath(name).parent.name


def _history_members(names: list[str], profiles: set[str]) -> dict[str, str]:
    """profile name -> its `watch-history.html`, for opted-in imports only.

    Two deliberate narrownesses:

    - The file name must be exactly `watch-history.html`. A localised export
      (`historique-de-visionnage.html`) therefore yields no history at all. That
      is the right way round: guessing which localised `.html` is the watch
      history risks opening the search history, which is never allowed.
    - The folder must be one of the child profiles we just read subscriptions
      for, which is what keeps the signed-in *parent's* own watch history — it
      sits in a `history/` folder of its own — out of this entirely.
    """
    out: dict[str, str] = {}
    for name in sorted(names):
        p = PurePosixPath(name)
        if p.name.casefold() == WATCH_HISTORY_HTML and p.parent.name in profiles:
            out[p.parent.name] = name
    return out


def _safe_member(name: str) -> bool:
    """Reject zip-slip: absolute paths, drive letters, and any `..` segment.

    Nothing here is ever written to disk, but a member that tries to escape its
    own tree says the archive is hostile, so the whole upload is refused.
    """
    if not name or name.startswith(("/", "\\")) or ":" in name.split("/")[0]:
        return False
    return ".." not in PurePosixPath(name.replace("\\", "/")).parts


# --- CSV -> channels ------------------------------------------------------------


def _decode(raw: bytes) -> str:
    """UTF-8 with or without a BOM; a mis-encoded export still parses."""
    try:
        return raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return raw.decode("latin-1")


def parse_subscriptions_csv(raw: bytes) -> list[TakeoutChannel]:
    """`Channel ID,Channel URL,Channel title` -> channels, deduped, in file order.

    Header rows, blank lines and localised column names are skipped by looking
    at the first cell rather than the header: a row counts only when it starts
    with a real channel id. `csv.reader` handles CRLF and quoted titles that
    contain commas.
    """
    out: list[TakeoutChannel] = []
    seen: set[str] = set()
    for row in csv.reader(io.StringIO(_decode(raw), newline="")):
        if not row:
            continue
        channel_id = row[0].strip()
        if not _CHANNEL_ID.match(channel_id) or channel_id in seen:
            continue
        seen.add(channel_id)
        url = row[1].strip() if len(row) > 1 else ""
        out.append(
            TakeoutChannel(
                channel_id=channel_id,
                title=(row[2].strip() if len(row) > 2 else "") or channel_id,
                url=url or f"https://www.youtube.com/channel/{channel_id}",
            )
        )
        if len(out) >= MAX_CHANNELS_PER_LIST:
            log.warning("subscriptions.csv truncated at %d channels", MAX_CHANNELS_PER_LIST)
            break
    return out


def _preview(named_csvs: list[tuple[str, bytes]]) -> TakeoutPreview:
    """Turn `(member path, csv bytes)` pairs into the preview shape."""
    profiles: list[TakeoutProfile] = []
    parent: TakeoutParentList | None = None
    for name, raw in named_csvs:
        channels = parse_subscriptions_csv(raw)
        if _is_own_list(name):
            merged = {c.channel_id: c for c in (parent.channels if parent else [])}
            merged.update({c.channel_id: c for c in channels})
            parent = TakeoutParentList(channel_count=len(merged), channels=list(merged.values()))
        elif len(profiles) < MAX_PROFILES:
            profiles.append(
                TakeoutProfile(
                    name=_profile_name(name) or "Profile",
                    channel_count=len(channels),
                    channels=channels,
                )
            )
    profiles.sort(key=lambda p: p.name.casefold())
    return TakeoutPreview(profiles=profiles, parent=parent)


# --- entry points ----------------------------------------------------------------


def parse_takeout_zip(data: bytes) -> TakeoutPreview:
    """Parse an uploaded Takeout zip. Raises `TakeoutError` on anything unusable.

    The default, and the only one the parent has not explicitly opted out of:
    watch history is never opened.
    """
    return _parse_zip(data, include_history=False)[0]


def parse_takeout_zip_with_history(data: bytes) -> tuple[TakeoutPreview, dict[str, HistoryAggregate]]:
    """The opt-in path (PROTOCOL.md "Watch history"). Same preview, plus one
    aggregate per child profile whose `watch-history.html` could be read.

    The file itself is not returned, kept or written anywhere: it is reduced to
    counts inside `history.parse_watch_history` and dropped with the zip.
    """
    return _parse_zip(data, include_history=True)


def _parse_zip(data: bytes, include_history: bool) -> tuple[TakeoutPreview, dict[str, HistoryAggregate]]:
    if not data:
        raise TakeoutError("the upload was empty")
    if len(data) > MAX_ZIP_BYTES:
        raise TakeoutError(
            f"the file is {len(data) // (1024 * 1024)} MB; the limit is "
            f"{MAX_ZIP_BYTES // (1024 * 1024)} MB. Export only 'YouTube and YouTube Music'."
        )
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as e:
        raise TakeoutError("that file is not a zip. Upload the .zip Google Takeout emailed you.") from e

    with zf:
        infos = zf.infolist()
        if len(infos) > MAX_ZIP_ENTRIES:
            raise TakeoutError(f"the zip has {len(infos)} entries; that is not a Takeout export.")
        for info in infos:
            if not _safe_member(info.filename):
                raise TakeoutError(f"the zip contains an unsafe path ({info.filename!r}); refusing it.")

        # Only subscription CSVs are opened here. Every history file is dropped
        # by name before a single byte of it is read; the opt-in pass below is
        # the one exception and it is narrower still.
        sizes = {i.filename: i.file_size for i in infos if not i.is_dir()}
        wanted = [n for n in _candidates(list(sizes)) if sizes[n] <= MAX_CSV_BYTES]
        if not wanted:
            raise TakeoutError(
                "no subscriptions.csv in that zip. In Takeout, choose 'YouTube and YouTube Music' "
                "and include the 'subscriptions' and 'children' categories."
            )
        named = [(n, zf.read(n)) for n in wanted]

        preview = _preview(named)
        histories: dict[str, HistoryAggregate] = {}
        if include_history:
            profiles = {p.name for p in preview.profiles}
            for profile, member in _history_members(list(sizes), profiles).items():
                if sizes[member] > MAX_HISTORY_BYTES:
                    log.warning("watch history for %r is %d bytes; skipped", profile, sizes[member])
                    continue
                aggregate = parse_watch_history(zf.read(member))
                if aggregate.videos:  # an unreadable file leaves no insight at all
                    histories[profile] = aggregate

    if not preview.profiles and preview.parent is None:
        raise TakeoutError("that zip has no readable subscriptions.")
    return preview, histories


def parse_takeout_dir(root: Path | str) -> TakeoutPreview:
    """Same parse over an already-unzipped export. Used by `scripts/` and the
    live check; the gateway only ever takes a zip."""
    root = Path(root)
    files = {p.relative_to(root).as_posix(): p for p in root.rglob("*") if p.is_file()}
    named = [
        (n, files[n].read_bytes())
        for n in _candidates(list(files))
        if files[n].stat().st_size <= MAX_CSV_BYTES
    ]
    if not named:
        raise TakeoutError(f"no subscriptions.csv under {root}")
    return _preview(named)
