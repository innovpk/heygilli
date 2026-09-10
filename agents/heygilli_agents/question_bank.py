"""The written question bank: what Gilli can ask about any video at all.

Every video used to fall back to one hardcoded question per band — "Can you
clap for the video?" for a five-year-old, every video, for ever. That is not a
fallback, it is a tic, and a child stops answering it by the third time.

These are the questions that need nothing from the video itself. They are
about *watching*, not about content, so they work whether or not a transcript
could be read — which on the deployed gateway is usually not. When a transcript
*is* available the Planner writes questions about what actually happened and
these are not used.

Two rules the bank keeps:

  - **Graded by band, not just labelled.** A four-year-old is asked to make a
    sound or name a thing they can see; a nine-year-old is asked what they
    would tell a friend about it. The types come from `TYPES_FOR_BAND`, so a
    question can only be in a band whose input the child actually has.
  - **The parent may remove any of them.** They are on by default, because a
    child whose parent has not been through a settings screen should still get
    a working app. `Kid.disabled_prompts` holds the ids they turned off, so
    removing one is a fact about that household and not a change to this file.

Ids are permanent. A parent who turned one off has stored its id, so renaming
one silently turns it back on.
"""
from __future__ import annotations

import hashlib
from collections.abc import Sequence

from pydantic import BaseModel, Field

from .schemas import AgeBand, Gesture, InputMode, Language, Option, Question, QuestionType


class Prompt(BaseModel):
    """One question or task, in every language the app speaks.

    Held separately from `Question` because a `Question` is a thing scheduled
    at a second of a particular video, and this is the wording it is made from.
    """

    id: str
    band: AgeBand
    type: QuestionType
    input: InputMode
    gesture: Gesture = "idle"
    #: What the child is asked, per language. Written by hand in both: a
    #: translated question is a question nobody checked.
    text: dict[Language, str]
    #: What a good answer is about. Free text, read by the grader, never shown.
    expected: str = ""
    #: What Gilli says back. Empty means the normal reply.
    model_line: dict[Language, str] = Field(default_factory=dict)
    #: A short label for the parent's list. Never spoken to the child.
    label: str = ""
    #: The cards, for a prompt answered by tapping. None marked `correct` means
    #: there is no right answer and any tap is a good one — see `score_pick`.
    options: tuple[Option, ...] = ()


