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
    Option,
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
    "yes_no": "pick",
}

#: A yes/no question is a pick with the options written here rather than by the
#: model. The model says what is being asked and which way is right; it never
#: gets to invent the two answers, so it cannot offer "yes", "no" and "maybe",
#: or label them in a language the child does not read.
YES_ID = "icon_yes"
NO_ID = "icon_no"
YES_NO_LABELS: dict[str, tuple[str, str]] = {
    "en": ("yes", "no"),
    "ur": ("ہاں", "نہیں"),
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
    "yes_no": "think",
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
    # An opinion pick's `expected` is a note to the grader, not a word to model:
    # syllabifying it said "A whichever one they tapped! Whichever-one they tapped."
    if q.is_opinion:
        return ""
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
        if q.type == "yes_no":
            # Already built — a bank prompt arrives with its two cards written
            # by hand, and `expected` on those says "whichever one they
            # tapped" because there is no right answer to a "would you watch
            # another?". Rebuilding it from `expected` would throw it away.
            if not is_yes_no_pair(q.options):
                q = build_yes_no(q, language)
                if q is None:
                    continue
            kept.append(q.model_copy(update={"input": "pick"}))
            continue
        if band == "4_6" or q.type in INPUT_FOR_TYPE:
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

    # The target, not the ceiling. `max_questions` is the most SPEC 7.3 permits
    # (3 to 6 for a reader) and the Planner was happily filling it: six
    # questions in an eight-minute video, measured live — one every eighty
    # seconds, which is a comprehension test with a cartoon in the gaps. Three
    # is the bottom of that same SPEC range, so this stays inside it.
    chosen = select(kept, gap, target_questions(band, duration_s))
    return [_fill(q, band, language) for q in chosen]


def build_yes_no(q: Question, language: str) -> Question | None:
    """A yes/no question with its two answers written here, not by the model.

    The model supplies the question and says which way is right, in `expected`.
    Everything else is fixed: two options, in this order, labelled in the
    child's language, with the tick and cross from the icon library. A model
    that returns three options, or labels them in English for an Urdu
    household, or marks both correct, cannot express any of that through this
    function — which is the point of it being a function.

    None when `expected` is not a yes or a no, because there is then no correct
    answer to mark and the question cannot be scored.
    """
    want = q.expected.strip().lower()
    yes_words = {"yes", "true", "ہاں"}
    no_words = {"no", "false", "نہیں"}
    if want in yes_words:
        correct_yes = True
    elif want in no_words:
        correct_yes = False
    else:
        return None
    yes_label, no_label = YES_NO_LABELS.get(language, YES_NO_LABELS["en"])
    return q.model_copy(
        update={
            "input": "pick",
            "options": [
                Option(icon_id=YES_ID, label=yes_label, correct=correct_yes),
                Option(icon_id=NO_ID, label=no_label, correct=not correct_yes),
            ],
        }
    )


#: Which way of answering wins a dead heat. Talking carries the most — it is
#: the one that grows vocabulary — so it takes a tie; the others are here so
#: the order is decided rather than incidental.
MODE_RANK: dict[str, int] = {"voice": 0, "pick": 1, "copy": 2}


def select(questions: list[Question], gap: int, want: int) -> list[Question]:
    """Choose which questions are asked: spaced by the band's gap, and mixed.

    These two used to happen in that order and the second one never had
    anything left to work with. Spacing kept whichever question came first and
    dropped everything within the gap behind it, so by the time a mixing step
    ran, the plan was already decided — and it was decided in favour of
    whatever the model wrote first, which is nearly always a question you
    answer by talking.

    So the choice is made once. Walking forward in time, everything still
    admissible under the gap is gathered; among those inside the next gap's
    worth of video — near enough that taking one costs nothing in pacing — the
    least-used way of answering wins, earliest first to break a tie.

    The result is that three spoken candidates and one tap at roughly the same
    moment yield the tap, and the plan a child meets asks them to talk, to
    choose, and to say yes or no, rather than to talk three times.

    It cannot invent variety. If every candidate is spoken, so is every
    question — that has to be fixed where the questions are written.
    """
    if want <= 0:
        return []
    pool = sorted(questions, key=lambda q: q.t_sec)
    chosen: list[Question] = []
    used: dict[str, int] = {}

    while len(chosen) < want:
        if chosen:
            floor = chosen[-1].t_sec + gap
            eligible = [q for q in pool if q.t_sec >= floor]
        else:
            eligible = list(pool)
        if not eligible:
            break
        # Strictly inside the gap: these are the candidates that taking the
        # earliest would *exclude* anyway, so choosing among them by mode costs
        # nothing. A candidate a full gap later is not an alternative, it is the
        # next question — and treating it as an alternative traded a question
        # for the mix, which is how a three-question plan came back with two.
        soonest = eligible[0].t_sec
        window = [q for q in eligible if q.t_sec < soonest + gap]
        # Least-used mode first, then earliest, and only then a preference for
        # talking. Time beats taste: pulling a later question forward to vary
        # the mode would cost the pacing the gap exists to protect. The last
        # term settles a genuine tie — two questions at the same second — where
        # a spoken answer is worth more than a tap.
        pick = min(
            window,
            key=lambda q: (used.get(q.input, 0), q.t_sec, MODE_RANK.get(q.input, 9)),
        )
        chosen.append(pick)
        used[pick.input] = used.get(pick.input, 0) + 1
        pool = [q for q in pool if q is not pick]

    return chosen


def is_yes_no_pair(options: list[Option]) -> bool:
    """Whether these are already the two yes/no cards."""
    return [o.icon_id for o in options] == [YES_ID, NO_ID]


def valid_pick(q: Question, icon_ids: frozenset[str] | None) -> bool:
    """Whether these cards can be put in front of a child.

    Three distinct pictures the library actually has, and exactly one right
    answer — *or* none at all. None is not a broken question: "how did that
    leave you feeling?" has no right answer, and `score_pick` accepts any card
    when nothing is marked. Requiring exactly one used to drop every one of
    those on the floor, which is how a bank full of them stayed unasked.

    Two marked correct is still wrong, and so is none of them being a picture.
    """
    if len(q.options) != 3:
        return False
    ids = [o.icon_id for o in q.options]
    if len(set(ids)) != 3:
        return False
    if sum(1 for o in q.options if o.correct) > 1:
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
