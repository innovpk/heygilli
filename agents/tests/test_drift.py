"""Channel drift: a channel is not what it was (PROTOCOL.md).

Offline. The two claims worth holding this feature to are that a parent is only
interrupted when something actually got worse, and that being interrupted is all
that happens: **HeyGilli never removes a channel by itself**, whatever the
review now says and whichever button the parent taps on the card.
"""
from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import drift, gateway
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import Channel, ChannelReview, ChannelSnapshot, ReviewFlag
from heygilli_agents.store import LocalStore

CHANNEL = "UCdrift0000000000000000"


def days_ago(n: int) -> str:
    return (datetime.now(UTC) - timedelta(days=n)).isoformat(timespec="seconds")


def review(
    verdict: str = "good",
    flags: tuple[str, ...] = (),
    titles: tuple[str, ...] = ("Counting to Ten", "Colours of the Rainbow"),
    reviewed_days_ago: int = 30,
    title: str = "Sprout Science",
) -> ChannelReview:
    return ChannelReview(
        channel_id=CHANNEL, title=title, verdict=verdict,
        summary="Short science explainers.",
        flags=[ReviewFlag(kind=k, note=f"saw {k}") for k in flags],
        sample_titles=list(titles), reviewed_at=days_ago(reviewed_days_ago), model="fake",
    )


def snap(verdict: str, *flags: str) -> ChannelSnapshot:
    return ChannelSnapshot(verdict=verdict, flags=[ReviewFlag(kind=k) for k in flags],
                           reviewed_at=days_ago(1))


# --- what counts as worse -----------------------------------------------------


class TestOnlyARealDeclineCountsAsWorse:
    @pytest.mark.parametrize(("before", "after"), [("good", "mixed"), ("good", "concern"),
                                                   ("mixed", "concern")])
    def test_a_verdict_moving_toward_concern_is_worse(self, before: str, after: str) -> None:
        assert drift.got_worse(snap(before), snap(after)) is True

    @pytest.mark.parametrize(("before", "after"), [("concern", "good"), ("mixed", "good"),
                                                   ("good", "good")])
    def test_a_channel_that_improved_or_stayed_put_is_not(self, before: str, after: str) -> None:
        """PROTOCOL.md: a channel that improved is not something anyone needs to
        be interrupted about."""
        assert drift.got_worse(snap(before), snap(after)) is False

    def test_a_new_flag_is_worse_even_when_the_verdict_holds(self) -> None:
        assert drift.got_worse(snap("mixed"), snap("mixed", "ads_or_merch")) is True

    def test_a_flag_that_was_already_there_is_not_news(self) -> None:
        assert drift.got_worse(snap("mixed", "ads_or_merch"), snap("mixed", "ads_or_merch")) is False

    def test_a_flag_going_away_is_not_worse(self) -> None:
        assert drift.got_worse(snap("mixed", "ads_or_merch", "scary"), snap("mixed", "scary")) is False

    @pytest.mark.parametrize(("before", "after"), [("good", "unknown"), ("unknown", "concern"),
                                                   ("unknown", "unknown")])
    def test_unknown_on_either_side_is_never_drift(self, before: str, after: str) -> None:
        """A channel whose feed could not be read tells us nothing about whether
        it changed. Interrupting a parent over an unreachable channel would
        teach them to ignore the inbox."""
        assert drift.got_worse(snap(before), snap(after)) is False


class TestTheComparisonItself:
    def test_the_evidence_is_the_uploads_that_are_actually_new(self) -> None:
        was = review(titles=("Counting to Ten", "Colours of the Rainbow"))
        now = review(verdict="concern", flags=("ads_or_merch",),
                     titles=("Counting to Ten", "MY NEW BETTING SPONSOR", "Free Spins Explained"),
                     reviewed_days_ago=0)
        d = drift.compare(was, now)

        assert d.worse is True
        assert d.sample_titles == ["MY NEW BETTING SPONSOR", "Free Spins Explained"]
        assert d.was.verdict == "good" and d.now.verdict == "concern"
        assert d.was.reviewed_at == was.reviewed_at, "the parent can see when each was read"

    def test_with_no_new_uploads_the_evidence_is_what_was_read_this_time(self) -> None:
        was = review(titles=("A", "B"))
        now = review(verdict="mixed", titles=("A", "B"), reviewed_days_ago=0)
        assert drift.compare(was, now).sample_titles == ["A", "B"]

    def test_the_sentence_from_the_diff_names_the_change_and_nothing_else(self) -> None:
        text = drift.describe_change(snap("good"), snap("concern", "ads_or_merch", "scary"))

        assert "good to concern" in text
        assert "ads or merch" in text and "scary" in text

    def test_a_change_with_no_verdict_or_flag_movement_still_reads_honestly(self) -> None:
        assert "changed" in drift.describe_change(snap("good"), snap("good"))