#: The bank. Order is the order a parent sees, and the order questions are
#: drawn in, so the plainest of each band comes first.
PROMPTS: tuple[Prompt, ...] = (
    # --- 5 to 6: pre-readers. Nothing written, one thing to do, said out loud.
    Prompt(
        id="p46_favourite_part",
        band="4_6", type="name_it", input="voice", gesture="think",
        label="What was your favourite bit?",
        text={"en": "What was your favourite bit?",
              "ur": "تمہیں سب سے اچھا کون سا حصہ لگا؟"},
        expected="anything they liked about the video",
    ),
    Prompt(
        id="p46_who_was_in_it",
        band="4_6", type="name_it", input="voice", gesture="point",
        label="Who was in it?",
        text={"en": "Who was in that video?", "ur": "اس ویڈیو میں کون تھا؟"},
        expected="a character, animal or person from the video",
    ),
    Prompt(
        id="p46_colour_seen",
        band="4_6", type="name_it", input="voice", gesture="point",
        label="Name a colour you saw",
        text={"en": "Can you name a colour you saw?",
              "ur": "کوئی ایک رنگ بتا سکتے ہو جو تم نے دیکھا؟"},
        expected="any colour",
    ),
    Prompt(
        id="p46_clap",
        band="4_6", type="copy_it", input="copy", gesture="cheer",
        label="Clap for the video",
        text={"en": "Can you clap for the video?",
              "ur": "کیا تم ویڈیو کے لیے تالی بجا سکتے ہو؟"},
        expected="clap",
        model_line={"en": "Clap clap! Great clapping!", "ur": "واہ! تالی!"},
    ),
    Prompt(
        id="p46_stretch_tall",
        band="4_6", type="copy_it", input="copy", gesture="stretch",
        label="Stretch up tall",
        text={"en": "Can you stretch up as tall as you can?",
              "ur": "کیا تم جتنا لمبا ہو سکتے ہو اتنا کھڑے ہو سکتے ہو؟"},
        expected="stretch",
        model_line={"en": "So tall! Well done.", "ur": "کتنے لمبے! شاباش۔"},
    ),
    Prompt(
        id="p46_happy_sad",
        band="4_6", type="name_it", input="voice", gesture="think",
        label="Happy or sad?",
        text={"en": "Was that video happy or was it sad?",
              "ur": "کیا وہ ویڈیو خوش تھی یا اداس؟"},
        expected="happy, sad, or how it felt to them",
    ),

    # --- 7 to 8: reading, and can hold one idea to say back.
    Prompt(
        id="p78_favourite_part",
        band="7_8", type="recall", input="voice", gesture="think",
        label="What was your favourite part?",
        text={"en": "What was your favourite part?", "ur": "تمہارا پسندیدہ حصہ کون سا تھا؟"},
        expected="any part of the video",
    ),
    Prompt(
        id="p78_one_new_thing",
        band="7_8", type="recall", input="voice", gesture="think",
        label="One thing you learned",
        text={"en": "Tell me one thing you did not know before.",
              "ur": "مجھے ایک ایسی بات بتاؤ جو تمہیں پہلے نہیں معلوم تھی۔"},
        expected="anything from the video they did not already know",
    ),
    Prompt(
        id="p78_what_happened_first",
        band="7_8", type="recall", input="voice", gesture="point",
        label="What happened first?",
        text={"en": "What happened at the very beginning?",
              "ur": "بالکل شروع میں کیا ہوا تھا؟"},
        expected="the opening of the video",
    ),
    Prompt(
        id="p78_why_liked",
        band="7_8", type="why", input="voice", gesture="think",
        label="Why did you like it?",
        text={"en": "Why did you like that one?", "ur": "تمہیں یہ کیوں پسند آئی؟"},
        expected="a reason, however small",
    ),
    Prompt(
        id="p78_what_next",
        band="7_8", type="predict", input="voice", gesture="think",
        label="What might happen next?",
        text={"en": "If there was more, what do you think would happen next?",
              "ur": "اگر یہ آگے چلتی تو تمہارے خیال میں کیا ہوتا؟"},
        expected="any reasonable guess",
    ),

    # --- 9 to 12: talked to like an older kid, asked to justify.
    Prompt(
        id="p911_tell_a_friend",
        band="9_11", type="explain", input="voice", gesture="think",
        label="Explain it to a friend",
        text={"en": "How would you explain this video to a friend who missed it?",
              "ur": "جس دوست نے یہ ویڈیو نہیں دیکھی، اسے تم کیسے بتاؤ گے؟"},
        expected="a short summary in their own words",
    ),
    Prompt(
        id="p911_best_bit_why",
        band="9_11", type="opinion", input="voice", gesture="think",
        label="Best part, and why",
        text={"en": "What was the best part, and what made it the best?",
              "ur": "سب سے اچھا حصہ کون سا تھا، اور وہ کیوں؟"},
        expected="a part, plus a reason",
    ),
    Prompt(
        id="p911_something_left_out",
        band="9_11", type="apply", input="voice", gesture="think",
        label="What was left out?",
        text={"en": "Is there anything you wanted them to explain and they did not?",
              "ur": "کیا کوئی ایسی بات تھی جو تم چاہتے تھے وہ سمجھاتے مگر انہوں نے نہیں سمجھائی؟"},
        expected="anything unexplained, or an honest no",
    ),
    Prompt(
        id="p911_compare_other",
        band="9_11", type="compare", input="voice", gesture="think",
        label="How did it compare?",
        text={"en": "How was this different from the last one you watched?",
              "ur": "یہ پچھلی ویڈیو سے کس طرح مختلف تھی؟"},
        expected="any difference they can name",
    ),
    Prompt(
        id="p911_would_recommend",
        band="9_11", type="opinion", input="voice", gesture="think",
        label="Would you recommend it?",
        text={"en": "Would you tell someone else to watch this? Why?",
              "ur": "کیا تم کسی اور کو یہ دیکھنے کا کہو گے؟ کیوں؟"},
        expected="yes or no, with a reason",
    ),

    # --- Answered by tapping, in every band.
    #
    # The bank was five spoken questions per reader band, and with no
    # transcript reachable from the deployed gateway the bank *is* the plan —
    # so a child who does not want to talk, or cannot right now, met a session
    # with no way in at all. None of these has a right answer, which is the
    # whole point of them: nothing is marked `correct`, so `score_pick` accepts
    # whatever the child taps and Gilli answers the opinion rather than marking
    # it.
    Prompt(
        id="p46_feeling_pick",
        band="4_6", type="pick_it", input="pick", gesture="think",
        label="How did it make you feel?",
        text={"en": "How did that make you feel?",
              "ur": "اس سے تمہیں کیسا لگا؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_happy", label="happy"),
            Option(icon_id="icon_sleepy", label="sleepy"),
            Option(icon_id="icon_star", label="amazed"),
        ),
    ),
    Prompt(
        id="p46_watch_again",
        band="4_6", type="yes_no", input="pick", gesture="cheer",
        label="Watch one more like it?",
        text={"en": "Would you like another one like that?",
              "ur": "کیا تم ایسی ایک اور دیکھنا چاہو گے؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_yes", label="yes"),
            Option(icon_id="icon_no", label="no"),
        ),
    ),
    Prompt(
        id="p78_feeling_pick",
        band="7_8", type="pick_it", input="pick", gesture="think",
        label="How did it make you feel?",
        text={"en": "How did that video leave you feeling?",
              "ur": "اس ویڈیو کے بعد تمہیں کیسا لگا؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_happy", label="happy"),
            Option(icon_id="icon_sleepy", label="sleepy"),
            Option(icon_id="icon_star", label="amazed"),
        ),
    ),
    Prompt(
        id="p78_learned_something",
        band="7_8", type="yes_no", input="pick", gesture="think",
        label="Did you learn something new?",
        text={"en": "Did you learn something new in that one?",
              "ur": "کیا تم نے اس میں کچھ نیا سیکھا؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_yes", label="yes"),
            Option(icon_id="icon_no", label="no"),
        ),
    ),
    Prompt(
        id="p911_feeling_pick",
        band="9_11", type="pick_it", input="pick", gesture="think",
        label="How did it leave you feeling?",
        text={"en": "How did that one leave you feeling?",
              "ur": "اس ویڈیو کے بعد تمہیں کیسا لگا؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_happy", label="happy"),
            Option(icon_id="icon_sleepy", label="sleepy"),
            Option(icon_id="icon_star", label="amazed"),
        ),
    ),
    Prompt(
        id="p911_trying_to_sell",
        band="9_11", type="yes_no", input="pick", gesture="think",
        label="Was it selling something?",
        text={"en": "Was that video trying to sell you something?",
              "ur": "کیا وہ ویڈیو تمہیں کچھ بیچنے کی کوشش کر رہی تھی؟"},
        expected="whichever one they tapped",
        options=(
            Option(icon_id="icon_yes", label="yes"),
            Option(icon_id="icon_no", label="no"),
        ),
    ),
)


