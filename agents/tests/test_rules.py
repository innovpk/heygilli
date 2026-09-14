"""SPEC 7.2 / 7.3 as enforced by rules.py, independent of any model."""
from __future__ import annotations

import itertools

import pytest

from heygilli_agents import rules
from heygilli_agents.schemas import Option, Question
from heygilli_agents.tools.icons import icon_ids


def q(t: int, qtype: str, **kw) -> Question:
    inp = {"name_it": "voice", "copy_it": "copy", "pick_it": "pick"}.get(qtype, "voice")
    return Question(t_sec=t, type=qtype, input=inp, text="?", expected=kw.pop("expected", "giraffe"), **kw)


def pick(t: int, ids=("icon_red", "icon_fish", "icon_car"), correct=(True, False, False)) -> Question:
    opts = [Option(icon_id=i, label=i[5:], correct=c) for i, c in zip(ids, correct, strict=True)]
    return Question(t_sec=t, type="pick_it", input="pick", text="Show me.", options=opts)


def test_timing_table_matches_spec() -> None:
    assert rules.TIMING["4_6"] == rules.Timing(120, 240, 360, 2, 15000, "gentle")
    assert rules.TIMING["7_8"] == rules.Timing(90, 180, 300, 6, 20000, "normal")
    assert rules.TIMING["9_11"] == rules.Timing(90, 180, 300, 6, 20000, "normal")
    assert rules.listen_ms("4_6") == 15000 and rules.listen_ms("9_11") == 20000


def test_a_child_gets_long_enough_to_think_of_an_answer() -> None:
    """The window is measured from the moment Gilli stops speaking, and it used
    to be 5 and 8 seconds. That is how long an adult takes to say an answer
    they already had. A child has to notice it is their turn, think, and then
    get the words out, and the video started again while they were still on the
    thinking. Being cut off mid-thought teaches a child not to bother."""
    for band in ("4_6", "7_8", "9_11"):
        assert 15000 <= rules.listen_ms(band) <= 20000, band


def test_min_gap_gentle_cannot_be_raised_for_prereaders() -> None:
    assert rules.min_gap_s("4_6") == 360
    assert rules.min_gap_s("4_6", "normal") == 360
    assert rules.min_gap_s("7_8") == 180
    assert rules.min_gap_s("7_8", "gentle") == 300


@pytest.mark.parametrize(
    "band,duration,expected",
    [("4_6", 120, 1), ("4_6", 299, 1), ("4_6", 600, 2), ("7_8", 100, 1), ("7_8", 900, 6), ("9_11", 1800, 6)],
)
def test_max_questions(band: str, duration: int, expected: int) -> None:
    assert rules.max_questions(band, duration) == expected


def test_no_why_for_prereaders() -> None:
    kept = rules.enforce([q(130, "why"), q(500, "name_it"), q(900, "recall")], "4_6", 1200, icon_ids=icon_ids())
    assert [x.type for x in kept] == ["name_it"]
    assert not rules.type_allowed("4_6", "why")
    assert rules.type_allowed("7_8", "why")


def test_pick_it_needs_three_distinct_real_icons_with_one_correct() -> None:
    ids = icon_ids()
    assert rules.valid_pick(pick(200), ids)
    assert not rules.valid_pick(pick(200, ids=("icon_red", "icon_red", "icon_car")), ids)
    assert not rules.valid_pick(pick(200, correct=(True, True, False)), ids)
    # None correct is an opinion, not a broken question: "how did that leave
    # you feeling?" has no right answer, and `score_pick` accepts any card when
    # nothing is marked. A model that forgets to mark one does not get here —
    # `planner.repair_pick` empties those before the rules see them.
    assert rules.valid_pick(pick(200, correct=(False, False, False)), ids)
    assert not rules.valid_pick(pick(200, ids=("icon_red", "icon_fish", "icon_unicorn_not_in_library")), ids)
    two = pick(200)
    two.options = two.options[:2]
    assert not rules.valid_pick(two, ids)
    # enforce drops the invalid one and keeps the valid one
    kept = rules.enforce([pick(130, correct=(True, True, False)), pick(600)], "4_6", 1200, icon_ids=ids)
    assert len(kept) == 1 and kept[0].t_sec == 600
    assert kept[0].expected == "fish"[:0] + "red"  # filled from the correct option label


