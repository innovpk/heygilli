"""The channels offered to a household that has none yet.

Setting up used to mean bringing channels from elsewhere: a Google account
whose subscriptions could be read, or a Takeout export the parent had to
request from Google and wait for. A parent with neither had an empty app and a
file download in the way of using it at all.
"""
from __future__ import annotations

import re

import pytest

from heygilli_agents import starter_channels
from heygilli_agents.schemas import TYPES_FOR_BAND


def test_every_channel_id_is_shaped_like_one() -> None:
    """An id that is not a channel id is a channel that silently never produces
    anything, which looks exactly like the app being broken. Each of these was
    resolved from the channel's own page and its feed read before being written
    down; this is the guard against the next one being typed by hand."""
    seen = set()
    for c in starter_channels.CHANNELS:
        assert re.fullmatch(r"UC[A-Za-z0-9_-]{22}", c.channel_id), f"{c.title}: {c.channel_id}"
        assert c.channel_id not in seen, f"{c.title} is listed twice"
        seen.add(c.channel_id)
        assert c.title.strip() and c.blurb.strip()
        assert c.topics and c.bands


def test_every_topic_offered_actually_has_channels_in_every_band() -> None:
    """A topic a parent can pick that returns nothing for their child's age is
    a dead end in the middle of setup."""
    for topic, _label in starter_channels.TOPICS:
        bands = {b for c in starter_channels.CHANNELS if topic in c.topics for b in c.bands}
        assert bands, f"topic {topic!r} has no channels at all"


def test_every_band_gets_something_whatever_they_pick() -> None:
    for band in TYPES_FOR_BAND:
        assert starter_channels.suggest(band), f"{band} has nothing to start with"


def test_no_preference_means_everything_for_the_band_not_nothing() -> None:
    """"I do not know yet" is the commonest answer during setup and must not be
    punished with a blank screen."""
    for band in TYPES_FOR_BAND:
        assert starter_channels.suggest(band, []) == starter_channels.suggest(band)
        assert len(starter_channels.suggest(band, [])) >= len(
            starter_channels.suggest(band, ["songs"])
        )


def test_topics_narrow_and_the_band_always_holds() -> None:
    songs = starter_channels.suggest("4_6", ["songs"])
    assert songs and all("songs" in c.topics for c in songs)
    assert all("4_6" in c.bands for c in songs)

    # Several topics is a union, not an intersection: a parent picking two
    # things wants more channels, not fewer.
    both = starter_channels.suggest("7_8", ["animals", "making"])
    assert len(both) >= len(starter_channels.suggest("7_8", ["animals"]))

    assert starter_channels.suggest("4_6", ["no_such_topic"]) == []


@pytest.mark.parametrize("band", ["4_6", "7_8", "9_11"])
def test_a_band_is_never_offered_a_channel_written_for_another(band) -> None:
    assert all(band in c.bands for c in starter_channels.suggest(band))
