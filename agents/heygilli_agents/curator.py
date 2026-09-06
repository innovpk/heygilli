"""Curator: new uploads on approved channels -> approve | hide | ask_parent, then plan.

Orchestration note. SPEC §9.3 sketches Curator -> Planner as a Strands Graph.
The installed SDK (strands-agents 1.54) has `GraphBuilder`, but its nodes hand
each other free text: the Planner would have to re-parse the Curator's prose and
the §7.3 rule enforcement would sit outside the graph anyway. Here the hand-off
is a typed Python pipeline: the Curator *agent* makes the judgement call with
structured output, code fans out to the Planner *agent* per (band, language),
and every plan passes `rules.enforce`. Same two Strands agents, deterministic
edges, no prose in between. See README "Why not a Graph".
"""
from __future__ import annotations

import logging

from pydantic import BaseModel, Field
from strands import Agent

from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES, ensure_plan, planner_agent
from .schemas import CuratorDecision, Kid, Policy, Video
from .store import Store
from .tools.notify import notify_parent
from .tools.screening import prescreen, screen_video
from .tools.transcript import fetch_transcript, transcript_text
from .tools.youtube import fetch_uploads, fetch_video_meta

log = logging.getLogger(__name__)

CURATOR_SYSTEM_PROMPT = f"""You are the Curator for HeyGilli. A parent has approved a YouTube
channel for their child; you review each NEW upload from that channel and decide whether this
particular video is right for this particular child's age band.

approve: clearly suitable, educational or gently entertaining, calm tone, on-topic for kids.
hide: anything scary, violent, gross-out, sexualised, hateful, product-pushing, or with a
"prank / 3AM / cursed" tone. Also hide compilations that are mostly ads.
ask_parent: borderline for the band (mildly intense, older themes, a sponsor segment, health or
body topics), or you simply cannot tell from the title, description and transcript excerpt.

Decide alone on clear cases; ask the parent only on borderline ones. Give ONE line a parent can read,
and up to 3 topic tags.

This household may have told you what it actually wants. When a household policy is given, it
outranks your own taste: a thing this family said is "fine" is fine here even if you would normally
hesitate, and a thing they would "rather not" have is not fine here even if it is harmless. When
your decision turns on one of those answers, put that answer's id in `policy_id` and name the
preference in `reason`. Leave `policy_id` empty when the policy had nothing to do with it.

{SAFETY_RULES}
""".strip()


class CuratorReport(BaseModel):
    approved: list[dict] = Field(default_factory=list)
    hidden: list[dict] = Field(default_factory=list)
    ask_parent: list[dict] = Field(default_factory=list)


def curator_agent(model=None) -> Agent:
    return make_agent("curator", CURATOR_SYSTEM_PROMPT, tools=[screen_video], model=model)


def policy_prompt(policy: Policy | None) -> str:
    """The household's own answers, as the Curator sees them.

    An empty policy contributes nothing at all rather than an empty heading: the
    Curator then falls back to age-band defaults, which is exactly what
    PROTOCOL.md says an empty policy means.
    """
    if policy is None or policy.is_empty():
        return ""
    lines = [f"- [{a.id}] {a.question or a.id}: {a.choice}" for a in policy.answers]
    if policy.notes.strip():
        lines.append(f"- the parent's own words: {policy.notes.strip()}")
    return "This household's policy:\n" + "\n".join(lines) + "\n\n"


def apply_policy(decision: CuratorDecision, policy: Policy | None) -> CuratorDecision:
    """A `rather_not` never hides a video silently; it sends it to the parent.

    PROTOCOL.md: the parent stays the decider. A preference is not a safety
    rule — it is a matter of taste this family expressed, so the video goes to
    their inbox where they can say yes to this one. The general safety rules are
    untouched: a decision the model did not attribute to a policy answer, and an
    id that is not in fact answered `rather_not`, both pass through unchanged, so
    the model cannot launder a `hide` into an `ask_parent` by naming an id.
    """
    if not decision.policy_id or decision.decision == "ask_parent":
        return decision
    answer = (policy.rather_not() if policy else {}).get(decision.policy_id)
    if answer is None:
        return decision
    preference = answer.question or answer.id
    return decision.model_copy(update={
        "decision": "ask_parent",
        "reason": f"{decision.reason} You said you would rather not: {preference}",
    })


def decide(
    video: Video, band: str, agent: Agent, excerpt: str, policy: Policy | None = None
) -> CuratorDecision:
    prescreened = prescreen(video)
    if prescreened.verdict != "pass":
        return CuratorDecision(decision=prescreened.verdict if prescreened.verdict != "pass" else "approve",
                               reason=prescreened.reason)
    prompt = (
        f"age_band: {band}\ntitle: {video.title}\nduration_s: {video.duration_s}\n"
        f"description: {video.description[:600]}\n\n{policy_prompt(policy)}"
        f"Transcript excerpt:\n{excerpt}\n\n"
        f"Return the CuratorDecision."
    )
    try:
        return apply_policy(structured(agent, prompt, CuratorDecision), policy)
    except LLMError as e:
        log.warning("curator model failed for %s: %s", video.id, e)
        return CuratorDecision(decision="ask_parent", reason="Could not review automatically.")


def run_curator(
    kid: Kid,
    store: Store,
    curator: Agent | None = None,
    planner: Agent | None = None,
    limit_per_channel: int = 5,
) -> CuratorReport:
    curator = curator or curator_agent()
    planner = planner or planner_agent()
    report = CuratorReport()
    seen = store.list_kid_videos(kid.household_id, kid.id)
    # Read once for the whole run: what this family wants does not change
    # halfway through a batch of uploads.
    policy = store.get_policy(kid.household_id, kid.id)

    for channel in store.list_channels(kid.household_id, kid.id):
        if not channel.approved:
            continue
        try:
            uploads = fetch_uploads(channel.id, limit_per_channel)
        except Exception as e:  # noqa: BLE001 - one bad channel must not stop the run
            log.warning("uploads failed for %s: %s", channel.id, e)
            continue
        for up in uploads:
            if up["id"] in seen:
                continue
            video = store.get_video(up["id"]) or Video(**up)
            if not video.duration_s:
                meta = fetch_video_meta(video.id)
                video.duration_s = meta.get("duration_s", 0)
                video.thumb_url = video.thumb_url or meta.get("thumb_url", "")
            tr = fetch_transcript(video.id)
            excerpt = transcript_text(tr["segments"][:40], max_chars=1500) or "(no transcript)"
            decision = decide(video, kid.age_band or "7_8", curator, excerpt, policy)
            video.screening.topics = decision.topics
            video.screening.reason = decision.reason
            video.transcript_source = tr["source"]
            entry = {**video.public(), "reason": decision.reason}

            if decision.decision == "approve":
                video.age_ok = True
                if kid.age_band and kid.age_band not in video.screening.age_ok:
                    video.screening.age_ok.append(kid.age_band)
                store.put_video(video)
                for language in kid.languages:
                    ensure_plan(video, kid.age_band or "7_8", language, store, planner, kid.question_freq)
                video = store.get_video(video.id) or video
                entry["plan_ready"] = video.plan_ready
                report.approved.append(entry)
            elif decision.decision == "hide":
                store.put_video(video)
                report.hidden.append(entry)
            else:
                store.put_video(video)
                notify_parent(kid.household_id, kid.id, video, decision.reason)
                report.ask_parent.append(entry)
            store.set_kid_video(kid.household_id, kid.id, video.id, decision.decision, decision.reason)
    return report