class TestTheSentenceTheParentReads:
    def test_the_model_writes_it_when_it_can(self) -> None:
        def canned(model_name: str, _text: str) -> dict[str, Any]:
            return {"what_changed": "It has started running betting sponsorships."} \
                if model_name == "DriftNote" else {}

        d = drift.compare(review(), review(verdict="concern", reviewed_days_ago=0))
        assert drift.write_note(d, make_agent("reviewer", "s", model=FakeModel(canned))) == (
            "It has started running betting sponsorships."
        )

    def test_a_provider_failure_leaves_the_sentence_from_the_diff_standing(self) -> None:
        def boom(_model_name: str, _text: str) -> dict[str, Any]:
            raise RuntimeError("provider is down")

        d = drift.compare(review(), review(verdict="concern", reviewed_days_ago=0))
        assert drift.write_note(d, make_agent("reviewer", "s", model=FakeModel(boom))) == d.what_changed
        assert "good to concern" in d.what_changed

    def test_an_empty_or_rambling_sentence_is_refused(self) -> None:
        def waffle(model_name: str, _text: str) -> dict[str, Any]:
            return {"what_changed": "x " * drift.MAX_NOTE_CHARS} if model_name == "DriftNote" else {}

        d = drift.compare(review(), review(verdict="concern", reviewed_days_ago=0))
        assert drift.write_note(d, make_agent("reviewer", "s", model=FakeModel(waffle))) == d.what_changed

    def test_the_prompt_carries_both_snapshots_and_the_new_titles(self) -> None:
        d = drift.compare(review(), review(verdict="concern", flags=("scary",),
                                           titles=("A HORROR SPECIAL",), reviewed_days_ago=0))
        prompt = drift.note_prompt(d)

        assert "good" in prompt and "concern" in prompt and "scary" in prompt
        assert "A HORROR SPECIAL" in prompt


# --- the weekly limit ---------------------------------------------------------


class TestOnceAWeekAtMost:
    def test_a_channel_reviewed_this_week_is_not_due(self, store: LocalStore) -> None:
        assert drift.due_for_recheck(review(reviewed_days_ago=2), store) is False
        assert drift.due_for_recheck(review(reviewed_days_ago=8), store) is True

    def test_a_channel_that_was_never_reviewed_is_not_due(self, store: LocalStore) -> None:
        """There is nothing to drift from, so nothing to check."""
        assert drift.due_for_recheck(None, store) is False

    def test_the_limit_holds_even_when_the_re_read_produced_nothing(self, store: LocalStore) -> None:
        """A re-read that came back unknown leaves the old review in place, so
        `reviewed_at` alone would say "due" again on the very next poll. The
        check has its own record for exactly this."""
        old = review(reviewed_days_ago=30)
        assert drift.due_for_recheck(old, store) is True

        drift.mark_checked(CHANNEL, store)
        assert drift.due_for_recheck(old, store) is False


# --- the endpoint -------------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Drift Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}", "_hid": body["household_id"]}


def hdr(auth: dict) -> dict:
    return {"Authorization": auth["Authorization"]}


@pytest.fixture
def kid_with_channel(client: TestClient, auth: dict, store: LocalStore) -> str:
    kid = client.post("/kids", json={"nickname": "Abu", "age": 8}, headers=hdr(auth)).json()
    store.put_channel(auth["_hid"], kid["id"], Channel(id=CHANNEL, title="Sprout Science"))
    return kid["id"]


def feed(*titles: str):
    """A stand-in for the channel's RSS feed, which is the Reviewer's only evidence."""
    return lambda channel_id, limit=12: {
        "title": "Sprout Science",
        "uploads": [{"title": t, "description": ""} for t in titles],
    }


def worse_review(model_name: str, _text: str) -> dict[str, Any]:
    if model_name == "ChannelReviewDraft":
        return {"verdict": "concern", "summary": "Now mostly betting promos.",
                "flags": [{"kind": "ads_or_merch", "note": "several betting sponsors"}],
                "good_for": []}
    if model_name == "DriftNote":
        return {"what_changed": "It has started running betting sponsorships."}
    return {}


def check(client: TestClient, auth: dict) -> dict:
    return client.post("/channels/drift/check", json={"channel_ids": [CHANNEL]},
                       headers=hdr(auth)).json()


