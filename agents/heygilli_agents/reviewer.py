"""Reviewer: what does one channel actually publish? (PROTOCOL.md "Channel reviews")

The Curator screens a single video. This agent looks at a whole channel, because
a parent who has just imported 153 subscriptions from a Takeout export needs to
know which ones are worth keeping before any individual video matters.

Evidence. One request to the channel's public RSS feed, which returns the
channel's own title plus its ~15 most recent uploads with titles and short
descriptions. No API key, no quota, no `search` endpoint. That feed is the
entire basis for the review, and the titles it fed the model come back in
`sample_titles` so the parent can see exactly what was read.

What is decided in code, not in the prompt:

- Fewer than `MIN_UPLOADS` readable uploads -> verdict `unknown` with an honest
  note. The model is not called at all, so it cannot guess from a channel name.
- `sample_titles` is set from the titles that were actually put in the prompt.
- A model failure is `unknown`, never a default `good`.

Reviews are cached globally by channel id (`store.get_channel_review`) with
`reviewed_at` and the model id, because the answer does not depend on which
child is asking.
"""
from __future__ import annotations

import logging

from strands import Agent

from .llm import make_agent, structured
from .models import spec_for
from .schemas import ChannelReview, ChannelReviewDraft, ReviewFlag, now_iso
from .store import Store, get_store
from .tools.screening import screen_video
from .tools.youtube import fetch_channel_feed

log = logging.getLogger(__name__)

MIN_UPLOADS = 3  # below this there is nothing honest to say
EVIDENCE_UPLOADS = 12  # how many recent uploads to read (the feed holds ~15)
DESCRIPTION_CHARS = 200  # descriptions are cheap in the feed; keep the prompt small

REVIEWER_SYSTEM_PROMPT = """You are the Reviewer for HeyGilli. A parent has just imported the
channels their child is subscribed to and wants to know, channel by channel, what each one
actually publishes. You are given a channel's recent upload titles and short descriptions. That
list is all you know; you have no other information about the channel.

Say what the channel publishes, in one or two plain sentences a parent can read in three seconds.
Be concrete and use the evidence: "mostly Minecraft let's-plays with clickbait thumbnails" beats
"gaming content".

Then flag ONLY what a parent would actually want to be told about:
- ads_or_merch: heavy merchandise or sponsorship pushing in the uploads themselves
- consumerism: unboxing, toy-haul and "buy this" bait aimed at children
- scary: horror, jump-scares, violence, distressing themes
- mature_language: swearing or adult humour
- low_quality: mass-produced filler, auto-generated or endlessly repeated formats
- off_topic: the channel has drifted away from what a child subscribed for
- not_for_kids: clearly made for adults
- unclear: you genuinely cannot tell from these titles

Give each flag one short factual line quoting or naming what you saw. No flag is the normal case:
most channels get none.

Verdicts. good: what it publishes looks fine for children. mixed: mostly fine with something a
parent should know about. concern: a parent should look before letting a child watch this.
unknown: the titles do not tell you enough.

Rules you must hold to:
- Never invent a specific. If a detail is not in the titles or descriptions you were given, it does
  not go in the review.
- Never moralise about the creator. Describe the content, not the person who made it; no words like
  greedy, lazy, irresponsible, shameless. A channel that sells merch is selling merch, not
  exploiting children.
- Say when you are unsure. "Only three uploads, all trailers, so it is hard to say" is a better
  answer than a confident one.
- good_for lists the age bands (4_6, 7_8, 9_11) the content suits. Leave it empty if you cannot
  tell.

You are writing advice for a parent who makes the decision. You are not banning anything.
""".strip()


def reviewer_agent(model=None) -> Agent:
    """The rule-based `screen_video` tool is offered so the model can check a
    title against the same word lists the Curator uses instead of guessing."""
    return make_agent("reviewer", REVIEWER_SYSTEM_PROMPT, tools=[screen_video], model=model)


def _model_id(agent: Agent) -> str:
    """The model actually used, for the review's `model` field."""
    try:
        return str(agent.model.get_config().get("model_id") or spec_for("reviewer"))
    except Exception:  # noqa: BLE001 - a provider without get_config still gets a label
        return spec_for("reviewer")


