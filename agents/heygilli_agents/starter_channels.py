"""Channels to offer a household that has none yet.

Setting up used to mean bringing channels from somewhere else: a Google
account whose subscriptions could be read, or a Takeout export the parent had
to request from Google and wait for. A parent with neither had an empty app
and a file download standing between them and using it at all.

These are a starting point instead. The parent says which age band and which
kinds of things their child likes, gets the channels that match, and approves
them in one go — after which everything works exactly as before: the Curator
reads each upload against that household's own answers, and a channel being in
this list buys it nothing at screening time.

Two things this list is not:

  - **Not an endorsement.** These are places to start, chosen because they are
    widely watched, publish steadily, and are aimed at children. Whether any
    particular upload suits a particular child is what the Curator decides
    against what that family said, and the answer differs between families.
  - **Not a search.** HeyGilli never queries YouTube for videos; a search hands
    back the open internet and undoes the allowlist the whole product rests on
    (see `home` and `reviewer.gather_evidence`). This is a fixed list in the
    repository that a parent chooses from, which is a different thing.

Every id here was resolved from the channel's own page and its RSS feed read
before being written down. A wrong id is a channel that silently never
produces anything, which looks exactly like the app being broken.
"""
from __future__ import annotations

from pydantic import BaseModel

from .schemas import AgeBand

#: The kinds of thing a parent picks from. Deliberately few and concrete: this
#: is asked once, during setup, of somebody who wants to finish and get on.
Topic = str

TOPICS: tuple[tuple[Topic, str], ...] = (
    ("songs", "Songs and moving about"),
    ("stories", "Stories and picture books"),
    ("science", "Science and how things work"),
    ("animals", "Animals and nature"),
    ("making", "Drawing and making things"),
    ("school", "Letters, numbers and school subjects"),
)


class StarterChannel(BaseModel):
    channel_id: str
    title: str
    #: Why a parent might want it, in their words. One line.
    blurb: str
    topics: tuple[Topic, ...]
    bands: tuple[AgeBand, ...]


