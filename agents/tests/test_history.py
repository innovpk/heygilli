"""Watch history: opt-in, aggregate, discarded (PROTOCOL.md).

Offline. Every fixture is invented: made-up channel ids, made-up channel names,
and video titles chosen to be unmistakable if one ever escaped.

The claim this file exists to enforce is the one in the protocol and in our
public docs: **no video title from a history import is ever persisted, and none
is ever sent to a model**. `test_takeout.py` proves the default — that history
is not even opened — by spying on `ZipFile.open`. This file proves the opt-in
path by spying on the store's own `put`, which every write in the service goes
through, and by reading back every byte the store wrote to disk.
"""
from __future__ import annotations

import io
import json
import tracemalloc
import zipfile
from typing import Any

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, history
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import HistoryAggregate, HistoryChannelCount, Kid
from heygilli_agents.store import LocalStore
from heygilli_agents.takeout import parse_takeout_zip, parse_takeout_zip_with_history
from tests.test_takeout import ID_A, ID_B, ID_C, csv_bytes, make_zip, row

# Titles that could not possibly appear by accident. If one of these turns up in
# the store or in a prompt, the promise is broken and the test says so.
TITLES = ["SECRET TITLE ALPHA", "SECRET TITLE BRAVO", "SECRET TITLE CHARLIE"]
VIDEO_IDS = ["vidsecret01", "vidsecret02", "vidsecret03"]


def entry(title: str, video_id: str, channel_id: str, channel: str, when: str) -> str:
    """One watched video in the shape Takeout writes it: the video's own anchor
    first, the channel's second, then the timestamp."""
    return (
        '<div class="outer-cell mdl-cell mdl-cell--12-col mdl-shadow--2dp"><div class="mdl-grid">'
        '<div class="header-cell mdl-cell mdl-cell--12-col"><p>YouTube</p></div>'
        '<div class="content-cell mdl-cell mdl-cell--6-col mdl-typography--body-1">'
        f'Watched&nbsp;<a href="https://www.youtube.com/watch?v={video_id}">{title}</a><br>'
        f'<a href="https://www.youtube.com/channel/{channel_id}">{channel}</a><br>'
        f"{when}</div></div></div>"
    )


def watch_history_html(entries: list[str] | None = None) -> str:
    body = entries if entries is not None else [
        # Two from a channel the child follows, three from one nobody chose.
        entry(TITLES[0], VIDEO_IDS[0], ID_A, "Sprout Science", "Sep 4, 2026, 4:12:33&#8239;PM PKT"),
        entry(TITLES[1], VIDEO_IDS[1], ID_A, "Sprout Science", "Sep 3, 2026, 5:01:00&#8239;PM PKT"),
        entry(TITLES[2], VIDEO_IDS[2], ID_C, "Rec &amp; Co", "Aug 30, 2026, 5:40:00&#8239;PM PKT"),
        entry("SECRET TITLE DELTA", "vidsecret04", ID_C, "Rec &amp; Co",
              "Aug 30, 2026, 6:02:00&#8239;PM PKT"),
        entry("SECRET TITLE ECHO", "vidsecret05", ID_C, "Rec &amp; Co",
              "Aug 29, 2026, 4:55:00&#8239;PM PKT"),
    ]
    return "<html><body><h1>Watch history</h1>" + "".join(body) + "</body></html>"


def takeout_with_history(profile: str = "Ayaan") -> bytes:
    """A realistic export with one child profile, its watch history, and the
    search history that must never be opened whatever the parent ticked."""
    yt = "YouTube and YouTube Music"
    return make_zip({
        f"Takeout/{yt}/subscriptions/subscriptions.csv": csv_bytes(row(ID_B, "Parent Follows This")),
        f"Takeout/{yt}/children/{profile}/subscriptions.csv": csv_bytes(row(ID_A, "Sprout Science")),
        f"Takeout/{yt}/children/{profile}/watch-history.html": watch_history_html().encode(),
        f"Takeout/{yt}/children/{profile}/search-history.html": b"<html>SECRET SEARCHES</html>",
        f"Takeout/{yt}/history/watch-history.html": b"<html>THE PARENTS OWN HISTORY</html>",
    })


# --- the parse ----------------------------------------------------------------


