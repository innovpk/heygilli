"""SPEC 7.2 / 7.3 as enforced by rules.py, independent of any model."""
from __future__ import annotations

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
    assert rules.TIMING["4_6"] == rules.Timing(120, 240, 360, 2, 5000, "gentle")
    assert rules.TIMING["7_8"] == rules.Timing(90, 180, 300, 6, 8000, "normal")
    assert rules.TIMING["9_11"] == rules.Timing(90, 180, 300, 6, 8000, "normal")
    assert rules.listen_ms("4_6") == 5000 and rules.listen_ms("9_11") == 8000


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
    assert not rules.valid_pick(pick(200, correct=(False, False, False)), ids)
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


def test_max_questions_cap_per_band() -> None:
    many = [q(90 + i * 200, "recall") for i in range(10)]
    assert len(rules.enforce(many, "7_8", 3600)) == 6
    pre = [q(120 + i * 400, "name_it") for i in range(5)]
    assert len(rules.enforce(pre, "4_6", 3600)) == 2
    assert len(rules.enforce(pre, "4_6", 290)) == 1


def test_short_video_gets_one_question_at_the_end() -> None:
    kept = rules.enforce([q(20, "recall"), q(60, "why")], "7_8", 150)
    assert len(kept) == 1
    assert kept[0].t_sec == 150 - rules.END_MARGIN_S
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
