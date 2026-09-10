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
import re
from collections.abc import Sequence

from pydantic import BaseModel, Field
from strands import Agent

from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES, build_plan, ensure_plan, planner_agent
from .schemas import CuratorDecision, Kid, Policy, Video
from .store import Store
from .tools.notify import notify_parent
from .tools.screening import prescreen, screen_video
from .tools.transcript import TranscriptsBlocked, fetch_transcript, transcript_text
from .tools.youtube import fetch_durations, fetch_uploads, fetch_video_meta

log = logging.getLogger(__name__)

CURATOR_SYSTEM_PROMPT = f"""You are the Curator for HeyGilli. A parent has approved a YouTube
channel for their child; you review each NEW upload from that channel and decide whether this
particular video is right for this particular child's age band.

approve: clearly suitable, educational or gently entertaining, calm tone, on-topic for kids.
hide: anything scary, violent, gross-out, sexualised, hateful, product-pushing, or with a
"prank / 3AM / cursed" tone. Also hide compilations that are mostly ads.
ask_parent: borderline for the band (mildly intense, older themes, a sponsor segment, health or
body topics), or you simply cannot tell from the title, description and transcript excerpt.

Decide alone on clear cases; ask the parent only on borderline ones. Give up to 3 topic tags
(what it is about) and up to 3 `concerns` (what gave you pause; empty when nothing did). A parent
skims these before reading `reason`, so a concern is a real one or none at all — never one
invented to balance a verdict.

`approve` is the ordinary answer for a video that is on topic, calm and suitable for the band, and
most good videos are. `ask_parent` is for something that genuinely gave you pause — not a way of
being safe. A run that asks about everything is a run that has decided nothing, and the parent is
back to watching each video themselves, which is the thing this is for.

`reason` is read by a parent deciding whether to overrule you, so it has to tell them something
they did not already have. Two or three sentences, each earning its place:

- Say what actually happens in it, from the transcript. Name the thing: what it shows, what it
  teaches, how it opens, what the tone is like. "This video is about volcanoes" next to a title
  reading "Every Kind of Volcano" tells a parent nothing at all.
- Say what their child would get from it, or what in it gave you pause — concretely. The moment,
  the segment, the turn of tone; not a category.
- When one of the household's own answers bears on it, name that answer, say which part of the
  video touched it, and put its id in `policy_id`. Only when it really does: an erupting volcano
  in a science explainer is not "mild peril", and a compilation is not "pushing merchandise".
  Reaching for a preference that is not there turns every video into a question and teaches a
  parent that your reasons mean nothing.
- When you were given no transcript, say plainly that this is the title and description only.
  Never write as though you watched something you did not.
- Off-topic is not a verdict on quality, but it is still off-topic. Say what it IS about so the
  parent can say yes to it knowingly — and never write that it matches what they asked for when
  it does not. A literature lesson is not science however good it is.

Never begin with "This video is about". Never restate the title back to them. Two videos in the
same run must not come back with the same sentence, and "It is educational, calm, and aligns with
what the parent asked for" is not a sentence — it is a shrug with more words in it.

Do not address the parent or ask them anything. No "please let me know if this is acceptable", no
sign-off, no question at the end: they are reading this beside a switch they are about to press,
and a line asking for a decision they are already making is noise. Write about the video and stop.

This household may have told you what it actually wants. When a household policy is given, it
outranks your own taste: a thing this family said is "fine" is fine here even if you would normally
hesitate, and a thing they would "rather not" have is not fine here even if it is harmless. When
your decision turns on one of those answers, put that answer's id in `policy_id` and name the
preference in `reason`. Leave `policy_id` empty when the policy had nothing to do with it.

{SAFETY_RULES}
""".strip()


#: A tag is something a parent skims beside a switch, so it has to be short
#: enough to skim. Enforced here rather than trusted to the prompt, like every
#: other rule the Curator's output has to meet.
MAX_TAGS = 3
MAX_TAG_CHARS = 28


def clean_tags(tags) -> list[str]:
    """At most three, each short, capitalised, and no two the same."""
    out: list[str] = []
    seen: set[str] = set()
    for raw in tags or []:
        tag = " ".join(str(raw).split()).strip(" .,;:-")
        if not tag or len(tag) > MAX_TAG_CHARS or len(tag.split()) > 4:
            continue  # a sentence is not a tag
        tag = tag[0].upper() + tag[1:]
        if tag.lower() in seen:
            continue
        seen.add(tag.lower())
        out.append(tag)
        if len(out) >= MAX_TAGS:
            break
    return out


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
    #: Videos already on the shelf whose questions came from a title alone,
    #: read properly this time. See `reread_titles_only`.
    reread: int = 0


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