class TestOneFileBecomesCounts:
    def test_entries_are_counted_by_channel_and_by_hour(self) -> None:
        agg = history.parse_watch_history(watch_history_html())

        assert agg.videos == 5 and agg.attributed == 5
        assert [(c.title, c.videos) for c in agg.channels] == [("Rec & Co", 3), ("Sprout Science", 2)]
        assert agg.first_watched == "2026-08-29" and agg.last_watched == "2026-09-04"
        assert (agg.by_hour[16], agg.by_hour[17], agg.by_hour[18]) == (2, 2, 1), "the export's own clock"
        assert sum(agg.by_hour) == 5

    def test_nothing_a_title_could_hide_in_comes_out(self) -> None:
        """The shape itself is the guarantee: there is nowhere in a
        `HistoryAggregate` to put a title, so this is checked on the whole
        serialised object rather than field by field."""
        blob = history.parse_watch_history(watch_history_html()).model_dump_json()

        for title in [*TITLES, "SECRET TITLE DELTA", "SECRET TITLE ECHO"]:
            assert title not in blob
        for video_id in VIDEO_IDS:
            assert video_id not in blob

    def test_a_removed_video_is_counted_but_attributed_to_nobody(self) -> None:
        """"Watched a video that has been removed" has no channel. It still
        happened, so it counts as watching, but it cannot count for or against
        the share that came from channels the child follows."""
        removed = (
            '<div class="outer-cell"><div class="content-cell">'
            "Watched a video that has been removed<br>Sep 1, 2026, 3:00:00 PM PKT</div></div>"
        )
        agg = history.parse_watch_history(watch_history_html([removed]))

        assert agg.videos == 1 and agg.attributed == 0 and agg.channels == []

    def test_a_channel_name_with_an_entity_in_it_is_read_as_text(self) -> None:
        agg = history.parse_watch_history(watch_history_html())
        assert any(c.title == "Rec & Co" for c in agg.channels)

    def test_a_non_english_date_costs_the_date_not_the_count(self) -> None:
        """Google localises the timestamp. A guessed date on a screen a parent
        makes decisions from is worse than an honest gap."""
        localised = entry("t", "v1", ID_A, "Sprout Science", "4 septembre 2026 à 16:12:33")
        agg = history.parse_watch_history(watch_history_html([localised]))

        assert agg.videos == 1 and agg.channels[0].videos == 1
        assert agg.first_watched is None and sum(agg.by_hour) == 0

    def test_an_empty_or_junk_file_yields_nothing_rather_than_an_error(self) -> None:
        assert history.parse_watch_history("").videos == 0
        assert history.parse_watch_history("<html>not a history at all</html>").videos == 0

    def test_a_huge_file_is_truncated_rather_than_refused(self) -> None:
        many = [entry("t", "v", ID_A, "Sprout Science", "Sep 4, 2026, 4:12:33 PM PKT")] * 10
        agg = history.parse_watch_history(watch_history_html(many), max_entries=4)
        assert agg.videos == 4


    def test_the_same_file_reads_the_same_as_bytes_or_as_text(self) -> None:
        """The file arrives from the zip as bytes and is read as bytes. A test
        that passes a string must be reading the same history the gateway does."""
        html = watch_history_html()
        as_text = history.parse_watch_history(html)
        as_bytes = history.parse_watch_history(html.encode())

        assert as_bytes.model_dump() == as_text.model_dump()

    def test_reading_a_big_file_does_not_cost_another_copy_of_it(self) -> None:
        """A real watch history is tens of megabytes and the instance has 512.
        Decoding the whole file and splitting it into a list of blocks cost two
        more copies of it, the first of them double size for a non-Latin
        export; that is what took the gateway over its memory limit. What the
        parse allocates now is one entry at a time."""
        one = entry("t", "v1", ID_A, "القناة العربية", "Sep 4, 2026, 4:12:33 PM PKT")
        raw = watch_history_html([one] * 4000).encode()

        tracemalloc.start()
        try:
            agg = history.parse_watch_history(raw)
            _, peak = tracemalloc.get_traced_memory()
        finally:
            tracemalloc.stop()

        assert agg.videos == 4000
        assert peak < len(raw) // 4, f"{peak} bytes for a {len(raw)} byte file"


# --- the zip ------------------------------------------------------------------