CHANNELS: tuple[StarterChannel, ...] = (
    # --- songs and movement -------------------------------------------------
    StarterChannel(
        channel_id="UC3wCAOfSB0W9iuKDDtNJeGw", title="Danny Go!",
        blurb="Songs that get them up and moving between videos.",
        topics=("songs",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UCLsooMJoIpl_7ux2jvdPB-Q", title="Super Simple Songs",
        blurb="Calm nursery songs, the same few over and over on purpose.",
        topics=("songs",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UC5uIZ2KOZZeQDQo_Gsi_qbQ", title="Cosmic Kids Yoga",
        blurb="Yoga told as a story. Quiet, and good before bed.",
        topics=("songs",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UC2YBT7HYqCbbvzu3kKZ3wnw", title="GoNoodle",
        blurb="Short bursts of dancing and stretching.",
        topics=("songs",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UCG2CL6EUjG8TVT1Tpl9nJdg", title="Ms Rachel",
        blurb="Slow, spoken-to-camera songs for the youngest watchers.",
        topics=("songs", "school"), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCe1VpF4wS_kdcjyTRSXBcnQ", title="The Singing Walrus",
        blurb="Counting and alphabet songs with a steady beat.",
        topics=("songs", "school"), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCVcQH8A634mauPrGbWs7QlQ", title="Jack Hartmann",
        blurb="Songs that teach letters and numbers by doing them.",
        topics=("songs", "school"), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCLy6-72NzYpFztbJ7jNEMkg", title="The Kiboomers",
        blurb="Nursery rhymes and seasonal songs.",
        topics=("songs",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCJkWoS4RsldA1coEIot5yDA", title="Mother Goose Club",
        blurb="Traditional rhymes, acted out.",
        topics=("songs",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCKAqou7V9FAWXpZd9xtOg3Q", title="Little Baby Bum",
        blurb="Animated nursery rhymes, long compilations.",
        topics=("songs",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UCwSf8jBhIOb58Tk78MZNnPg", title="Pinkfong",
        blurb="Baby Shark and the rest. Catchy, and repetitive by design.",
        topics=("songs",), bands=("4_6",),
    ),

    # --- stories ------------------------------------------------------------
    StarterChannel(
        channel_id="UCnBdzaRy-Ky9Vh54XJlFz1Q", title="Storyline Online",
        blurb="Picture books read aloud by actors, one book per video.",
        topics=("stories",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UCVzLLZkDuFGAE2BGdBuBNBg", title="Bluey",
        blurb="Clips from the show, mostly about a family playing.",
        topics=("stories",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UCoookXUzPciGrEZEXmh4Jjg", title="Sesame Street",
        blurb="Sketches and songs about feelings, letters and getting along.",
        topics=("stories", "school"), bands=("4_6",),
    ),

    # --- science and how things work ---------------------------------------
    StarterChannel(
        channel_id="UCRFIPG2u1DxKLNuE3y2SjHA", title="SciShow Kids",
        blurb="One question answered per video, gently and with props.",
        topics=("science",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UC5AN7XdQkLo6SO9_nI5Mk9Q", title="Free School",
        blurb="Art, history and nature explained plainly, no jokes.",
        topics=("science", "school"), bands=("7_8", "9_11"),
    ),
    StarterChannel(
        channel_id="UCONtPx56PSebXJOxbFv-2jQ", title="Crash Course Kids",
        blurb="Primary-school science, one idea at a time.",
        topics=("science", "school"), bands=("7_8", "9_11"),
    ),
    StarterChannel(
        channel_id="UCbprhISv-0ReKPPyhf7-Dtw", title="Science Max",
        blurb="School experiments done far bigger than at school.",
        topics=("science",), bands=("7_8", "9_11"),
    ),
    StarterChannel(
        channel_id="UCsooa4yRKGN_zEE8iknghZA", title="TED-Ed",
        blurb="Animated explanations. Aimed older; some are quite dense.",
        topics=("science",), bands=("9_11",),
    ),

    # --- animals ------------------------------------------------------------
    StarterChannel(
        channel_id="UCXVCgDuD_QCkI7gTKU7-tpg", title="Nat Geo Kids",
        blurb="Animal facts and footage from the magazine's children's arm.",
        topics=("animals", "science"), bands=("4_6", "7_8", "9_11"),
    ),
    StarterChannel(
        channel_id="UCINb0wqPz-A0dV9nARjJlOQ", title="The Dodo",
        blurb="Animal rescue stories. Warm, but some begin with an animal hurt.",
        topics=("animals",), bands=("7_8", "9_11"),
    ),

    # --- making things ------------------------------------------------------
    StarterChannel(
        channel_id="UC5XMF3Inoi8R9nSI8ChOsdQ", title="Art for Kids Hub",
        blurb="Draw-along videos a child can follow with paper and a pen.",
        topics=("making",), bands=("4_6", "7_8", "9_11"),
    ),

    # --- school subjects ----------------------------------------------------
    StarterChannel(
        channel_id="UCPlwvN0w4qFSP1FllALB92w", title="Numberblocks",
        blurb="Numbers as characters. Counting without it feeling like counting.",
        topics=("school",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UC_qs3c0ehDvZkbiEbOj6Drg", title="Alphablocks",
        blurb="Letters as characters, sounding words out together.",
        topics=("school",), bands=("4_6",),
    ),
    StarterChannel(
        channel_id="UC2ri4rEb8abnNwXvTjg5ARw", title="Khan Academy Kids",
        blurb="Early reading and maths from the Khan Academy people.",
        topics=("school",), bands=("4_6", "7_8"),
    ),
    StarterChannel(
        channel_id="UCJ5dVwsCLKlWuOZyi7WDwfw", title="BrainPOP",
        blurb="Short lessons across school subjects.",
        topics=("school",), bands=("7_8", "9_11"),
    ),
)


def suggest(band: AgeBand, topics: list[str] | tuple[str, ...] = ()) -> list[StarterChannel]:
    """Channels for this band, narrowed to these topics when any are given.

    The band is a filter and the topics are a preference: a parent who picks
    nothing gets everything written for their child's age rather than an empty
    list, because "I do not know yet" is the commonest answer during setup and
    should not be punished with a blank screen.
    """
    for_band = [c for c in CHANNELS if band in c.bands]
    wanted = {t for t in topics if t}
    if not wanted:
        return for_band
    return [c for c in for_band if wanted.intersection(c.topics)]
