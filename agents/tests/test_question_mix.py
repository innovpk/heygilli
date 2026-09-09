"""A plan should not ask a child to do the same thing three times running.

Every question above band 4_6 used to be answered by talking, because those
bands had no other type. A child who is shy, tired, eating, or sitting in a
room with other people had no way into the whole session — and the tap and the
tick that band 4_6 already had were sitting unused.
"""
from __future__ import annotations

from heygilli_agents import rules
from heygilli_agents.schemas import Option, Question


def q(t: int, *, mode: str = "voice", qtype: str = "recall", **kw) -> Question:
    return Question(t_sec=t, type=qtype, input=mode, text=f"q at {t}", **kw)


class TestSelect:
    def test_prefers_a_mode_it_has_not_used_yet(self) -> None:
        # Three spoken and one tap, all within reach of the same slot. The tap
        # is the one a plan of spoken questions is missing.
        got = rules.select(
            [q(100), q(400), q(410, mode="pick")],
            gap=300,
            want=2,
        )
        # 400 is spoken and comes first, but talking has already had its turn.
        assert [x.input for x in got] == ["voice", "pick"]

    def test_still_obeys_the_gap(self) -> None:
        got = rules.select([q(100), q(120, mode="pick"), q(400, mode="pick")], gap=300, want=3)
        assert [x.t_sec for x in got] == [100, 400]

    def test_never_reorders_the_video(self) -> None:
        got = rules.select(
            [q(100), q(500, mode="pick"), q(900, mode="copy")], gap=300, want=3
        )
        assert [x.t_sec for x in got] == sorted(x.t_sec for x in got)

    def test_a_single_question_is_a_spoken_one(self) -> None:
        # Talking carries the most, so when there is room for one it wins.
        got = rules.select([q(100, mode="pick"), q(100)], gap=60, want=1)
        assert got[0].input == "voice"

    def test_cannot_invent_variety_it_was_not_given(self) -> None:
        got = rules.select([q(100), q(400), q(700)], gap=300, want=3)
        assert [x.input for x in got] == ["voice", "voice", "voice"]

    def test_takes_nothing_when_none_is_wanted(self) -> None:
        assert rules.select([q(100)], gap=60, want=0) == []


class TestYesNo:
    def test_writes_both_answers_itself(self) -> None:
        built = rules.build_yes_no(
            Question(t_sec=100, type="yes_no", input="voice", text="Is lava hot?", expected="yes"),
            "en",
        )
        assert built is not None
        assert built.input == "pick"
        assert [o.label for o in built.options] == ["yes", "no"]
        assert [o.correct for o in built.options] == [True, False]

    def test_marks_no_when_no_is_right(self) -> None:
        built = rules.build_yes_no(
            Question(t_sec=100, type="yes_no", input="voice", text="Is lava cold?", expected="no"),
            "en",
        )
        assert built is not None
        assert [o.correct for o in built.options] == [False, True]

    def test_answers_are_in_the_child_s_language(self) -> None:
        built = rules.build_yes_no(
            Question(t_sec=100, type="yes_no", input="voice", text="?", expected="yes"), "ur"
        )
        assert built is not None
        assert [o.label for o in built.options] == ["ہاں", "نہیں"]

    def test_drops_a_question_with_no_right_answer(self) -> None:
        # "Did you like it?" is an opinion wearing a yes/no costume, and there
        # is nothing to mark correct.
        assert (
            rules.build_yes_no(
                Question(t_sec=100, type="yes_no", input="voice", text="Fun?", expected="maybe"),
                "en",
            )
            is None
        )

    def test_the_model_cannot_supply_its_own_options(self) -> None:
        # Three options, both marked correct, labelled by the model: none of it
        # survives, because the options are built here rather than accepted.
        built = rules.build_yes_no(
            Question(
                t_sec=100,
                type="yes_no",
                input="voice",
                text="?",
                expected="yes",
                options=[
                    Option(icon_id="icon_lion", label="definitely", correct=True),
                    Option(icon_id="icon_giraffe", label="nope", correct=True),
                    Option(icon_id="icon_apple", label="maybe", correct=True),
                ],
            ),
            "en",
        )
        assert built is not None
        assert len(built.options) == 2
        assert sum(o.correct for o in built.options) == 1
        assert [o.icon_id for o in built.options] == [rules.YES_ID, rules.NO_ID]


class TestEnforce:
    def test_a_reader_can_now_be_asked_to_tap(self) -> None:
        kept = rules.enforce(
            [
                q(100, mode="voice", qtype="recall"),
                Question(
                    t_sec=400, type="yes_no", input="voice", text="Is lava hot?", expected="yes"
                ),
            ],
            "7_8",
            duration_s=1200,
        )
        assert {k.input for k in kept} == {"voice", "pick"}

    def test_a_yes_no_with_no_answer_never_reaches_a_child(self) -> None:
        kept = rules.enforce(
            [Question(t_sec=100, type="yes_no", input="voice", text="Fun?", expected="hmm")],
            "7_8",
            duration_s=1200,
        )
        assert kept == []


