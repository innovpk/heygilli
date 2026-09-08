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
from collections.abc import Sequence

from pydantic import BaseModel, Field
from strands import Agent

from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES, ensure_plan, planner_agent
from .schemas import CuratorDecision, Kid, Policy, Video
from .store import Store
from .tools.notify import notify_parent
from .tools.screening import prescreen, screen_video
from .tools.transcript import TranscriptsBlocked, fetch_transcript, transcript_text
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
    #: Why the run ended before it ran out of channels, empty when it did not.
    #: A partial screening that reports itself as a whole one is the worst
    #: outcome here: a parent would believe every upload had been looked at.
    stopped_early: str = ""
    #: How many videos in this run were judged on their title and description
    #: because no transcript could be read, and why. Not a footnote: it is the
    #: difference between "we watched these" and "we read their titles", and
    #: the parent is shown the same fact per video as "read: title only".
    read_titles_only: int = 0
    no_transcripts: str = ""


#: What a video with no readable transcript looks like to the rest of the run.
_NO_TRANSCRIPT: dict = {"source": "none", "segments": []}


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

    The field is documented as one id, but a video can offend several
    preferences at once and the model then answers with all of them, comma
    separated. Looking the whole string up as a single key found nothing, so
    the protection above silently did not apply and taste hid a video that
    should have gone to the inbox. Every id offered is checked instead, and
    the first that really is answered `rather_not` decides — an unanswered id
    alongside a real one still cannot launder anything.
    """
    if not decision.policy_id or decision.decision == "ask_parent":
        return decision
    rather_not = policy.rather_not() if policy else {}
    answer = next(
        (rather_not[i] for i in
         (part.strip() for part in decision.policy_id.split(",")) if i in rather_not),
        None,
    )
    if answer is None:
        return decision
    preference = answer.question or answer.id
    return decision.model_copy(update={
        "decision": "ask_parent",
        "reason": f"{decision.reason} You said you would rather not: {preference}",
    })


def caption_language(transcript_source: str) -> str:
    """The language of the captions we read, or "" when we do not know.

    `fetch_transcript` reports its source as `captions:<lang>:<auto|manual>`;
    anything else (Gemini, or no transcript at all) tells us nothing about the
    language, and guessing from a title is how a Spanish video ends up in front
    of a child who speaks English.
    """
    parts = transcript_source.split(":")
    return parts[1].split("-")[0].lower() if len(parts) >= 2 and parts[0] == "captions" else ""


def understandable(transcript_source: str, languages: Sequence[str]) -> bool:
    """Whether a child who speaks [languages] could follow this.

    Unknown language is not a reason to hide: plenty of good videos have no
    captions, and refusing everything we cannot identify would empty the shelf.
    """
    lang = caption_language(transcript_source)
    if not lang or not languages:
        return True
    return lang in {str(x).split("-")[0].lower() for x in languages}


def decide(
    video: Video,
    band: str,
    agent: Agent,
    excerpt: str,
    policy: Policy | None = None,
    languages: Sequence[str] = (),
    transcript_source: str = "",
    wanted_topics: Sequence[str] = (),
) -> CuratorDecision:
    prescreened = prescreen(video)
    if prescreened.verdict != "pass":
        return CuratorDecision(decision=prescreened.verdict if prescreened.verdict != "pass" else "approve",
                               reason=prescreened.reason)
    # A child cannot answer a question about a video they cannot understand.
    # Checked in code rather than asked of the model: the caption language is a
    # fact, and a model reading a Cyrillic title has been happy to approve it.
    if not understandable(transcript_source, languages):
        return CuratorDecision(
            decision="hide",
            reason=f"spoken in {caption_language(transcript_source)}, "
                   f"which is not a language they are set up for",
        )
    spoken = ", ".join(languages) if languages else "unknown"
    # What the parent asked for, and what to do when an upload is not it. A
    # channel's topics are the channel's, not each video's: an educational
    # channel posts quote compilations, a science channel posts a birthday
    # message, and both were approved without anything noticing they were not
    # what the parent chose. Never hidden for it, though — a preference the
    # family expressed goes to the parent, and only the safety rules hide on
    # their own.
    wanted = (
        f"the parent asked for: {', '.join(wanted_topics)}\n"
        "If this video is not about any of those, return ask_parent and say so "
        "in the reason. Never hide it for that alone.\n"
        if wanted_topics
        else ""
    )
    prompt = (
        f"age_band: {band}\nlanguages the child speaks: {spoken}\n{wanted}"
        f"title: {video.title}\nduration_s: {video.duration_s}\n"
        f"description: {video.description[:600]}\n\n{policy_prompt(policy)}"
        f"Transcript excerpt:\n{excerpt}\n\n"
        f"Return the CuratorDecision. Hide anything not in a language above."
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
    no_transcripts = False

    for channel in store.list_channels(kid.household_id, kid.id):
        if not channel.approved:
            continue
        try:
            uploads = fetch_uploads(channel.id, limit_per_channel)
        except Exception as e:  # noqa: BLE001 - one bad channel must not stop the run
            log.warning("uploads failed for %s: %s", channel.id, e)
            continue
        # One Data API call for the whole channel rather than a watch page per
        # video: the watch page is refused to this machine, which left every
        # duration at 0 — and a duration of 0 turns the parent's "longest
        # video" limit into no limit and schedules the end-of-video question at
        # the moment it starts.
        for up in uploads:
            if up["id"] in seen:
                continue
            video = store.get_video(up["id"]) or Video(**up)
            if not video.duration_s or not video.thumb_url:
                # The watch page, which YouTube refuses to datacenter
                # addresses: from a home connection this fills the length in,
                # from the deployed gateway it does not, and an unknown length
                # stays unknown rather than becoming zero seconds.
                meta = fetch_video_meta(video.id)
                video.duration_s = video.duration_s or meta.get("duration_s", 0)
                video.thumb_url = video.thumb_url or meta.get("thumb_url", "")
            if no_transcripts:
                tr = _NO_TRANSCRIPT  # already established; asking again earns the same refusal
            else:
                try:
                    tr = fetch_transcript(video.id)
                except TranscriptsBlocked as e:
                    # This used to end the run. The reasoning was that a
                    # screening done on titles must not pass for one done on
                    # transcripts — right in itself, but it assumed the refusal
                    # was temporary. From a datacenter it is not: it is every
                    # video, every run, forever, and the guard turned "weaker
                    # screening" into a child with an empty screen and a parent
                    # with no idea why.
                    #
                    # So carry on with the title and description, which the RSS
                    # feed gives us and which the Curator prompt already knows
                    # to be cautious with. What must not happen is the part the
                    # old guard was actually protecting: passing this off as a
                    # full screening. Every such video is stored with
                    # `transcript_source: "none"`, which the app shows as
                    # "read: title only", and the report says how many.
                    log.warning("no transcripts for kid %s, reading titles: %s", kid.id, e)
                    no_transcripts = True
                    report.no_transcripts = str(e)
                    tr = _NO_TRANSCRIPT
            if tr["source"] == "none":
                report.read_titles_only += 1
            excerpt = transcript_text(tr["segments"][:40], max_chars=1500) or "(no transcript)"
            decision = decide(
                video,
                kid.age_band or "7_8",
                curator,
                excerpt,
                policy,
                languages=kid.languages,
                transcript_source=tr["source"],
                wanted_topics=kid.topics,
            )
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
                    ensure_plan(video, kid.age_band or "7_8", language, store, planner,
                                kid.question_freq, kid.disabled_prompts)
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
