#!/usr/bin/env python3
"""Check every suggested channel is the channel we say it is.

The list is hand-written channel ids, and two of them were wrong. "Free
School" pointed at a different channel of the same name that posts
motivational-quote compilations, so a parent who asked for science was offered
Vivekananda and Gandhi quotes. "Pinkfong" pointed at a repost account calling
itself pinkfongbabyshark, whose uploads include a "CRAZY GHOST REMIX" and a
"horror video" — offered to four-year-olds.

Neither could be caught by reading the file: the ids look fine and the titles
read correctly. Only the live feed says what a channel actually is, so this
asks it. Run it when the list changes, and now and then regardless — a channel
can be sold or repurposed without its id changing.

    python scripts/verify_starter_channels.py
"""
from __future__ import annotations

import concurrent.futures as cf
import html
import re
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from heygilli_agents.starter_channels import CHANNELS  # noqa: E402

FEED = "https://www.youtube.com/feeds/videos.xml?channel_id={}"


def fetch(channel_id: str) -> tuple[str, list[str]]:
    with urllib.request.urlopen(FEED.format(channel_id), timeout=30) as r:
        xml = r.read().decode("utf-8", "replace")
    title = re.search(r"<title>(.*?)</title>", xml)
    uploads = re.findall(r"<media:title>(.*?)</media:title>", xml)
    return html.unescape(title.group(1) if title else ""), [html.unescape(u) for u in uploads[:5]]


def _key(name: str) -> str:
    """A name reduced to what identifies it: letters and digits, lowercased."""
    return re.sub(r"[^a-z0-9]+", "", name.lower())


def check(channel) -> tuple[bool, str]:
    try:
        real, uploads = fetch(channel.channel_id)
    except Exception as e:  # noqa: BLE001 - a channel that will not answer is a finding
        return False, f"{channel.title}: feed would not load ({type(e).__name__})"
    # Not equality: official names carry suffixes we do not want in the app
    # ("GoNoodle | Get Moving"), curly apostrophes, and spacing of their own
    # ("StorylineOnline"). One name has to contain the other once both are
    # stripped to letters and digits, which still catches an id pointing
    # somewhere else entirely while ignoring how the name is typed.
    a, b = _key(channel.title), _key(real)
    if a not in b and b not in a:
        listed = "\n      ".join(uploads)
        return False, f"{channel.title!r} is really {real!r}\n      {listed}"
    return True, f"{channel.title} -> {real}"


def main() -> int:
    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(check, CHANNELS))
    bad = [msg for ok, msg in results if not ok]
    for ok, msg in results:
        print(("  ok  " if ok else "  BAD ") + msg)
    print(f"\n{len(results) - len(bad)}/{len(results)} verified")
    if bad:
        print("\nWrong or unreachable:")
        for msg in bad:
            print("  - " + msg)
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