class TestTheDriftCheckEndpoint:
    def test_a_channel_read_recently_is_answered_from_cache(
        self, client: TestClient, auth: dict, store: LocalStore, monkeypatch
    ) -> None:
        """`checked` is how many were actually re-read. A parent polling this
        screen must not cost one model call per channel per poll."""
        store.put_channel_review(CHANNEL, review(reviewed_days_ago=1).model_dump())
        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed", feed("Anything"))

        assert check(client, auth) == {"drifted": [], "checked": 0}

    def test_a_never_reviewed_channel_is_not_checked(self, client: TestClient, auth: dict) -> None:
        assert check(client, auth) == {"drifted": [], "checked": 0}

    def test_a_channel_that_got_worse_is_reported_and_reaches_the_inbox(
        self, client: TestClient, auth: dict, store: LocalStore, kid_with_channel: str, monkeypatch
    ) -> None:
        store.put_channel_review(CHANNEL, review(reviewed_days_ago=30).model_dump())
        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed",
                            feed("Free Spins Explained", "Betting Tips Live", "Counting to Ten"))
        monkeypatch.setattr("heygilli_agents.reviewer.reviewer_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))
        monkeypatch.setattr(drift, "drift_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))

        body = check(client, auth)

        assert body["checked"] == 1 and len(body["drifted"]) == 1
        d = body["drifted"][0]
        assert d["channel_id"] == CHANNEL and d["worse"] is True
        assert d["was"]["verdict"] == "good" and d["now"]["verdict"] == "concern"
        assert d["what_changed"] == "It has started running betting sponsorships."
        assert "Free Spins Explained" in d["sample_titles"]

        inbox = client.get("/parent/inbox", headers=hdr(auth)).json()
        assert len(inbox) == 1
        assert inbox[0]["kind"] == "channel_drift" and inbox[0]["video"] is None
        assert inbox[0]["drift"]["channel_id"] == CHANNEL
        assert "Sprout Science" in inbox[0]["reason"]

    def test_the_channel_is_still_there_afterwards(
        self, client: TestClient, auth: dict, store: LocalStore, kid_with_channel: str, monkeypatch
    ) -> None:
        """The rule the whole feature turns on. A drift is information; removal
        is a DELETE the parent makes."""
        store.put_channel_review(CHANNEL, review(reviewed_days_ago=30).model_dump())
        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed", feed("A", "B", "C"))
        monkeypatch.setattr("heygilli_agents.reviewer.reviewer_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))
        monkeypatch.setattr(drift, "drift_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))

        check(client, auth)
        prompt_id = client.get("/parent/inbox", headers=hdr(auth)).json()[0]["id"]

        for decision in ("hide", "approve"):
            r = client.post(f"/parent/inbox/{prompt_id}", json={"decision": decision},
                            headers=hdr(auth))
            assert r.status_code == 200
            channels = client.get(f"/kids/{kid_with_channel}/channels", headers=hdr(auth)).json()
            assert [c["id"] for c in channels] == [CHANNEL], "nothing may remove it but the parent"

    def test_a_second_check_does_not_stack_up_cards(
        self, client: TestClient, auth: dict, store: LocalStore, kid_with_channel: str, monkeypatch
    ) -> None:
        store.put_channel_review(CHANNEL, review(reviewed_days_ago=30).model_dump())
        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed", feed("A", "B", "C"))
        monkeypatch.setattr("heygilli_agents.reviewer.reviewer_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))
        monkeypatch.setattr(drift, "drift_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel(worse_review)))

        check(client, auth)
        # The weekly limit alone stops the second check, but force the aged state
        # back to prove the inbox would not double up even if it did not.
        store.cache_put(drift.CHECK_NAMESPACE, CHANNEL, {"checked_at": days_ago(30)})
        aged = ChannelReview.model_validate(store.get_channel_review(CHANNEL))
        aged.reviewed_at = days_ago(30)
        store.put_channel_review(CHANNEL, aged.model_dump())
        check(client, auth)

        assert len(client.get("/parent/inbox", headers=hdr(auth)).json()) == 1

    def test_a_channel_that_improved_interrupts_nobody(
        self, client: TestClient, auth: dict, store: LocalStore, kid_with_channel: str, monkeypatch
    ) -> None:
        store.put_channel_review(
            CHANNEL, review(verdict="concern", flags=("scary",), reviewed_days_ago=30).model_dump()
        )
        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed", feed("A", "B", "C"))
        # The fake's default review is "good" with no flags: the channel cleaned up.
        monkeypatch.setattr("heygilli_agents.reviewer.reviewer_agent",
                            lambda model=None: make_agent("reviewer", "s", model=FakeModel()))

        body = check(client, auth)

        assert body["checked"] == 1 and body["drifted"] == []
        assert client.get("/parent/inbox", headers=hdr(auth)).json() == []

    def test_an_unreadable_channel_keeps_the_review_the_parent_had(
        self, client: TestClient, auth: dict, store: LocalStore, kid_with_channel: str, monkeypatch
    ) -> None:
        """A network blip must not decay a good review into "unknown" on the
        parent's screen, and must not raise a card either."""
        store.put_channel_review(CHANNEL, review(reviewed_days_ago=30).model_dump())

        def unreachable(channel_id, limit=12):
            raise RuntimeError("feed is down")

        monkeypatch.setattr("heygilli_agents.reviewer.fetch_channel_feed", unreachable)

        body = check(client, auth)

        assert body["checked"] == 1 and body["drifted"] == []
        assert ChannelReview.model_validate(store.get_channel_review(CHANNEL)).verdict == "good"
        assert client.get("/parent/inbox", headers=hdr(auth)).json() == []

    def test_drift_check_needs_auth(self, client: TestClient) -> None:
        assert client.post("/channels/drift/check", json={"channel_ids": []}).status_code == 401