class TestHistoryIsOnlyReadWhenTheParentAsked:
    def test_the_default_still_opens_nothing_but_subscription_csvs(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The opt-in must not have widened the default by accident, so this is
        the same spy `test_takeout.py` uses, run against a zip that does contain
        a watch history."""
        data = takeout_with_history()
        opened: list[str] = []
        real_open = zipfile.ZipFile.open

        def spy(self, name, *a, **k):
            opened.append(name.filename if hasattr(name, "filename") else str(name))
            return real_open(self, name, *a, **k)

        monkeypatch.setattr(zipfile.ZipFile, "open", spy)
        parse_takeout_zip(data)

        assert opened and all(o.endswith("subscriptions.csv") for o in opened), opened

    def test_opting_in_opens_the_watch_history_and_nothing_else(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Search history is never in scope, whatever the parent ticked, and
        neither is the signed-in parent's own watch history: only a child
        profile folder's file is read."""
        data = takeout_with_history()
        opened: list[str] = []
        real_open = zipfile.ZipFile.open

        def spy(self, name, *a, **k):
            opened.append(name.filename if hasattr(name, "filename") else str(name))
            return real_open(self, name, *a, **k)

        monkeypatch.setattr(zipfile.ZipFile, "open", spy)
        preview, histories = parse_takeout_zip_with_history(data)

        assert [p.name for p in preview.profiles] == ["Ayaan"]
        assert set(histories) == {"Ayaan"} and histories["Ayaan"].videos == 5
        assert not any("search-history" in o for o in opened), opened
        assert not any(o.endswith("history/watch-history.html") for o in opened), (
            "that one is the parent's own history, not a child's"
        )

    def test_a_localised_history_file_is_left_alone_rather_than_guessed_at(self) -> None:
        """Guessing which localised `.html` is the watch history risks opening
        the search history. Losing the feature in French is the better failure."""
        yt = "YouTube et YouTube Music"
        data = make_zip({
            f"Takeout/{yt}/abonnements/abonnements.csv": csv_bytes(row(ID_B, "Parent")),
            f"Takeout/{yt}/enfants/Ayaan/abonnements.csv": csv_bytes(row(ID_A, "Kid")),
            f"Takeout/{yt}/enfants/Ayaan/historique-de-visionnage.html": watch_history_html().encode(),
        })
        _, histories = parse_takeout_zip_with_history(data)
        assert histories == {}

    def test_an_unreadable_history_leaves_no_insight_at_all(self) -> None:
        yt = "YouTube and YouTube Music"
        data = make_zip({
            f"Takeout/{yt}/children/Ayaan/subscriptions.csv": csv_bytes(row(ID_A, "Sprout Science")),
            f"Takeout/{yt}/children/Ayaan/watch-history.html": b"<html>nothing parseable</html>",
        })
        assert parse_takeout_zip_with_history(data)[1] == {}


# --- the aggregate a parent reads ---------------------------------------------


def aggregate() -> HistoryAggregate:
    return HistoryAggregate(
        videos=10, attributed=10, first_watched="2026-08-01", last_watched="2026-09-04",
        by_hour=[0] * 16 + [6, 4] + [0] * 6,
        channels=[
            HistoryChannelCount(channel_id=ID_C, title="Rec & Co", videos=7),
            HistoryChannelCount(channel_id=ID_A, title="Sprout Science", videos=3),
        ],
    )


class TestUnsubscribedShareIsTheNumberThatMatters:
    def test_it_measures_what_the_recommender_chose(self) -> None:
        """A child whose watching is mostly from channels nobody chose is being
        fed by the recommender rather than by their own subscriptions."""
        insight = history.build_insight("kid_1", aggregate(), subscribed={ID_A})

        assert insight.unsubscribed_share == 0.7
        assert [(c.title, c.subscribed) for c in insight.top_channels] == [
            ("Rec & Co", False), ("Sprout Science", True),
        ]

    def test_a_child_who_only_watches_what_they_follow_scores_zero(self) -> None:
        insight = history.build_insight("kid_1", aggregate(), subscribed={ID_A, ID_C})
        assert insight.unsubscribed_share == 0.0

    def test_videos_with_no_channel_do_not_skew_the_share(self) -> None:
        agg = aggregate().model_copy(update={"videos": 20, "attributed": 10})
        assert history.build_insight("kid_1", agg, {ID_A}).unsubscribed_share == 0.7

    def test_top_channels_is_capped_at_twenty(self) -> None:
        agg = HistoryAggregate(videos=30, attributed=30, channels=[
            HistoryChannelCount(channel_id=f"UC{i:022d}", title=f"Channel {i}", videos=1)
            for i in range(30)
        ])
        assert len(history.build_insight("kid_1", agg).top_channels) == 20


class TestTheSummarySaysWhatTheNumbersShow:
    def test_the_numbers_only_summary_stands_on_its_own(self) -> None:
        insight = history.build_insight("kid_1", aggregate(), subscribed={ID_A})
        assert "10 videos" in insight.summary
        assert "70%" in insight.summary and "does not follow" in insight.summary
        assert "4pm and 7pm" in insight.summary

    def test_a_flat_day_claims_no_pattern(self) -> None:
        assert history.peak_hours([1] * 24) is None
        assert history.peak_hours([0] * 24) is None

    def test_the_model_is_given_channel_names_and_never_a_title(self) -> None:
        """PROTOCOL.md: only channel names are ever sent to a model. Built from
        a real parse so this covers the whole path, not a hand-made object."""
        agg = history.parse_watch_history(watch_history_html())
        insight = history.build_insight("kid_1", agg, subscribed={ID_A})
        prompt = history.summary_prompt(insight, Kid(household_id="hh", nickname="Abu", age=8))

        assert "Sprout Science" in prompt and "Rec & Co" in prompt
        for title in [*TITLES, "SECRET TITLE DELTA"]:
            assert title not in prompt

    def test_a_provider_failure_falls_back_to_the_numbers(self) -> None:
        def boom(_model_name: str, _text: str) -> dict[str, Any]:
            raise RuntimeError("provider is down")

        insight = history.build_insight("kid_1", aggregate(), subscribed={ID_A})
        text = history.write_summary(insight, Kid(household_id="hh", nickname="Abu", age=8),
                                     make_agent("digest", "s", model=FakeModel(boom)))

        assert text == history.plain_summary(insight)

    def test_a_summary_the_model_padded_out_is_refused(self) -> None:
        def waffle(model_name: str, _text: str) -> dict[str, Any]:
            return {"summary": "x " * history.MAX_SUMMARY_CHARS} if model_name == "HistorySummary" else {}

        insight = history.build_insight("kid_1", aggregate(), subscribed={ID_A})
        text = history.write_summary(insight, Kid(household_id="hh", nickname="Abu", age=8),
                                     make_agent("digest", "s", model=FakeModel(waffle)))

        assert text == history.plain_summary(insight)

    def test_nothing_watched_means_no_model_call_at_all(self) -> None:
        model = FakeModel()
        insight = history.build_insight("kid_1", HistoryAggregate())
        text = history.write_summary(insight, Kid(household_id="hh", nickname="Abu", age=8),
                                     make_agent("digest", "s", model=model))

        assert model.calls == []
        assert "No watching" in text


# --- the endpoints, end to end ------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "History Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


def upload(client: TestClient, auth: dict, include_history: bool) -> dict:
    return client.post(
        "/import/takeout",
        files={"file": ("takeout.zip", takeout_with_history(), "application/zip")},
        data={"include_history": str(include_history).lower()},
        headers=hdr(auth),
    ).json()


def import_profile(client: TestClient, auth: dict, kid_id: str, profile: str = "Ayaan"):
    return client.post(
        f"/kids/{kid_id}/channels/import",
        json={"channel_ids": [ID_A], "profile": profile},
        headers=hdr(auth),
    )


@pytest.fixture
def kid_id(client: TestClient, auth: dict) -> str:
    return client.post("/kids", json={"nickname": "Ayaan", "age": 8}, headers=hdr(auth)).json()["id"]


class TestTheOptInFlow:
    def test_without_the_tick_there_is_no_history_to_read(
        self, client: TestClient, auth: dict, kid_id: str
    ) -> None:
        """A household that never opts in has no HistoryInsight, and asking for
        one is a 404 rather than an empty object."""
        upload(client, auth, include_history=False)
        import_profile(client, auth, kid_id)

        assert client.get(f"/kids/{kid_id}/history", headers=hdr(auth)).status_code == 404

    def test_opting_in_and_mapping_the_profile_to_a_kid(
        self, client: TestClient, auth: dict, kid_id: str
    ) -> None:
        assert upload(client, auth, include_history=True)["profiles"][0]["name"] == "Ayaan"
        # Until the parent says which kid the profile is, nothing is tied to a child.
        assert client.get(f"/kids/{kid_id}/history", headers=hdr(auth)).status_code == 404

        import_profile(client, auth, kid_id)
        body = client.get(f"/kids/{kid_id}/history", headers=hdr(auth)).json()

        assert body["kid_id"] == kid_id and body["source"] == "takeout"
        assert body["videos"] == 5
        assert body["first_watched"] == "2026-08-29" and body["last_watched"] == "2026-09-04"
        assert body["unsubscribed_share"] == 0.6, "three of five came from a channel nobody chose"
        assert [c["title"] for c in body["top_channels"]] == ["Rec & Co", "Sprout Science"]
        assert [c["subscribed"] for c in body["top_channels"]] == [False, True]
        assert len(body["by_hour"]) == 24 and body["summary"]

    def test_the_pending_aggregate_is_used_once_and_then_gone(
        self, client: TestClient, auth: dict, kid_id: str, store: LocalStore
    ) -> None:
        """An import the parent abandons leaves counts under a profile name and
        nothing tied to a child; attaching consumes them."""
        upload(client, auth, include_history=True)
        assert store.get_pending_history(auth["_hid"], "Ayaan") is not None

        import_profile(client, auth, kid_id)
        assert store.get_pending_history(auth["_hid"], "Ayaan") is None

    def test_deleting_it_is_one_call(self, client: TestClient, auth: dict, kid_id: str) -> None:
        upload(client, auth, include_history=True)
        import_profile(client, auth, kid_id)

        assert client.delete(f"/kids/{kid_id}/history", headers=hdr(auth)).json() == {"deleted": True}
        assert client.get(f"/kids/{kid_id}/history", headers=hdr(auth)).status_code == 404
        # Deleting something that is not there is not an error: it is already gone.
        assert client.delete(f"/kids/{kid_id}/history", headers=hdr(auth)).json() == {"deleted": False}

    def test_history_endpoints_need_auth_and_a_real_kid(
        self, client: TestClient, auth: dict
    ) -> None:
        assert client.get("/kids/kid_nope/history", headers=hdr(auth)).status_code == 404
        assert client.get("/kids/kid_nope/history").status_code == 401
        assert client.delete("/kids/kid_nope/history").status_code == 401

    def test_no_video_title_is_ever_written_anywhere(
        self, client: TestClient, auth: dict, kid_id: str, store: LocalStore,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """The claim in PROTOCOL.md and in our public docs, enforced rather than
        promised.

        `Store.put` is the single primitive every write in the service goes
        through, so watching it catches a title persisted by any route: the
        import, the attach, the background summary, the curation that an import
        kicks off. The files on disk are then read back as a second, independent
        check that nothing arrived by some path that is not `put`.
        """
        written: list[str] = []
        real_put = LocalStore.put

        def spy(self, household, entity, item_id, data):
            written.append(json.dumps({"entity": entity, "id": item_id, "data": data},
                                      ensure_ascii=False))
            return real_put(self, household, entity, item_id, data)

        monkeypatch.setattr(LocalStore, "put", spy)

        upload(client, auth, include_history=True)
        import_profile(client, auth, kid_id)
        client.get(f"/kids/{kid_id}/history", headers=hdr(auth))

        assert written, "the flow wrote nothing at all, so this proves nothing"
        assert any("history" in w for w in written), "the aggregate itself must have been written"
        blob = "\n".join(written)
        on_disk = "\n".join(p.read_text() for p in store.root.rglob("*.json"))
        for secret in [*TITLES, "SECRET TITLE DELTA", "SECRET TITLE ECHO", *VIDEO_IDS]:
            assert secret not in blob, f"{secret!r} reached the store"
            assert secret not in on_disk, f"{secret!r} is on disk"


def test_a_zip_of_only_history_is_still_refused(client: TestClient, auth: dict) -> None:
    """History is never a reason to accept an export on its own: without a
    subscriptions CSV there is no profile to attribute it to."""
    yt = "YouTube and YouTube Music"
    data = make_zip({f"Takeout/{yt}/children/Ayaan/watch-history.html": watch_history_html().encode()})
    r = client.post("/import/takeout", files={"file": ("t.zip", data, "application/zip")},
                    data={"include_history": "true"}, headers=hdr(auth))
    assert r.status_code == 400


def test_the_uploaded_zip_itself_is_never_kept(
    client: TestClient, auth: dict, store: LocalStore
) -> None:
    """The file is discarded with the request. What survives is counts."""
    upload(client, auth, include_history=True)
    for path in store.root.rglob("*"):
        assert path.suffix not in (".zip", ".html"), path
    with zipfile.ZipFile(io.BytesIO(takeout_with_history())) as z:
        raw = z.read("Takeout/YouTube and YouTube Music/children/Ayaan/watch-history.html")
    assert raw not in b"".join(p.read_bytes() for p in store.root.rglob("*.json"))
