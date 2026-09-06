"""Persistence: one small interface, two backends.

    HEYGILLI_STORE=local   JSON files under agents/.data/<household>/<entity>/<id>.json
    HEYGILLI_STORE=dynamo  single table, PK=household, SK=<entity>#<id>

Global entities (videos, plans, transcript cache) live under the pseudo-household
"_global" so every household shares one plan per video/band/language.
"""
from __future__ import annotations

import json
import os
from abc import ABC, abstractmethod
from pathlib import Path
from typing import Any

from .schemas import (
    Answer,
    BreakPeriod,
    Channel,
    Digest,
    GoogleLink,
    HistoryAggregate,
    HistoryInsight,
    Kid,
    ParentPrompt,
    Policy,
    QuestionPlan,
    Session,
    Video,
)

GLOBAL = "_global"
DATA_DIR = Path(os.getenv("HEYGILLI_DATA_DIR", Path(__file__).resolve().parent.parent / ".data"))


class Store(ABC):
    """Four primitive operations; everything typed below is built on them."""

    @abstractmethod
    def put(self, household: str, entity: str, item_id: str, data: dict[str, Any]) -> None: ...

    @abstractmethod
    def get(self, household: str, entity: str, item_id: str) -> dict[str, Any] | None: ...

    @abstractmethod
    def list(self, household: str, entity: str) -> list[dict[str, Any]]: ...

    @abstractmethod
    def delete(self, household: str, entity: str, item_id: str) -> None: ...

    # -- kids
    def put_kid(self, kid: Kid) -> None:
        self.put(kid.household_id, "kid", kid.id, kid.model_dump())

    def get_kid(self, household: str, kid_id: str) -> Kid | None:
        d = self.get(household, "kid", kid_id)
        return Kid.model_validate(d) if d else None

    def list_kids(self, household: str) -> list[Kid]:
        return [Kid.model_validate(d) for d in self.list(household, "kid")]

    # -- the parent's Google link (one per household, see schemas.GoogleLink).
    # The refresh token inside it is a credential; it is stored here in the
    # clear for the hackathon and would be encrypted at rest in a real
    # deployment (README "Data safety").
    def put_google_link(self, household: str, link: GoogleLink) -> None:
        self.put(household, "google_link", "youtube", link.model_dump())

    def get_google_link(self, household: str) -> GoogleLink | None:
        d = self.get(household, "google_link", "youtube")
        return GoogleLink.model_validate(d) if d else None

    def clear_google_link(self, household: str) -> None:
        self.delete(household, "google_link", "youtube")

    # -- household policy (one per kid; PROTOCOL.md "Household policy")
    def put_policy(self, household: str, policy: Policy) -> None:
        self.put(household, "policy", policy.kid_id, policy.model_dump())

    def get_policy(self, household: str, kid_id: str) -> Policy | None:
        """None means the parent has never answered anything, which is a valid
        state: the Curator then falls back to age-band defaults."""
        d = self.get(household, "policy", kid_id)
        return Policy.model_validate(d) if d else None

    # -- watch history (PROTOCOL.md "Watch history: opt-in, aggregate, discarded")
    #
    # Only counts are ever written here. A pending aggregate is one profile's
    # history waiting for the parent to say which kid it belongs to; it is
    # deleted the moment it is attached, so an import the parent abandons leaves
    # nothing behind that is tied to a child.
    def put_history(self, household: str, insight: HistoryInsight) -> None:
        self.put(household, "history", insight.kid_id, insight.model_dump())

    def get_history(self, household: str, kid_id: str) -> HistoryInsight | None:
        d = self.get(household, "history", kid_id)
        return HistoryInsight.model_validate(d) if d else None

    def delete_history(self, household: str, kid_id: str) -> None:
        self.delete(household, "history", kid_id)

    def put_pending_history(self, household: str, profile: str, agg: HistoryAggregate) -> None:
        self.put(household, "history_pending", profile, agg.model_dump())

    def get_pending_history(self, household: str, profile: str) -> HistoryAggregate | None:
        d = self.get(household, "history_pending", profile)
        return HistoryAggregate.model_validate(d) if d else None

    def delete_pending_history(self, household: str, profile: str) -> None:
        self.delete(household, "history_pending", profile)

    # -- channels (per kid)
    def put_channel(self, household: str, kid_id: str, ch: Channel) -> None:
        self.put(household, f"channel@{kid_id}", ch.id, ch.model_dump())

    def list_channels(self, household: str, kid_id: str) -> list[Channel]:
        return [Channel.model_validate(d) for d in self.list(household, f"channel@{kid_id}")]

    def delete_channel(self, household: str, kid_id: str, channel_id: str) -> None:
        """Remove a channel from one kid. Other kids keep theirs, and the global
        review cache is untouched (PROTOCOL.md "Channel reviews")."""
        self.delete(household, f"channel@{kid_id}", channel_id)

    # -- channel reviews (global: a review is a property of the channel, not of a kid)
    def get_channel_review(self, channel_id: str) -> dict[str, Any] | None:
        return self.cache_get("channel_review", channel_id)

    def put_channel_review(self, channel_id: str, data: dict[str, Any]) -> None:
        self.cache_put("channel_review", channel_id, data)

    # -- videos (global metadata) + per-kid visibility
    def put_video(self, video: Video) -> None:
        self.put(GLOBAL, "video", video.id, video.model_dump())

    def get_video(self, video_id: str) -> Video | None:
        d = self.get(GLOBAL, "video", video_id)
        return Video.model_validate(d) if d else None

    def set_kid_video(self, household: str, kid_id: str, video_id: str, status: str, reason: str) -> None:
        self.put(household, f"kidvideo@{kid_id}", video_id, {"status": status, "reason": reason})

    def list_kid_videos(self, household: str, kid_id: str) -> dict[str, dict[str, Any]]:
        return {d["_id"]: d for d in self.list(household, f"kidvideo@{kid_id}")}

    # -- plans (global, keyed video#band#language)
    def put_plan(self, plan: QuestionPlan) -> None:
        key = QuestionPlan.key(plan.video_id, plan.age_band, plan.language)
        self.put(GLOBAL, "plan", key, plan.model_dump())

    def get_plan(self, video_id: str, age_band: str, language: str) -> QuestionPlan | None:
        d = self.get(GLOBAL, "plan", QuestionPlan.key(video_id, age_band, language))
        return QuestionPlan.model_validate(d) if d else None

    # -- sessions and answers
    def put_session(self, s: Session) -> None:
        self.put(s.household_id, "session", s.id, s.model_dump())

    def get_session(self, household: str, session_id: str) -> Session | None:
        d = self.get(household, "session", session_id)
        return Session.model_validate(d) if d else None

    def list_sessions(self, household: str, kid_id: str, date: str | None = None) -> list[Session]:
        out = [Session.model_validate(d) for d in self.list(household, "session")]
        return [s for s in out if s.kid_id == kid_id and (date is None or s.date == date)]

    # -- movement breaks (one entity per kid; a break is never deleted, it expires)
    def put_break(self, household: str, b: BreakPeriod) -> None:
        self.put(household, f"break@{b.kid_id}", b.id, b.model_dump())

    def list_breaks(self, household: str, kid_id: str) -> list[BreakPeriod]:
        out = [BreakPeriod.model_validate(d) for d in self.list(household, f"break@{kid_id}")]
        return sorted(out, key=lambda b: b.started_at)

    def get_break(self, household: str, kid_id: str, break_id: str) -> BreakPeriod | None:
        d = self.get(household, f"break@{kid_id}", break_id)
        return BreakPeriod.model_validate(d) if d else None

    def put_answer(self, household: str, a: Answer) -> None:
        self.put(household, f"answer@{a.session_id}", a.id, a.model_dump())

    def list_answers(self, household: str, session_id: str) -> list[Answer]:
        out = [Answer.model_validate(d) for d in self.list(household, f"answer@{session_id}")]
        return sorted(out, key=lambda a: (a.created_at, a.question_idx))

    # -- digests and parent inbox
    def put_digest(self, household: str, d: Digest) -> None:
        self.put(household, "digest", f"{d.kid_id}#{d.date}", d.model_dump())

    def get_digest(self, household: str, kid_id: str, date: str) -> Digest | None:
        d = self.get(household, "digest", f"{kid_id}#{date}")
        return Digest.model_validate(d) if d else None

    # -- analytics notes (one model call per kid/window/rounded-inputs, see analytics.py)
    def get_analytics_note(self, household: str, key: str) -> dict[str, Any] | None:
        return self.get(household, "analytics_note", key)

    def put_analytics_note(self, household: str, key: str, data: dict[str, Any]) -> None:
        self.put(household, "analytics_note", key, data)

    def put_parent_prompt(self, p: ParentPrompt) -> None:
        self.put(p.household_id, "parent_prompt", p.id, p.model_dump())

    def get_parent_prompt(self, household: str, prompt_id: str) -> ParentPrompt | None:
        d = self.get(household, "parent_prompt", prompt_id)
        return ParentPrompt.model_validate(d) if d else None

    def list_parent_prompts(self, household: str, open_only: bool = True) -> list[ParentPrompt]:
        out = [ParentPrompt.model_validate(d) for d in self.list(household, "parent_prompt")]
        if open_only:
            out = [p for p in out if p.decision is None]
        return sorted(out, key=lambda p: p.created_at)

    # -- generic cache for tools (youtube pages, transcripts)
    def cache_get(self, namespace: str, key: str) -> dict[str, Any] | None:
        d = self.get(GLOBAL, f"cache@{namespace}", key)
        if d is not None:
            d.pop("_id", None)  # cached payloads round-trip exactly as they were put
        return d

    def cache_put(self, namespace: str, key: str, data: dict[str, Any]) -> None:
        self.put(GLOBAL, f"cache@{namespace}", key, data)