class TestTheBankIsMixedToo:
    """The bank is not a fallback in practice — it is the plan.

    Transcripts are not reachable from the deployed gateway, so nearly every
    session a real child has is built from `question_bank`. A mix that lives
    only in the Planner is a mix almost nobody meets.
    """

    def test_every_band_can_be_answered_without_talking(self) -> None:
        from heygilli_agents import question_bank

        for band in ("4_6", "7_8", "9_11"):
            modes = {p.input for p in question_bank.for_band(band)}
            assert modes - {"voice"}, f"{band} can only be answered by talking"

    def test_a_transcript_less_plan_is_not_all_one_mode(self) -> None:
        from heygilli_agents import planner
        from heygilli_agents.schemas import Video

        # Every band, and many videos. Which prompts a video draws comes from a
        # hash of its id, so one video proves nothing: the first version of
        # this test passed on a lucky id while both reader bands were, in fact,
        # still handing out three spoken questions in a row.
        for band in ("4_6", "7_8", "9_11"):
            for i in range(25):
                self._one_plan_is_mixed(planner, Video, band, f"vid{i}")

    def _one_plan_is_mixed(self, planner, Video, band, video_id) -> None:
        # A long video, so there is room for the target number of questions.
        plan = planner.fallback_plan(
            Video(id=video_id, title="t", description="", duration_s=1800), band, "en"
        )
        assert len(plan.questions) >= 2
        assert len({q.input for q in plan.questions}) > 1, (
            f"{band}/{video_id}: every question is answered the same way"
        )
        # And the tap has something to tap. A pick that arrives with no cards
        # is a blank screen and a listening window that never ends.
        for q in plan.questions:
            if q.input == "pick":
                assert len(q.options) >= 2, f"{q.text!r} is a pick with no cards"
                assert all(o.icon_id for o in q.options)

    def test_an_opinion_pick_cannot_be_answered_wrongly(self) -> None:
        from heygilli_agents.buddy import score_pick
        from heygilli_agents.schemas import Option, Question

        q = Question(
            t_sec=100,
            type="pick_it",
            input="pick",
            text="How did that make you feel?",
            options=[
                Option(icon_id="icon_happy", label="happy"),
                Option(icon_id="icon_sleepy", label="sleepy"),
                Option(icon_id="icon_star", label="amazed"),
            ],
        )
        # Nothing is marked correct, so no tap is a wrong one.
        for i in range(3):
            assert score_pick(q, i).result == "correct"

    def test_a_pick_with_a_right_answer_still_has_a_wrong_one(self) -> None:
        from heygilli_agents.buddy import score_pick
        from heygilli_agents.schemas import Option, Question

        q = Question(
            t_sec=100,
            type="pick_it",
            input="pick",
            text="Which one erupts?",
            options=[
                Option(icon_id="icon_volcano", label="volcano", correct=True),
                Option(icon_id="icon_apple", label="apple"),
                Option(icon_id="icon_lion", label="lion"),
            ],
        )
        assert score_pick(q, 0).result == "correct"
        assert score_pick(q, 1).result == "off_topic"


class TestOnlyTheBankMayAskWithoutARightAnswer:
    """An opinion pick is deliberate. A model forgetting is not.

    `valid_pick` allows a pick with no correct card, because "how did that
    leave you feeling?" has no right answer. That permission is for the
    hand-written bank. If a model writes a question *about the video* and
    forgets to mark which card is right, the child is told they are right
    whatever they tap — the question looks like it worked and taught nothing.
    """

    def _pick(self, **kw):
        from heygilli_agents.schemas import Option, Question

        return Question(
            t_sec=200,
            type="pick_it",
            input="pick",
            text="Which one erupts?",
            options=[
                Option(icon_id="icon_volcano", label="volcano", **kw),
                Option(icon_id="icon_apple", label="apple"),
                Option(icon_id="icon_lion", label="lion"),
            ],
        )

    def test_a_model_pick_with_no_right_answer_is_emptied(self) -> None:
        from heygilli_agents import planner

        repaired = planner.repair_pick(self._pick(correct=False), "en")
        assert repaired.options == []

    def test_and_so_never_reaches_a_child(self) -> None:
        from heygilli_agents import planner, rules
        from heygilli_agents.tools.icons import icon_ids

        repaired = planner.repair_pick(self._pick(correct=False), "en")
        assert rules.enforce([repaired], "7_8", 1200, "en", None, icon_ids()) == []

    def test_while_a_properly_marked_one_survives(self) -> None:
        from heygilli_agents import planner, rules
        from heygilli_agents.tools.icons import icon_ids

        repaired = planner.repair_pick(self._pick(correct=True), "en")
        kept = rules.enforce([repaired], "7_8", 1200, "en", None, icon_ids())
        assert len(kept) == 1
        assert sum(o.correct for o in kept[0].options) == 1
