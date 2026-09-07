"""Planner agent: transcript + band + language -> QuestionPlan (SPEC §7, §9.3).

The model proposes questions with Strands structured output; `rules.enforce`
then applies the §7.2/§7.3 contract in code, so the plan the child meets is
correct on any provider. Plans are cached per (video, band, language).
"""
from __future__ import annotations

import logging
from collections.abc import Sequence

from strands import Agent

from . import question_bank, rules
from .llm import LLMError, make_agent, structured
from .schemas import (
    TYPES_FOR_BAND,
    AgeBand,
    Language,
    Option,
    PlanDraft,
    Question,
    QuestionFreq,
    QuestionPlan,
    Video,
)
from .store import Store, get_store
from .tools.icons import find_icon, icon_ids, icon_lookup, list_icons
from .tools.transcript import TranscriptsBlocked, fetch_transcript, transcript_text

log = logging.getLogger(__name__)

SAFETY_RULES = """
Hard rules, no exceptions:
- Never mock, never say "wrong", "no", or "incorrect". Never compare the child to other kids.
- Never mention scores or points.
- Never ask for personal information: no names, school, home, family details, photos, location.
- Nothing scary, violent, gross-out, or sad. Nothing that asks the child to do something in the
  real world beyond a sound, a gesture, or naming what they see.
- Every question must be answerable from what was just watched. No trivia the video did not cover.
- No sarcasm. Talk like a kind, curious older cousin, not a teacher.
""".strip()

BAND_GUIDE = {
    "4_6": """
Band 4 to 6 (pre-readers). Types allowed: name_it (single word by voice), copy_it (make a sound or
a motion, never scored), pick_it (three pictures, exactly one correct).
Goals: vocabulary, naming, colours, counting to 5, animal sounds, basic emotions, one-step instructions.
Ask only about what is visible on the paused frame or heard in the last 30 seconds. Never "why".
Short sentences, stretched key words ("looong"), lots of "let's". `expected` is ONE word.
For pick_it: the two wrong options must be clearly different things (a giraffe, a fish, a car),
never near-misses, and every option label must be a concept from the icon library (use icon_lookup).
`model_line` is the sentence where the buddy says the answer word clearly once, e.g. "A giraffe! Gi-raffe."
""",
    "7_8": """
Band 7 to 8. Types allowed: recall, why, predict (sequence questions count as recall).
Goals: recall, cause and effect, prediction, sequencing, new words in context.
Playful and curious; ask "what do you think?". `expected` is a short phrase; add 2-4 `variants`
a child might say. `followup` is one extra fact to share after a correct answer.
""",
    "9_11": """
Band 9 to 11. Types allowed: explain, compare, apply, opinion (with a reason).
Goals: explanation, comparison, applying an idea elsewhere, forming an opinion with a reason,
noticing when a video is trying to sell something. Drop all baby talk; talk like an older cousin
who finds the topic genuinely interesting; mild humour is fine. `expected` is the gist of a good
answer; for opinion questions `expected` describes what a reasoned answer contains.
""",
}

PLANNER_SYSTEM_PROMPT = f"""You are the Planner for HeyGilli, a co-watching buddy named Gilli for
kids' YouTube. Given a timestamped transcript, you write the questions Gilli will ask when the video
pauses. Timing: place questions at a sentence end or scene change, never inside a sentence; respect
the first-question threshold and the minimum gap you are given; never exceed the maximum count.
Use the transcript timestamps (seconds) for `t_sec`. Write in the requested language.
Set `input` to voice/pick/copy, a `gesture` from idle|stretch|shrink|spin|point|roar|think|cheer,
and leave `options` empty unless the type is pick_it.

{SAFETY_RULES}
""".strip()

# Distinct, unrelated distractors used when a pick_it needs repairing (never near-misses).
DISTRACTOR_POOL = ("icon_car", "icon_fish", "icon_sun", "icon_ball", "icon_tree", "icon_house")


def planner_agent(model=None) -> Agent:
    return make_agent("planner", PLANNER_SYSTEM_PROMPT, tools=[icon_lookup, list_icons], model=model)


def plan_prompt(video: Video, segments: list[dict], band: AgeBand, language: Language, freq) -> str:
    t = rules.TIMING[band]
    return (
        f"age_band: {band}\nlanguage: {language}\nduration_s: {video.duration_s}\n"
        f"title: {video.title}\n"
        f"types allowed: {', '.join(TYPES_FOR_BAND[band])}\n"
        f"first question no earlier than: {t.first_question_s}s\n"
        f"minimum gap between questions: {rules.min_gap_s(band, freq)}s\n"
        f"maximum questions: {rules.max_questions(band, video.duration_s)}\n"
        f"{BAND_GUIDE[band].strip()}\n\n"
        f"Transcript:\n{transcript_text(segments)}\n\n"
        f"Return the PlanDraft."
    )