#: A whole closing sentence addressed to the parent rather than about the
#: video. The prompt forbids these; this is what happens when it is not obeyed,
#: which it was not — "Please let me know if this video is acceptable." closed
#: all eleven reasons in one run. It sits beside a switch the parent is already
#: reaching for, asking for the decision they are in the middle of making.
#:
#: Anchored at the start of the sentence, which matters: matching anywhere cut
#: "The presenter says let me know in the comments, which is a call to action"
#: down to "The presenter says" — losing the very thing the parent needed.
_PLEA = re.compile(
    r"^(?:please\s+|kindly\s+)?(?:let me know|do let me know|confirm)\b",
    re.IGNORECASE,
)
_SENTENCE = re.compile(r"[^.?!]+[.?!]*")


def tidy_reason(reason: str) -> str:
    """Drop a closing plea, leaving what was actually said about the video.

    Narrow on purpose: only the final sentence, only when it opens as one of
    these. A sentence that merely contains the words keeps them, and a reason
    that is nothing but a plea is left alone — cutting a parent's explanation
    to nothing is worse than leaving one stray line in it.
    """
    sentences = [m.group().strip() for m in _SENTENCE.finditer(reason.strip()) if m.group().strip()]
    if len(sentences) < 2 or not _PLEA.match(sentences[-1]):
        return reason.strip()
    return " ".join(sentences[:-1])