def for_band(band: AgeBand) -> list[Prompt]:
    """Every prompt written for this band, in the order a parent sees them."""
    return [p for p in PROMPTS if p.band == band]


def allowed(band: AgeBand, disabled: Sequence[str] = ()) -> list[Prompt]:
    """The band's prompts this household still permits.

    Opt-out, not opt-in: a parent who has never opened the screen gets all of
    them, because a child whose parent has not been through settings should
    still have a working app. An id in `disabled` that no longer exists is
    ignored rather than an error — the household outlives any one release.
    """
    off = set(disabled)
    return [p for p in for_band(band) if p.id not in off]


def find(prompt_id: str) -> Prompt | None:
    return next((p for p in PROMPTS if p.id == prompt_id), None)


def pick(band: AgeBand, video_id: str, disabled: Sequence[str] = ()) -> Prompt | None:
    """One prompt for this video: the same one every time for the same video,
    a different one for the next.

    Chosen by hashing the video id rather than at random, so a child who comes
    back to a video is asked what they were asked before — the question is part
    of that video for them — while the video after it gets a different one.
    Returns None when the parent has turned the whole band off, which is a
    supported state: the video plays and nothing is asked.
    """
    pool = allowed(band, disabled)
    if not pool:
        return None
    digest = hashlib.sha256(f"{band}:{video_id}".encode()).digest()
    return pool[int.from_bytes(digest[:8], "big") % len(pool)]