def test_first_question_minimum() -> None:
    kept = rules.enforce([q(60, "recall"), q(95, "recall"), q(400, "predict")], "7_8", 900)
    assert [x.t_sec for x in kept] == [95, 400]
    kept = rules.enforce([q(100, "name_it"), q(125, "name_it")], "4_6", 900)
    assert [x.t_sec for x in kept] == [125]


def test_min_gap_drops_the_later_violator() -> None:
    kept = rules.enforce([q(100, "recall"), q(200, "why"), q(281, "predict"), q(500, "recall")], "7_8", 900)
    assert [x.t_sec for x in kept] == [100, 281, 500]
    gentle = rules.enforce([q(100, "recall"), q(300, "why"), q(400, "predict"), q(650, "recall")], "7_8", 900, freq="gentle")
    assert [x.t_sec for x in gentle] == [100, 400]  # 300 < 100+300, 650 < 400+300 -> dropped
    pre = rules.enforce([q(130, "name_it"), q(400, "name_it"), q(500, "name_it")], "4_6", 1200)
    assert [x.t_sec for x in pre] == [130, 500]  # gentle gap 360 for 4_6


def test_a_video_gets_two_or_three_questions_not_as_many_as_will_fit() -> None:
    """Measured against the live gateway: an eight-minute video came back with
    six questions, one every eighty seconds. That is a comprehension test with
    a cartoon in the gaps.

    `max_questions` is the most SPEC 7.3 permits, and the Planner was filling
    it because nothing asked it not to. Three is the bottom of that same range,
    so this stays inside the spec rather than departing from it."""
    many = [q(90 + i * 200, "recall") for i in range(10)]
    kept = rules.enforce(many, "7_8", 3600)
    assert len(kept) == 3
    assert len(kept) <= rules.max_questions("7_8", 3600), "outside what SPEC 7.3 allows"

    # A shorter one gets fewer still: two under five minutes. Three that
    # genuinely fit inside 4m50s and obey the shrunk gap, so the count that
    # comes back is the target's doing and not the spacing's.
    fits = [q(90, "recall"), q(193, "why"), q(296, "predict")]
    assert len(rules.enforce(fits, "7_8", 300)) == 3, "the fixture stopped biting"
    # Ten seconds shorter and the target is two; the spacing has room for
    # three, so the count is the target's doing.
    assert len(rules.enforce([q(90, "recall"), q(193, "why"), q(285, "predict")], "7_8", 290)) == 2

    pre = [q(120 + i * 400, "name_it") for i in range(5)]
    assert len(rules.enforce(pre, "4_6", 3600)) == 2
    assert len(rules.enforce(pre, "4_6", 290)) == 1


def test_short_video_gets_one_mid_video_question() -> None:
    kept = rules.enforce([q(20, "recall"), q(60, "why")], "7_8", 150)
    assert len(kept) == 1
    assert kept[0].t_sec == 60
    assert kept[0].type == "why"


def test_questions_after_the_end_are_dropped() -> None:
    kept = rules.enforce([q(100, "recall"), q(899, "predict")], "7_8", 900)
    assert [x.t_sec for x in kept] == [100]


def test_prereader_input_is_forced_and_defaults_filled() -> None:
    weird = Question(t_sec=130, type="copy_it", input="voice", text="Roar!", expected="roar")
    kept = rules.enforce([weird], "4_6", 900)
    assert kept[0].input == "copy"
    assert kept[0].gesture == "roar"
    assert kept[0].model_line.startswith("Listen to mine!")
    name = rules.enforce([q(130, "name_it")], "4_6", 900)[0]
    assert name.model_line == "A giraffe! Gi-raffe."
    assert rules.enforce([q(130, "name_it", expected="")], "4_6", 900) == []  # nothing to model


def test_syllabify() -> None:
    assert rules.syllabify("giraffe") == "gi-raffe"
    assert rules.syllabify("cat") == "cat"
    assert "-" in rules.syllabify("elephant")


def test_copy_it_without_expected_gets_a_word_to_praise() -> None:
    kept = rules.enforce([Question(t_sec=130, type="copy_it", input="copy", text="Boom!", expected="")], "4_6", 900)
    assert kept[0].expected == "sound" and kept[0].model_line


# --- two or three questions on a five-minute video ------------------------------------------