class LocalStore(Store):
    """JSON files. Good enough for one household and for tests."""

    def __init__(self, root: Path | str | None = None) -> None:
        self.root = Path(root) if root else DATA_DIR
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, household: str, entity: str, item_id: str) -> Path:
        safe_id = item_id.replace("/", "_").replace("#", "__")
        return self.root / household / entity / f"{safe_id}.json"

    def put(self, household: str, entity: str, item_id: str, data: dict[str, Any]) -> None:
        p = self._path(household, entity, item_id)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({**data, "_id": item_id}, ensure_ascii=False, indent=1))

    def get(self, household: str, entity: str, item_id: str) -> dict[str, Any] | None:
        p = self._path(household, entity, item_id)
        return json.loads(p.read_text()) if p.exists() else None

    def list(self, household: str, entity: str) -> list[dict[str, Any]]:
        d = self.root / household / entity
        if not d.exists():
            return []
        return [json.loads(p.read_text()) for p in sorted(d.glob("*.json"))]

    def delete(self, household: str, entity: str, item_id: str) -> None:
        p = self._path(household, entity, item_id)
        if p.exists():
            p.unlink()


class DynamoStore(Store):
    """Single-table design on DynamoDB: PK=household, SK=<entity>#<id>."""

    def __init__(self, table_name: str | None = None, region: str | None = None) -> None:
        import boto3

        self.table_name = table_name or os.getenv("HEYGILLI_DYNAMO_TABLE", "heygilli")
        self.region = region or os.getenv("AWS_REGION", "us-east-1")
        self._ddb = boto3.resource("dynamodb", region_name=self.region)
        self.table = self._ddb.Table(self.table_name)

    @staticmethod
    def _sk(entity: str, item_id: str) -> str:
        return f"{entity}#{item_id}"

    def create_table_if_missing(self) -> None:
        client = self._ddb.meta.client
        existing = client.list_tables()["TableNames"]
        if self.table_name in existing:
            return
        client.create_table(
            TableName=self.table_name,
            BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[
                {"AttributeName": "pk", "AttributeType": "S"},
                {"AttributeName": "sk", "AttributeType": "S"},
            ],
            KeySchema=[
                {"AttributeName": "pk", "KeyType": "HASH"},
                {"AttributeName": "sk", "KeyType": "RANGE"},
            ],
        )
        client.get_waiter("table_exists").wait(TableName=self.table_name)

    def put(self, household: str, entity: str, item_id: str, data: dict[str, Any]) -> None:
        # Store the document as a JSON string: no float/Decimal dance, one attribute.
        self.table.put_item(
            Item={
                "pk": household,
                "sk": self._sk(entity, item_id),
                "doc": json.dumps({**data, "_id": item_id}, ensure_ascii=False),
            }
        )

    def get(self, household: str, entity: str, item_id: str) -> dict[str, Any] | None:
        r = self.table.get_item(Key={"pk": household, "sk": self._sk(entity, item_id)})
        item = r.get("Item")
        return json.loads(item["doc"]) if item else None

    def list(self, household: str, entity: str) -> list[dict[str, Any]]:
        from boto3.dynamodb.conditions import Key

        out: list[dict[str, Any]] = []
        kwargs: dict[str, Any] = {
            "KeyConditionExpression": Key("pk").eq(household) & Key("sk").begins_with(f"{entity}#")
        }
        while True:
            r = self.table.query(**kwargs)
            out.extend(json.loads(i["doc"]) for i in r.get("Items", []))
            if "LastEvaluatedKey" not in r:
                return out
            kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]

    def delete(self, household: str, entity: str, item_id: str) -> None:
        self.table.delete_item(Key={"pk": household, "sk": self._sk(entity, item_id)})


_store: Store | None = None


def get_store() -> Store:
    """Process-wide store chosen by HEYGILLI_STORE (default local)."""
    global _store
    if _store is None:
        kind = os.getenv("HEYGILLI_STORE", "local").lower()
        if kind == "dynamo":
            ds = DynamoStore()
            ds.create_table_if_missing()
            _store = ds
        elif kind == "local":
            _store = LocalStore()
        else:
            raise ValueError(f"unknown HEYGILLI_STORE={kind!r}; expected local|dynamo")
    return _store


def set_store(store: Store | None) -> None:
    """Tests swap in a temp-dir LocalStore."""
    global _store
    _store = store
