"""Planner agent: transcript + band + language -> QuestionPlan (SPEC §7, §9.3).

The model proposes questions with Strands structured output; `rules.enforce`
then applies the §7.2/§7.3 contract in code, so the plan the child meets is
correct on any provider. Plans are cached per (video, band, language).
"""
from __future__ import annotations

import logging
from collections.abc import Sequence
from datetime import UTC, datetime

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
Band 5 to 6 (pre-readers). Types allowed: name_it (single word by voice), copy_it (make a sound or
a motion, never scored), pick_it (three pictures, exactly one correct), yes_no.
Goals: vocabulary, naming, colours, counting to 5, animal sounds, basic emotions, one-step instructions.
Ask only about what is visible on the paused frame or heard in the last 30 seconds. Never "why".
Short sentences, stretched key words ("looong"), lots of "let's". `expected` is ONE word.
For pick_it: the two wrong options must be clearly different things (a giraffe, a fish, a car),
never near-misses, and every option label must be a concept from the icon library (use icon_lookup).
`model_line` is the sentence where the buddy says the answer word clearly once, e.g. "A giraffe! Gi-raffe."
""",
    "7_8": """
Band 7 to 8. Types allowed: recall, why, predict (sequence questions count as recall), pick_it,
yes_no.
Goals: recall, cause and effect, prediction, sequencing, new words in context.
Playful and curious; ask "what do you think?". `expected` is a short phrase; add 2-4 `variants`
a child might say. `followup` is one extra fact to share after a correct answer.
""",
    "9_11": """
Band 9 to 12. Types allowed: explain, compare, apply, opinion (with a reason), pick_it, yes_no.
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

Vary how the child answers. Do not write a plan where every question is answered by talking: a
child who is shy, tired, eating, or in a room with other people has no way into a plan like that,
and it is the same skill tested over and over. Across the questions you propose, mix:
  - spoken answers (name_it / recall / why / predict / explain / compare / apply / opinion),
  - pick_it, three options with exactly one right — a real question, not a giveaway,
  - yes_no, for a claim from the video that is plainly true or plainly false.

For yes_no: write the question in `text`, set `expected` to exactly "yes" or "no", and leave
`options` empty — the two answers are added for you. Never write a yes_no question whose answer is
a matter of taste; "did you like it?" has no right answer and must be an opinion instead.

Propose more questions than the maximum you are given, spread across these kinds and across the
video. Which ones are used is decided after you answer, and a plan made only of spoken questions
cannot be mixed afterwards — the variety has to be in what you propose.

