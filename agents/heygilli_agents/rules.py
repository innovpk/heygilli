"""SPEC §7.2 and §7.3 as code. The Planner model proposes; this module decides.

Every rule here is enforced after the model returns so a weak or misbehaving
provider can never produce a plan that breaks the band contract.
"""
from __future__ import annotations

from dataclasses import dataclass

from .schemas import (
    TYPES_FOR_BAND,
    AgeBand,
    Gesture,
    InputMode,
    Question,
    QuestionFreq,
    QuestionType,
)


@dataclass(frozen=True)
class Timing:
    first_question_s: int
    min_gap_normal_s: int
    min_gap_gentle_s: int
    max_questions: int
    listen_ms: int
    default_freq: QuestionFreq


# SPEC §7.3 timing table.
#
# The listening window used to be 5 seconds for pre-readers and 8 for everyone
# else, and it was measured from the moment Gilli stopped speaking. That is
# about as long as it takes an adult to answer a question they already knew the
# answer to. A child has to hear it, work out that it is their turn, think, and
# then say something — and eight seconds in, while they were still on the
# thinking, the video started playing again. Being cut off mid-thought teaches
# a child not to bother, which is the opposite of the whole point.
#
# 15 and 20 seconds. Pre-readers get less not because they are quicker but
# because they need only one word and will not sit through silence; the older
# bands are answering "why" and "what do you think", which take longer to say
# than to know.
TIMING: dict[str, Timing] = {
    "4_6": Timing(120, 240, 360, 2, 15000, "gentle"),
    "7_8": Timing(90, 180, 300, 6, 20000, "normal"),
    "9_11": Timing(90, 180, 300, 6, 20000, "normal"),
}

SHORT_VIDEO_S = 180  # under 3 minutes: one question at the end, every band
PREREADER_SHORT_S = 300  # 4_6: 1 question under 5 min, 2 above
END_MARGIN_S = 3  # an end-of-video question fires this many seconds before the end

INPUT_FOR_TYPE: dict[str, InputMode] = {
    "name_it": "voice",
    "copy_it": "copy",
    "pick_it": "pick",
}

GESTURE_FOR_TYPE: dict[str, Gesture] = {
    "name_it": "point",
    "copy_it": "roar",
    "pick_it": "point",
    "recall": "think",
    "why": "think",
    "predict": "spin",
    "explain": "think",
    "compare": "stretch",
    "apply": "spin",
    "opinion": "think",
}


def listen_ms(band: AgeBand) -> int:
    return TIMING[band].listen_ms


#: What a video should actually come back with, as against the ceiling below.
#:
#: `max_questions` was the only number the Planner was given, so a model that
#: proposed one question was inside the rules and a child watching a
#: twenty-minute video was asked one thing at minute two and then left alone.
#: Two or three is the shape of the thing: enough that Gilli is watching along,
#: few enough that it is not a comprehension test.
TARGET_QUESTIONS = 3
TARGET_SHORT_S = 8 * 60  # under this, two is plenty


def target_questions(band: AgeBand, duration_s: int) -> int:
    """How many to aim for, never more than the band's ceiling allows."""
    if 0 < duration_s < SHORT_VIDEO_S:
        return 1
    want = 2 if 0 < duration_s <= TARGET_SHORT_S else TARGET_QUESTIONS
    return min(want, max_questions(band, duration_s))


def room_for(band: AgeBand, duration_s: int, freq: QuestionFreq | None = None) -> list[int]:
    """Seconds at which questions could go, spaced by the band's own rules.

    The gap is the binding constraint, not the count: a five-minute video for a
    pre-reader has room for one question and no amount of asking will fit two
    without breaking the spacing the band exists to protect.
    """
    if duration_s <= 0:
        return []
    t = TIMING[band]
    gap = min_gap_s(band, freq)
    last = duration_s - END_MARGIN_S
    slots: list[int] = []
    at = t.first_question_s
    while at <= last and len(slots) < max_questions(band, duration_s):
        slots.append(at)
        at += gap
    return slots


def max_questions(band: AgeBand, duration_s: int) -> int:
    if 0 < duration_s < SHORT_VIDEO_S:
        return 1
    if band == "4_6":
        return 1 if 0 < duration_s < PREREADER_SHORT_S else 2
    return TIMING[band].max_questions


def min_gap_s(band: AgeBand, freq: QuestionFreq | None = None) -> int:
    t = TIMING[band]
    freq = freq or t.default_freq
    if band == "4_6":
        freq = "gentle"  # cannot be raised
    return t.min_gap_gentle_s if freq == "gentle" else t.min_gap_normal_s