def gather_evidence(channel_id: str, limit: int = EVIDENCE_UPLOADS) -> dict:
    """One RSS request -> `{"title", "uploads"}`. Never the Data API search endpoint."""
    feed = fetch_channel_feed(channel_id, limit)
    return {"title": feed.get("title", ""), "uploads": feed.get("uploads", [])}


def _evidence_prompt(title: str, uploads: list[dict]) -> str:
    lines = []
    for i, up in enumerate(uploads, 1):
        desc = " ".join((up.get("description") or "").split())[:DESCRIPTION_CHARS]
        lines.append(f"{i}. {up.get('title', '')}" + (f"\n   {desc}" if desc else ""))
    return (
        f"channel: {title or '(unknown title)'}\n"
        f"recent uploads ({len(uploads)}):\n" + "\n".join(lines) +
        "\n\nReturn the ChannelReviewDraft. Base every word on the list above."
    )


def _unknown(channel_id: str, title: str, thumb_url: str, titles: list[str], note: str,
             model: str) -> ChannelReview:
    return ChannelReview(
        channel_id=channel_id, title=title or channel_id, thumb_url=thumb_url,
        verdict="unknown", summary=note,
        flags=[ReviewFlag(kind="unclear", note=note)],
        sample_titles=titles, reviewed_at=now_iso(), model=model,
    )


def review_channel(
    channel_id: str,
    store: Store | None = None,
    agent: Agent | None = None,
    title_hint: str = "",
    thumb_url: str = "",
    refresh: bool = False,
) -> ChannelReview:
    """Review one channel and cache the result. Blocking; callers run it in a thread."""
    store = store or get_store()
    if not refresh and (cached := store.get_channel_review(channel_id)):
        review = ChannelReview.model_validate(cached)
        if not review.thumb_url and thumb_url:  # a later caller knew the avatar
            review.thumb_url = thumb_url
            store.put_channel_review(channel_id, review.model_dump())
        return review

    agent = agent or reviewer_agent()
    model = _model_id(agent)
    title = title_hint

    try:
        evidence = gather_evidence(channel_id)
    except Exception as e:  # noqa: BLE001 - one unreachable channel must not sink a bulk run
        log.warning("no feed for channel %s: %s", channel_id, e)
        review = _unknown(channel_id, title, thumb_url, [],
                          "Could not read this channel's recent uploads, so there is nothing to "
                          "base a review on.", model)
        store.put_channel_review(channel_id, review.model_dump())
        return review

    title = evidence["title"] or title_hint
    uploads = evidence["uploads"]
    sample_titles = [str(u.get("title", "")).strip() for u in uploads if str(u.get("title", "")).strip()]

    if len(sample_titles) < MIN_UPLOADS:
        review = _unknown(
            channel_id, title, thumb_url, sample_titles,
            f"Only {len(sample_titles)} recent upload"
            f"{'' if len(sample_titles) == 1 else 's'} could be read, which is too little to say "
            "what this channel publishes.",
            model,
        )
        store.put_channel_review(channel_id, review.model_dump())
        return review

    try:
        draft = structured(agent, _evidence_prompt(title, uploads), ChannelReviewDraft)
    except Exception as e:  # noqa: BLE001 - LLMError, a provider error, a throttle: all mean "unknown"
        log.warning("reviewer model failed for %s: %s", channel_id, e)
        review = _unknown(channel_id, title, thumb_url, sample_titles,
                          "The review could not be completed automatically.", model)
        store.put_channel_review(channel_id, review.model_dump())
        return review

    review = ChannelReview(
        channel_id=channel_id,
        title=title or channel_id,
        thumb_url=thumb_url,
        verdict=draft.verdict,
        summary=draft.summary,
        flags=draft.flags,
        good_for=draft.good_for,
        sample_titles=sample_titles,  # what was actually sent, never what the model claims
        reviewed_at=now_iso(),
        model=model,
    )
    store.put_channel_review(channel_id, review.model_dump())
    return review