def pick_many(
    band: AgeBand, video_id: str, count: int, disabled: Sequence[str] = ()
) -> list[Prompt]:
    """`count` different prompts for this video, or as many as the band has.

    Same rule as `pick`: chosen by hashing the video id, so a child coming back
    to a video meets the questions they met before — they are part of that video
    for them — while the next video gets different ones. Distinct, because being
    asked the same thing twice in one sitting reads as not having been heard the
    first time.
    """
    pool = allowed(band, disabled)
    if not pool or count <= 0:
        return []
    digest = hashlib.sha256(f"{band}:{video_id}".encode()).digest()
    start = int.from_bytes(digest[:8], "big") % len(pool)
    # Strides through the pool from a per-video starting point rather than
    # taking a slice, so two videos that happen to start near each other do not
    # come back with almost the same list.
    step = 1 + (int.from_bytes(digest[8:16], "big") % max(1, len(pool) - 1))
    order: list[Prompt] = []
    seen: set[str] = set()
    for i in range(len(pool)):
        prompt = pool[(start + i * step) % len(pool)]
        if prompt.id in seen:
            continue
        seen.add(prompt.id)
        order.append(prompt)

    # Then spread across ways of answering, in that order.
    #
    # The stride alone gave a whole session of one mode: the reader bands are
    # mostly spoken prompts, so three draws from a hash came back three
    # questions to talk through — measured, on both of them — and the tap
    # prompts sat in the bank never being asked. Taking the least-used mode
    # each time keeps the per-video shuffle (which prompt of that mode) while
    # making sure a child is not asked to do the same thing three times.
    out: list[Prompt] = []
    used: dict[str, int] = {}
    while len(out) < count and order:
        nxt = min(order, key=lambda p: (used.get(p.input, 0), order.index(p)))
        out.append(nxt)
        used[nxt.input] = used.get(nxt.input, 0) + 1
        order.remove(nxt)
    return out


def as_question(prompt: Prompt, t_sec: int, language: Language) -> Question:
    """The prompt, scheduled at a second of one video.

    Falls back to English when a language has no wording rather than showing a
    key or an empty string: a missing translation is a gap in this file, and a
    child should not meet it as silence.
    """
    return Question(
        t_sec=max(t_sec, 0),
        type=prompt.type,
        input=prompt.input,
        text=prompt.text.get(language) or prompt.text["en"],
        expected=prompt.expected,
        gesture=prompt.gesture,
        model_line=prompt.model_line.get(language, "") or prompt.model_line.get("en", ""),
        # Labels stay in English here on purpose: the client reads the word off
        # the icon library, which carries both languages, so a card in an Urdu
        # household is labelled from `shared/icons.json` rather than from a
        # translation copied into this file.
        options=list(prompt.options),
    )