def type_allowed(band: AgeBand, qtype: QuestionType) -> bool:
    return qtype in TYPES_FOR_BAND[band]


def syllabify(word: str) -> str:
    """Cheap 'Gi-raffe' style split for the modelled answer word (4_6 only)."""
    word = word.strip()
    if len(word) < 4:
        return word
    vowels = "aeiouy"
    for i in range(1, len(word) - 2):
        if word[i] in vowels and word[i + 1] not in vowels and word[i + 2] in vowels:
            return f"{word[: i + 1]}-{word[i + 1 :]}"
    mid = len(word) // 2
    return f"{word[:mid]}-{word[mid:]}"


def default_model_line(q: Question, language: str) -> str:
    word = q.expected.strip()
    if not word:
        return ""
    if language == "ur":
        return f"{word}! {word}."
    return f"A {word}! {syllabify(word).capitalize()}." if q.type != "copy_it" else f"Listen to mine! {word}!"


def enforce(
    questions: list[Question],
    band: AgeBand,
    duration_s: int,
    language: str = "en",
    freq: QuestionFreq | None = None,
    icon_ids: frozenset[str] | None = None,
) -> list[Question]:
    """Return the subset of `questions` that obeys §7.2/§7.3, shifted and filled in.

    Order of operations, each one deterministic:
      1. drop types not allowed for the band ("why" never reaches a 4_6 plan)
      2. force the input mode for 4_6 types; validate pick_it options
      3. short video (< 3 min) -> exactly one question at the end
      4. sort, then drop anything before the first-question threshold
      5. enforce the minimum gap (gentle for 4_6) by dropping the earlier violator
      6. cap the count for the band and duration
      7. fill model_line and gesture defaults
    """
    kept: list[Question] = []
    for q in questions:
        if not type_allowed(band, q.type):
            continue
        if band == "4_6":
            q = q.model_copy(update={"input": INPUT_FOR_TYPE[q.type]})
        if q.type == "pick_it" or q.input == "pick":
            if not valid_pick(q, icon_ids):
                continue
        else:
            q = q.model_copy(update={"options": []})
        if q.input == "voice" and not q.expected.strip() and q.type in ("name_it",):
            continue  # nothing to model for a pre-reader
        kept.append(q)

    kept.sort(key=lambda q: q.t_sec)
    t = TIMING[band]

    if 0 < duration_s < SHORT_VIDEO_S:
        if not kept:
            return []
        last = kept[-1].model_copy(update={"t_sec": max(duration_s - END_MARGIN_S, 0)})
        return [_fill(last, band, language)]

    kept = [q for q in kept if q.t_sec >= t.first_question_s]
    if duration_s > 0:
        kept = [q for q in kept if q.t_sec <= duration_s - END_MARGIN_S]

    gap = min_gap_s(band, freq)
    spaced: list[Question] = []
    for q in kept:
        if spaced and q.t_sec - spaced[-1].t_sec < gap:
            continue
        spaced.append(q)

    # The target, not the ceiling. `max_questions` is the most SPEC 7.3 permits
    # (3 to 6 for a reader) and the Planner was happily filling it: six
    # questions in an eight-minute video, measured live — one every eighty
    # seconds, which is a comprehension test with a cartoon in the gaps. Three
    # is the bottom of that same SPEC range, so this stays inside it.
    spaced = spaced[: target_questions(band, duration_s)]
    return [_fill(q, band, language) for q in spaced]


def valid_pick(q: Question, icon_ids: frozenset[str] | None) -> bool:
    if len(q.options) != 3:
        return False
    ids = [o.icon_id for o in q.options]
    if len(set(ids)) != 3:
        return False
    if sum(1 for o in q.options if o.correct) != 1:
        return False
    return icon_ids is None or all(i in icon_ids for i in ids)


def _fill(q: Question, band: AgeBand, language: str) -> Question:
    update: dict = {}
    if q.gesture == "idle":
        update["gesture"] = GESTURE_FOR_TYPE.get(q.type, "idle")
    if band == "4_6":
        if q.type == "pick_it" and not q.expected:
            correct = next((o for o in q.options if o.correct), None)
            if correct:
                update["expected"] = correct.label
        if q.type == "copy_it" and not q.expected.strip():
            update["expected"] = "sound" if language == "en" else "آواز"  # "Great sound!" beats "Great !"
        merged = q.model_copy(update=update)
        if not merged.model_line:
            update["model_line"] = default_model_line(merged, language)
    return q.model_copy(update=update)