Every question is about THIS video: a thing that was said, shown, or happened in it, at or before
`t_sec`. Never a question that could be asked of any video ("did you like it?", "what was your
favourite bit?"). Make the child think: the answer should take a moment of remembering or
reasoning, not be in the question itself, and for pick_it the wrong options must not be
ruled out by the question's own words.

Write a `hint` for every question: one short sentence Gilli says if the child has gone quiet.
A hint points back to the moment in the video ("think about what the giraffe was reaching
for", "it happened right after the egg cracked") or narrows it ("it's the one with the long
neck") — it never says the answer, never says "wrong", and never adds a new fact. For pick_it,
the hint may rule out one card. For copy_it, leave `hint` empty.

{SAFETY_RULES}
""".strip()

# Distinct, unrelated distractors used when a pick_it needs repairing (never near-misses).
DISTRACTOR_POOL = ("icon_car", "icon_fish", "icon_sun", "icon_ball", "icon_tree", "icon_house")


def planner_agent(model=None) -> Agent:
    return make_agent("planner", PLANNER_SYSTEM_PROMPT, tools=[icon_lookup, list_icons], model=model)


#: How much of a transcript the Planner is given, named rather than left to
#: `transcript_text`'s default so that the number is arguable.
#:
#: It is the model bill: input is 97% of it (11.66M tokens against 320K out)
#: and almost all of that is this string, on the one call that runs per band
#: and per language. So 6000 was tried, and the eval refused it — 11 of 18
#: cells against 16, with draft violations going from 23 to 242. Half a
#: transcript is not half a plan; the model stops seeing the end of the video
#: and starts writing questions the timing rules then throw away.
#:
#: Cheaper plans have to come from somewhere else — a smaller model on the
#: roles that only skim, or sending the segments that matter rather than the
#: first N characters. Not from this number.
PLAN_TRANSCRIPT_CHARS = 12000


def plan_prompt(video: Video, segments: list[dict], band: AgeBand, language: Language, freq) -> str:
    t = rules.TIMING[band]
    return (
        f"age_band: {band}\nlanguage: {language}\nduration_s: {video.duration_s}\n"
        f"title: {video.title}\n"
        f"types allowed: {', '.join(TYPES_FOR_BAND[band])}\n"
        f"first question no earlier than: {t.first_question_s}s\n"
        f"minimum gap between questions: {rules.min_gap_s(band, freq)}s\n"
        f"questions that will be asked: {rules.target_questions(band, video.duration_s)}\n"
        f"propose at least this many candidates: "
        f"{2 * rules.target_questions(band, video.duration_s) + 2}\n"
        f"{BAND_GUIDE[band].strip()}\n\n"
        f"Transcript:\n{transcript_text(segments, max_chars=PLAN_TRANSCRIPT_CHARS)}\n\n"
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
    source: str = "transcript",
) -> QuestionPlan:
    """Ask the model, then enforce the band contract in code.

    `source` names where `segments` came from and is written onto the plan;
    a plan that ends up made of bank questions is marked "none" whatever was
    passed, because that is what it is.
    """
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
    kept = top_up(kept, video, band, language, freq, disabled_prompts)
    return QuestionPlan(
        video_id=video.id, age_band=band, language=language, questions=kept, source=source
    )


def top_up(
    kept: list[Question],
    video: Video,
    band: AgeBand,
    language: Language,
    freq: QuestionFreq | None = None,
    disabled_prompts: Sequence[str] = (),
) -> list[Question]:
    """Bring a thin plan up to the target with questions from the bank.

    The Planner was given a ceiling and no floor, so one question was inside the
    rules — and a child watching twenty minutes was asked a single thing at
    minute two and then left to it. The model is the right author of a question
    about *this* video and the wrong thing to depend on for how many there are,
    so the count is guaranteed here.

    Only into slots the band's own spacing leaves free, and never past the
    ceiling: a plan that met the target by crowding two questions into a minute
    would be worse than a short one.
    """
    want = rules.target_questions(band, video.duration_s)
    if len(kept) >= want:
        return kept
    gap = rules.min_gap_s(band, freq)
    free = [
        slot
        for slot in rules.room_for(band, video.duration_s, freq)
        if all(abs(slot - q.t_sec) >= gap for q in kept)
    ]
    if not free:
        return kept
    prompts = question_bank.pick_many(band, video.id, want - len(kept), disabled_prompts)
    added = [
        question_bank.as_question(prompt, slot, language)
        for prompt, slot in zip(prompts, free, strict=False)
    ]
    if not added:
        return kept
    return rules.enforce(
        kept + added, band, video.duration_s, language, freq, icon_ids()
    )


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
        # Emptied rather than passed on. `valid_pick` now allows a pick with
        # nothing marked correct, because an opinion question — "how did that
        # leave you feeling?" — genuinely has no right answer. That is a thing
        # the bank writes on purpose, not a thing a model gets to do by
        # forgetting: a comprehension question with no correct card would tell
        # a child they were right whatever they tapped.
        return q.model_copy(update={"options": []})
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
    # One question used to be the whole of a transcript-less plan, and with no
    # transcripts reachable from the deployed gateway that was every video a
    # child ever saw: one question, at the very end, and nothing else the whole
    # way through. The bank has more than one thing to ask.
    want = rules.target_questions(band, video.duration_s)
    # A full gap clear of the end-of-video question, not merely before it: a
    # four-year-old was getting one at 2:00 and another at 6:37 of a 6:40 video,
    # 277 seconds apart where that band's own spacing asks for 360.
    gap = rules.min_gap_s(band)
    slots = [
        slot for slot in rules.room_for(band, video.duration_s) if slot <= t_sec - gap
    ][: want - 1]
    prompts = question_bank.pick_many(band, video.id, len(slots) + 1, disabled_prompts)
    questions = [
        question_bank.as_question(prompt, at, language)
        for prompt, at in zip(prompts, [*slots, t_sec], strict=False)
    ]
    return QuestionPlan(
        video_id=video.id, age_band=band, language=language, questions=questions, source="none"
    )


def trim_cached(plan: QuestionPlan, video: Video, band: AgeBand, store: Store) -> QuestionPlan:
    """Bring a plan written under an older count down to the current target.

    Plans are cached per video and shared by every household, so lowering the
    number of questions changed nothing for any video already planned — a
    five-minute video went on handing out the six it was given the first time,
    to everyone, for ever.

    Trimming rather than re-planning: the questions are already in order and
    already spaced, so the first few are a correct plan for this video, and a
    model call to rediscover that would be paid for by a child waiting.
    """
    want = rules.target_questions(band, video.duration_s)
    if len(plan.questions) <= want:
        return plan
    # Through `select`, not a slice: taking the first few keeps whatever the
    # model happened to write first, and what it writes first is nearly always
    # a spoken question. A cached plan trimmed that way is exactly the
    # all-talking plan the mix exists to prevent.
    kept = rules.select(plan.questions, rules.min_gap_s(band), want)
    trimmed = plan.model_copy(update={"questions": kept})
    store.put_plan(trimmed)
    log.info(
        "trimmed cached plan for %s/%s from %d to %d",
        video.id, band, len(plan.questions), want,
    )
    return trimmed


#: How long a plan written without a transcript is served before the
#: transcript is looked for again. Not on every session: a video Gemini
#: cannot read would otherwise cost a model call, and a child's wait, every
#: time it was watched.
REPLAN_FALLBACK_AFTER_S = 60 * 60


def is_stale_fallback(plan: QuestionPlan, video: Video) -> bool:
    """A cached plan made of bank questions that is old enough to try again.

    Plans are cached per video and shared by every household, and one written
    while no transcript source could answer — every video, on the deployed
    gateway, for as long as it had no Gemini key — stayed the plan for that
    video for ever. Fixing the key fixed nothing a child could see.

    Plans from before `source` existed carry "": for those the video's own
    record says whether it was ever read.
    """
    source = plan.source or (video.transcript_source or "")
    if source != "none":
        return False
    try:
        written = datetime.fromisoformat(plan.created_at)
    except ValueError:
        return True
    if written.tzinfo is None:
        written = written.replace(tzinfo=UTC)
    return (datetime.now(UTC) - written).total_seconds() >= REPLAN_FALLBACK_AFTER_S


def ensure_plan(
    video: Video,
    band: AgeBand,
    language: Language,
    store: Store | None = None,
    agent: Agent | None = None,
    freq: QuestionFreq | None = None,
    disabled_prompts: Sequence[str] = (),
) -> QuestionPlan:
    """Cached plan or a fresh one (fetching the transcript if needed).

    A cached plan that was written without a transcript is tried again once
    it is old enough (`is_stale_fallback`): if the words can be read now, the
    bank questions are replaced with questions about the video. If they still
    cannot, the fallback is rewritten with a fresh timestamp and served for
    another while.
    """
    store = store or get_store()
    cached = store.get_plan(video.id, band, language)
    if cached and not is_stale_fallback(cached, store.get_video(video.id) or video):
        return trim_cached(cached, video, band, store)
    if cached:
        log.info("plan for %s/%s/%s was written without a transcript; trying again",
                 video.id, band, language)
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
    plan = build_plan(
        video, tr["segments"], band, language, freq, agent, disabled_prompts, source=tr["source"]
    )
    store.put_plan(plan)
    stored = store.get_video(video.id) or video
    stored.transcript_source = tr["source"]
    stored.plan_ready = True
    store.put_video(stored)
    return plan