def build_plan(
    video: Video,
    segments: list[dict],
    band: AgeBand,
    language: Language,
    freq: QuestionFreq | None = None,
    agent: Agent | None = None,
    disabled_prompts: Sequence[str] = (),
) -> QuestionPlan:
    """Ask the model, then enforce the band contract in code."""
    if not segments:
        return fallback_plan(video, band, language, disabled_prompts)
    agent = agent or planner_agent()
    try:
        draft = structured(agent, plan_prompt(video, segments, band, language, freq), PlanDraft)
    except LLMError as e:
        log.warning("planner failed for %s/%s/%s: %s", video.id, band, language, e)
        return fallback_plan(video, band, language, disabled_prompts)
    questions = [repair_pick(q, language) for q in draft.questions]
    kept = rules.enforce(questions, band, video.duration_s, language, freq, icon_ids())
    if not kept:
        log.info("no question survived the rules for %s/%s; using fallback", video.id, band)
        return fallback_plan(video, band, language, disabled_prompts)
    return QuestionPlan(video_id=video.id, age_band=band, language=language, questions=kept)


def repair_pick(q: Question, language: Language) -> Question:
    """Map option labels to real icon ids; fill missing distractors from the pool."""
    if q.type != "pick_it" and q.input != "pick":
        return q
    fixed: list[Option] = []
    for o in q.options:
        hit = find_icon(o.icon_id) or find_icon(o.label)
        if hit and hit["id"] not in {f.icon_id for f in fixed}:
            fixed.append(Option(icon_id=hit["id"], label=hit.get(language) or hit["en"], correct=o.correct))
    correct = [o for o in fixed if o.correct]
    if len(correct) != 1:
        return q.model_copy(update={"options": fixed})  # rules.enforce will drop it
    for icon_id in DISTRACTOR_POOL:
        if len(fixed) >= 3:
            break
        if icon_id not in {f.icon_id for f in fixed}:
            hit = find_icon(icon_id)
            if hit:
                fixed.append(Option(icon_id=hit["id"], label=hit.get(language) or hit["en"]))
    return q.model_copy(update={"options": fixed[:3]})


def fallback_plan(
    video: Video,
    band: AgeBand,
    language: Language,
    disabled_prompts: Sequence[str] = (),
) -> QuestionPlan:
    """No usable transcript (SPEC §9.4): one end-of-video question from the bank.

    This used to be a single hardcoded line per band, so every video a
    five-year-old watched ended with "can you clap for the video?" — and with
    no transcripts reachable from the deployed gateway, that was every video
    they ever saw. `question_bank.pick` gives a different one per video and the
    same one each time that video comes back, and the parent may turn any of
    them off.

    No prompts left is a real setting, not a failure: the video plays and
    nothing is asked.
    """
    # An end-of-video question is scheduled relative to the end, and a video
    # whose length nobody could look up has no known end: `duration_s - 3` came
    # out as 3 below zero and then clamped to 0, so Gilli asked "what was your
    # favourite bit?" the instant the video started, before there was anything
    # to have a favourite bit of. Every household without a Google grant hits
    # that, because a length can only be looked up with one.
    #
    # With no end to aim at, the earliest moment the band's own rules allow an
    # interruption is the honest answer: late enough that the child has watched
    # something, and the same threshold every other question obeys. A video
    # shorter than that ends with nothing asked, which is a question missed
    # rather than a question asked at the wrong moment.
    t_sec = (
        max(video.duration_s - rules.END_MARGIN_S, 0)
        if video.duration_s
        else rules.TIMING[band].first_question_s
    )
    prompt = question_bank.pick(band, video.id, disabled_prompts)
    questions = [question_bank.as_question(prompt, t_sec, language)] if prompt else []
    return QuestionPlan(video_id=video.id, age_band=band, language=language, questions=questions)


def ensure_plan(
    video: Video,
    band: AgeBand,
    language: Language,
    store: Store | None = None,
    agent: Agent | None = None,
    freq: QuestionFreq | None = None,
    disabled_prompts: Sequence[str] = (),
) -> QuestionPlan:
    """Cached plan or a fresh one (fetching the transcript if needed)."""
    store = store or get_store()
    cached = store.get_plan(video.id, band, language)
    if cached:
        return cached
    try:
        tr = fetch_transcript(video.id)
    except TranscriptsBlocked as e:
        # The Curator screens without a transcript when it has to; the Planner
        # must be able to as well, or the first video it approves that way
        # takes the whole run down with it. `build_plan` already handles no
        # segments — one general question at the end — and the video is marked
        # "none" so the app still says it was read on its title alone.
        log.info("no transcript for %s, planning from the title: %s", video.id, e)
        tr = {"source": "none", "segments": []}
    plan = build_plan(video, tr["segments"], band, language, freq, agent, disabled_prompts)
    store.put_plan(plan)
    stored = store.get_video(video.id) or video
    stored.transcript_source = tr["source"]
    stored.plan_ready = True
    store.put_video(stored)
    return plan