def apply_wanted(
    decision: CuratorDecision, wanted_topics: Sequence[str]
) -> CuratorDecision:
    """A video that is not what the family asked for goes to the parent.

    The rule lived in the prompt and the model kept it right up until the
    prompt also asked for a fuller `reason`. Then it began approving Crash
    Course *Literature* for a household that asked for science, writing "aligns
    with the parent's request for science content" underneath — the check had
    become a sentence it could compose its way around.

    So the judgement stays with the model, which is the only thing that can
    tell whether volcanoes count as science, and the consequence moves here,
    where no wording can reach it. Same split as `apply_policy`, and never a
    hide: wanting science is a preference, not a safety rule.
    """
    if not wanted_topics or decision.matches_wanted or decision.decision != "approve":
        return decision
    return decision.model_copy(update={
        "decision": "ask_parent",
        "reason": f"{decision.reason} This is not one of the things you asked for "
                  f"({', '.join(wanted_topics)}), so it is yours to say.",
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
        decided = structured(
            agent, prompt, CuratorDecision,
            context={"title": video.title, "description": video.description},
        )
        decided = decided.model_copy(update={"reason": tidy_reason(decided.reason)})
        return apply_wanted(apply_policy(decided, policy), wanted_topics)
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
        # video. The watch page is refused to this machine, which left every
        # duration at 0 — and 0 means "we could not find out", so the length
        # ceiling skipped it, the parent's "longest video" limit applied to
        # nothing, and the end-of-video question was scheduled for the moment
        # it started. `videos.list` costs one quota unit for up to fifty ids
        # and answers from a datacenter, which is the whole reason this is
        # affordable to do automatically.
        lengths = fetch_durations([up["id"] for up in uploads if up["id"] not in seen])
        for up in uploads:
            if up["id"] in seen:
                continue
            video = store.get_video(up["id"]) or Video(**up)
            video.duration_s = video.duration_s or lengths.get(video.id, 0)
            if not video.duration_s or not video.thumb_url:
                # The watch page, which YouTube refuses to datacenter
                # addresses: from a home connection this fills the length in,
                # from the deployed gateway it does not, and an unknown length
                # stays unknown rather than becoming zero seconds. Still worth
                # asking — it is also where the thumbnail comes from, and a
                # household running this locally gets a length from it.
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
            topics = clean_tags(decision.topics)
            concerns = clean_tags(decision.concerns)
            video.screening.topics = topics
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
            store.set_kid_video(
                kid.household_id, kid.id, video.id, decision.decision, decision.reason,
                topics=topics, concerns=concerns,
            )

    if not no_transcripts:
        report.reread = reread_titles_only(kid, store, planner)
    return report


def check_videos(
    kid: Kid,
    store: Store,
    video_ids: Sequence[str],
    uploads: Sequence[dict] = (),
    curator: Agent | None = None,
) -> list[dict]:
    """Read videos a parent found themselves, against this family's answers.

    The same judgement the scheduled run makes, for a video or channel the
    parent pasted rather than one from a channel they already allowed. It
    changes nothing a child can see: no kid-video entry is written, so the
    shelf is exactly as it was. The parent allows one afterwards through the
    review endpoint, the same as any other.

    Returns `{"video", "status", "reason", "topics", "concerns"}` per id, in
    the order asked. `uploads` are the feed entries a channel check already
    has, so their titles and dates are not fetched a second time.
    """
    curator = curator or curator_agent()
    policy = store.get_policy(kid.household_id, kid.id)
    feed = {u["id"]: u for u in uploads}
    videos: list[Video] = []
    for vid in video_ids:
        video = store.get_video(vid)
        if video is None:
            if vid in feed:
                video = Video(**feed[vid])
            else:
                meta = fetch_video_meta(vid)
                video = Video(
                    id=vid,
                    channel_id=meta.get("channel_id", ""),
                    title=meta.get("title", "") or vid,
                    duration_s=meta.get("duration_s", 0),
                    thumb_url=meta.get("thumb_url", ""),
                )
        videos.append(video)
    lengths = fetch_durations([v.id for v in videos if not v.duration_s])

    out: list[dict] = []
    for video in videos:
        video.duration_s = video.duration_s or lengths.get(video.id, 0)
        try:
            tr = fetch_transcript(video.id)
        except TranscriptsBlocked as e:
            # Read on the title and description, and said so: the item goes
            # back marked "title only", as it does on the scheduled run.
            log.warning("no transcript for checked video %s: %s", video.id, e)
            tr = _NO_TRANSCRIPT
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
        topics = clean_tags(decision.topics)
        concerns = clean_tags(decision.concerns)
        video.screening.topics = topics
        video.screening.reason = decision.reason
        video.transcript_source = tr["source"]
        store.put_video(video)
        out.append(
            {
                "video": video,
                "status": decision.decision,
                "reason": decision.reason,
                "topics": topics,
                "concerns": concerns,
            }
        )
    return out


#: How many already-screened videos one run will go back to. A re-read is a
#: transcript fetch and a Planner call each, and new uploads are the point of
#: the run, so this is what is left over rather than the whole backlog.
REREAD_PER_RUN = 10


def reread_titles_only(kid: Kid, store: Store, planner: Agent | None = None) -> int:
    """Go back to videos whose questions were written from a title alone.

    A transcript failure is nearly always temporary — a Gemini quota window, a
    503, a caption fetch that was rate-limited — and the run that hit one wrote
    a fallback plan: one general end-of-video question, the same for every
    video it happened to. That plan is cached forever and the video is in
    `seen`, so the next run skips it. One bad fifteen minutes during setup cost
    a child real questions on those videos for as long as they existed, and
    nothing anywhere said so or could be pressed to fix it.

    So: the approved videos that were read on their title, re-read, and their
    plans rebuilt when the words arrive this time. Deliberately only the plan.
    The *decision* is not revisited — a video on this shelf either passed
    screening or a parent put it there by hand, and quietly re-deciding it on
    new evidence would take back an answer they gave.
    """
    done = 0
    for video_id, entry in store.list_kid_videos(kid.household_id, kid.id).items():
        if done >= REREAD_PER_RUN:
            break
        if entry.get("status") != "approve":
            continue
        video = store.get_video(video_id)
        if video is None or video.transcript_source not in ("", "none"):
            continue
        try:
            tr = fetch_transcript(video.id)
        except TranscriptsBlocked as e:
            # Still nothing, and it will be nothing for every video after this
            # one too: the refusal is about this machine, not this video.
            log.info("re-read for kid %s got no further: %s", kid.id, e)
            break
        if tr["source"] == "none":
            continue
        for language in kid.languages:
            # Past the cache deliberately: the cached plan is the fallback that
            # this exists to replace.
            plan = build_plan(
                video, tr["segments"], kid.age_band or "7_8", language,
                kid.question_freq, planner, kid.disabled_prompts,
            )
            store.put_plan(plan)
        # Marked as read only once the plans are actually written. The other
        # order loses the video: a Planner failure halfway through would leave
        # it claiming a transcript it never used, and `transcript_source` is
        # the only thing that brings it back here next time.
        video.transcript_source = tr["source"]
        video.plan_ready = True
        store.put_video(video)
        done += 1
    return done