def test_a_five_minute_video_gets_three_questions_for_a_reader() -> None:
    """Held to the long-video gap, a five-minute video had room for two
    questions for a reader and one for a pre-reader, whatever the target said.
    The gap shrinks to fit the target, never below the band's floor."""
    assert rules.target_questions("7_8", 300) == 3
    assert rules.min_gap_s("7_8", duration_s=300) == max(rules.GAP_FLOOR_S["7_8"], (297 - 90) // 2)
    assert rules.room_for("7_8", 300) == [90, 193, 296]
    assert rules.room_for("9_11", 325) == [90, 206, 322]


def test_a_four_minute_video_gets_two() -> None:
    assert rules.target_questions("7_8", 240) == 2
    assert rules.room_for("7_8", 240) == [90, 237]


def test_a_five_minute_video_gets_two_for_a_pre_reader() -> None:
    assert rules.target_questions("4_6", 300) == 2
    assert rules.min_gap_s("4_6", duration_s=300) == 177
    assert rules.room_for("4_6", 300) == [120, 297]
    # Under five minutes a pre-reader still gets one: the ceiling, not the gap.
    assert rules.target_questions("4_6", 290) == 1
    assert rules.room_for("4_6", 290) == [120]


def test_the_gap_never_shrinks_below_the_floor() -> None:
    for band in ("4_6", "7_8", "9_11"):
        for duration in range(0, 3600, 7):
            gap = rules.min_gap_s(band, duration_s=duration)
            assert rules.GAP_FLOOR_S[band] <= gap <= rules.min_gap_s(band), f"{band}/{duration}"
            slots = rules.room_for(band, duration)
            assert len(slots) <= rules.max_questions(band, duration) or duration <= 0, f"{band}/{duration}"
            assert all(b - a >= gap for a, b in itertools.pairwise(slots)), f"{band}/{duration}"
    # Just over three minutes: two questions, a minute and a half apart.
    assert rules.target_questions("7_8", 190) == 2
    assert rules.room_for("7_8", 190) == [90, 187]


def test_a_long_video_keeps_the_bands_own_gap_and_an_unknown_length_too() -> None:
    assert rules.min_gap_s("7_8", duration_s=1200) == 180
    assert rules.min_gap_s("7_8", duration_s=0) == 180
    assert rules.min_gap_s("4_6", duration_s=1200) == 360


def test_gentle_is_what_the_parent_asked_for_and_is_not_shrunk() -> None:
    assert rules.min_gap_s("7_8", "gentle", 300) == 300
    assert rules.room_for("7_8", 300, "gentle") == [90]


def test_enforce_fits_three_into_five_minutes() -> None:
    kept = rules.enforce(
        [q(90, "recall"), q(193, "why"), q(296, "predict"), q(150, "recall")], "7_8", 300
    )
    assert [x.t_sec for x in kept] == [90, 193, 296]


# --- written cards for a reader ------------------------------------------------------------


def _pick(options: list[Option]) -> Question:
    return Question(t_sec=300, type="pick_it", input="pick", text="Why?", expected="x", options=options)


def test_a_reader_may_be_given_words_where_no_picture_fits() -> None:
    words = _pick([
        Option(icon_id="", label="to cool the brain", correct=True),
        Option(icon_id="", label="to get more sleep"),
        Option(icon_id="", label="to stretch the jaw"),
    ])
    assert rules.valid_pick(words, frozenset({"icon_sun"}), "7_8")
    assert rules.valid_pick(words, frozenset({"icon_sun"}), "9_11")
    assert not rules.valid_pick(words, frozenset({"icon_sun"}), "4_6"), "a pre-reader cannot read a card"
    assert not rules.valid_pick(words, frozenset({"icon_sun"})), "no band means the strict rule"
    assert [o.label for o in rules.enforce([words], "7_8", 900)[0].options] == [
        "to cool the brain", "to get more sleep", "to stretch the jaw"]
    assert rules.enforce([words], "4_6", 900) == []


def test_written_cards_still_need_three_different_non_empty_answers() -> None:
    dup = _pick([Option(label="leaves", correct=True), Option(label="Leaves"), Option(label="bark")])
    assert not rules.valid_pick(dup, None, "7_8")
    blank = _pick([Option(label="leaves", correct=True), Option(label=""), Option(label="bark")])
    assert not rules.valid_pick(blank, None, "7_8")
    mixed = _pick([Option(icon_id="icon_sun", label="the sun", correct=True),
                   Option(label="the moon"), Option(label="a lamp")])
    assert rules.valid_pick(mixed, frozenset({"icon_sun"}), "7_8")
    assert not rules.valid_pick(mixed, frozenset({"icon_car"}), "7_8"), "a picture that is named must exist"
