"""Buddy engine: SPEC 7.4 answer handling, offline."""
from __future__ import annotations

from heygilli_agents.buddy import SessionEngine, phonetic_match, score_pick, to_pick
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.schemas import ClientAnswer, Kid, Option, Question, QuestionPlan, Session
from heygilli_agents.store import LocalStore

PICK = Question(
    t_sec=200, type="pick_it", input="pick", text="Show me the red one.", expected="red",
    options=[Option(icon_id="icon_red", label="red", correct=True),
             Option(icon_id="icon_fish", label="fish"), Option(icon_id="icon_car", label="car")],
)
COPY = Question(t_sec=300, type="copy_it", input="copy", text="Can you roar?", expected="roar")


def name_it(t: int, word: str = "giraffe") -> Question:
    return Question(t_sec=t, type="name_it", input="voice", text="What animal is that?", expected=word,
                    variants=["raffe"], model_line=f"A {word}! Gi-raffe.")


def engine(store: LocalStore, band: str, questions: list[Question], canned=None) -> SessionEngine:
    kid = Kid(household_id="hh", nickname="k", age={"4_6": 5, "7_8": 8, "9_11": 10}[band])
    session = Session(household_id="hh", kid_id=kid.id, video_id="v", age_band=band)
    plan = QuestionPlan(video_id="v", age_band=band, language="en", questions=questions)
    model = FakeModel(canned) if canned else FakeModel()
    return SessionEngine(session, plan, kid, store, agent_factory=lambda: make_agent("buddy", "sys", model=model))


def test_pick_is_deterministic() -> None:
    assert score_pick(PICK, 0).result == "correct"
    assert score_pick(PICK, 1).result == "off_topic"
    assert score_pick(PICK, 1).paraphrase == "fish"
    assert score_pick(PICK, None).result == "unclear"
    assert score_pick(PICK, 7).result == "unclear"


def test_pick_answer_never_calls_the_model(store: LocalStore) -> None:
    e = engine(store, "4_6", [PICK])
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="pick", option=0))
    assert reply.result == "correct" and reply.model_word == "red" and reply.text is None
    assert e._agent is None  # no Strands agent was ever built
    stored = store.list_answers("hh", e.session.id)
    assert len(stored) == 1 and stored[0].result == "correct"


def test_copy_it_is_always_success_and_never_scored(store: LocalStore) -> None:
    e = engine(store, "4_6", [COPY, COPY.model_copy(update={"t_sec": 700})])
    e.ask(0)
    ok = e.answer(ClientAnswer(t="answer", q=0, input="copy"))
    e.ask(1)
    quiet = e.answer(ClientAnswer(t="answer", q=1, input="none"))
    assert ok.result == "correct" and quiet.result == "correct"
    assert ok.gesture == "cheer" and quiet.gesture == "roar"
    assert ok.model_word is None  # the "extra" for copy_it is the sound, not a word
    assert e._agent is None
    assert e.empty_count == 0  # silence on copy_it does not count toward the pick switch
    assert all(a.result == "correct" for a in store.list_answers("hh", e.session.id))


def test_phonetic_matching_is_forgiving() -> None:
    assert phonetic_match("giraffe", "giraffe", []) == "correct"
    assert phonetic_match("a giraffe!", "giraffe", []) == "correct"
    assert phonetic_match("raffe", "giraffe", ["raffe"]) == "correct"
    assert phonetic_match("gaffe", "giraffe", []) == "partial"  # shared first sound
    assert phonetic_match("raff", "giraffe", []) == "partial"  # shared syllable
    assert phonetic_match("", "giraffe", []) == "silence"
    assert phonetic_match("um", "giraffe", []) == "unclear"
    assert phonetic_match("dog", "giraffe", []) is None  # inconclusive -> model decides


def test_prereader_partial_is_treated_as_success(store: LocalStore) -> None:
    e = engine(store, "4_6", [name_it(130)])
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="voice", transcript="gaffe"))
    assert reply.result == "partial"
    assert reply.gesture == "cheer"  # same experience as a confident "giraffe"
    assert reply.model_word == "giraffe"
    assert e.words_said == ["giraffe"]  # counted as a word said
    a = store.list_answers("hh", e.session.id)[0]
    assert a.word_said == "giraffe" and a.paraphrase == "gaffe"
    assert e._agent is None  # phonetics decided; no model call


def test_prereader_model_correct_becomes_partial_success(store: LocalStore) -> None:
    def canned(model: str, text: str) -> dict:
        return {"result": "correct", "paraphrase": "the tall one"} if model == "Score" else {}

    e = engine(store, "4_6", [name_it(130)], canned=canned)
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="voice", transcript="the tall one"))
    assert reply.result == "partial" and reply.model_word == "giraffe"
    assert e.words_said == ["giraffe"]


def test_prereader_off_topic_models_the_word(store: LocalStore) -> None:
    def canned(model: str, text: str) -> dict:
        return {"result": "off_topic", "paraphrase": "dog"} if model == "Score" else {}

    e = engine(store, "4_6", [name_it(130)])
    e._agent_factory = lambda: make_agent("buddy", "sys", model=FakeModel(canned))
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="voice", transcript="dog"))
    assert reply.result == "off_topic" and reply.model_word == "giraffe" and reply.gesture == "point"
    # the spoken line still says the answer word once
    assert e.words_said == []


def test_switch_to_pick_after_two_empty_answers(store: LocalStore) -> None:
    e = engine(store, "4_6", [name_it(130), name_it(500, "lion"), name_it(900, "fish"), name_it(1300, "quasar")])
    e.ask(0)
    e.answer(ClientAnswer(t="answer", q=0, input="none"))
    assert not e.switched_to_pick
    e.ask(1)
    e.answer(ClientAnswer(t="answer", q=1, input="voice", transcript="um"))  # unclear
    assert e.switched_to_pick
    q2 = e.questions[2]
    assert q2.type == "pick_it" and q2.input == "pick"
    assert [o.correct for o in q2.options].count(True) == 1
    assert len({o.icon_id for o in q2.options}) == 3
    assert q2.options[0].icon_id == "icon_fish"
    # a word with no icon degrades to copy_it rather than an impossible pick
    assert e.questions[3].type == "copy_it" and e.questions[3].input == "copy"
    ask = e.ask(2)
    assert ask.input == "pick" and ask.options is not None and ask.text is None
    reply = e.answer(ClientAnswer(t="answer", q=2, input="pick", option=0))
    assert reply.result == "correct"


def test_older_band_uses_model_reply_and_keeps_only_paraphrase(store: LocalStore) -> None:
    q = Question(t_sec=100, type="why", input="voice", text="Why did the ice melt?", expected="the sun warmed it",
                 followup="Ice melts at zero degrees.")
    e = engine(store, "7_8", [q])
    ask = e.ask(0)
    assert ask.text == q.text and ask.listen_ms == 20000
    transcript = "because the sun was shining on it and it got really really hot outside today"
    reply = e.answer(ClientAnswer(t="answer", q=0, input="voice", transcript=transcript))
    assert reply.result == "correct" and reply.gesture == "cheer" and reply.text
    assert reply.model_word is None
    a = store.list_answers("hh", e.session.id)[0]
    assert len(a.paraphrase.split()) <= 10
    assert transcript not in a.model_dump_json()  # never persisted verbatim
    assert e.finished


def test_older_silence_reassures_without_a_model_call(store: LocalStore) -> None:
    q = Question(t_sec=100, type="explain", input="voice", text="How?", expected="x")
    e = engine(store, "9_11", [q])
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="none"))
    assert reply.result == "silence" and "All good" in (reply.text or "")
    assert e._agent is None


def test_due_question_and_end(store: LocalStore) -> None:
    e = engine(store, "4_6", [name_it(130), PICK.model_copy(update={"t_sec": 600})])
    assert e.due_question(100) is None
    assert e.due_question(130.4) == 0
    e.ask(0)
    assert e.due_question(200) is None
    assert e.due_question(601) == 1
    end = e.end()
    assert end.t == "end" and end.words_said == []


def test_to_pick_urdu_labels() -> None:
    q = to_pick(name_it(100), "ur")
    assert q.type == "pick_it" and q.options[0].label == "زرافہ" and "دکھاؤ" in q.text


def test_opinion_pick_never_repeats_the_grader_note() -> None:
    """The bank's opinion prompts carry expected="whichever one they tapped".

    That is a note to the grader, and three separate paths read it out: the
    older-band reply said "Yes, whichever one they tapped!", the pre-reader
    line syllabified it, and the digest listed it as a word the child heard.
    """
    from heygilli_agents import rules
    from heygilli_agents.buddy import opinion_reply, prereader_reply
    from heygilli_agents.question_bank import PROMPTS, as_question

    opinions = [p for p in PROMPTS if p.options and not any(o.correct for o in p.options)]
    assert len(opinions) >= 6
    for prompt in opinions:
        for language in ("en", "ur"):
            q = as_question(prompt, 200, language)
            assert q.is_opinion
            chosen = q.options[0].label
            said, gesture = opinion_reply(q, chosen, language)
            assert said.strip() and gesture == "cheer"
            assert "whichever" not in said.lower()
            assert q.expected not in said
            pre, _ = prereader_reply(q, "correct", chosen, language)
            assert "whichever" not in pre.lower() and q.expected not in pre
            assert rules.default_model_line(q, language) == ""


def test_opinion_pick_models_no_word(store: LocalStore) -> None:
    """A pre-reader is taught the answer word. An opinion has none, so the
    grader note must not arrive as one -- it was also spoken, via `model_word`."""
    feeling = Question(
        t_sec=200, type="pick_it", input="pick", text="How did that make you feel?",
        expected="whichever one they tapped",
        options=[Option(icon_id="icon_happy", label="happy"),
                 Option(icon_id="icon_sleepy", label="sleepy"),
                 Option(icon_id="icon_star", label="amazed")],
    )
    e = engine(store, "4_6", [feeling])
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="pick", option=0))
    assert reply.result == "correct"
    assert reply.model_word is None
    assert "whichever" not in (reply.text or "")


def test_a_real_pick_still_names_the_answer() -> None:
    """The fix must not silence ordinary picks: one marked correct still gets
    the word said back."""
    from heygilli_agents.buddy import prereader_reply
    assert not PICK.is_opinion
    said, _ = prereader_reply(PICK, "correct", "red", "en")
    assert "red" in said.lower()


def test_converted_pick_never_reads_the_grader_note() -> None:
    """`_switch_to_pick` turns voice questions into picks on a device with no
    microphone. 20 of the bank's 22 prompts describe a good answer instead of
    naming one, and `find_icon` matches those a word at a time -- "anything
    unexplained, or an honest no" drew a card saying "no", and the reply then
    read the whole note out."""
    from heygilli_agents.buddy import to_pick
    from heygilli_agents.question_bank import PROMPTS, as_question

    prose = [p for p in PROMPTS if p.input == "voice" and len(p.expected.split()) > 1]
    assert len(prose) >= 14
    for prompt in prose:
        q = as_question(prompt, 200, "en")
        converted = to_pick(q, "en")
        if converted is None:
            continue  # not asked at all is a fine answer
        assert prompt.expected not in converted.text, prompt.id
        assert prompt.expected != converted.expected, prompt.id
        if converted.options:
            assert converted.expected in {o.label for o in converted.options}, prompt.id


def test_older_pick_reply_names_the_card_not_expected(store: LocalStore) -> None:
    """A pick reply says the card the child tapped. `expected` is a note to
    whatever grades the answer, and only band 4_6 ever has it filled from a
    card label, so reading it out was wrong for every older-band pick."""
    from heygilli_agents.schemas import Option as O
    from heygilli_agents.schemas import Question as Q
    q = Q(t_sec=100, type="pick_it", input="pick", text="Which one?",
          expected="a reason, however small",
          options=[O(icon_id="icon_fish", label="fish", correct=True),
                   O(icon_id="icon_car", label="car"), O(icon_id="icon_sun", label="sun")])
    e = engine(store, "9_11", [q])
    e.ask(0)
    reply = e.answer(ClientAnswer(t="answer", q=0, input="pick", option=0))
    assert reply.text and "reason, however small" not in reply.text
    assert "fish" in reply.text.lower()


# --- hints ------------------------------------------------------------------------------


def test_hint_is_the_planners_or_the_bands_and_only_once(store: LocalStore) -> None:
    from heygilli_agents import rules
    from heygilli_agents.schemas import Question, QuestionPlan

    plan = QuestionPlan(video_id="v", age_band="7_8", language="en", questions=[
        Question(t_sec=100, type="recall", input="voice", text="What did it eat?",
                 expected="leaves", hint="Think about what was up in the tree."),
        Question(t_sec=400, type="why", input="voice", text="Why?", expected="sun"),
    ])
    eng = engine(store, "7_8", plan.questions)
    first = eng.hint(0)
    assert first is not None and first.text == "Think about what was up in the tree."
    assert first.speak == first.text and first.listen_ms == rules.listen_ms("7_8")
    assert eng.hint(0) is None, "a second hint for the same question"
    second = eng.hint(1)
    assert second is not None and second.text == rules.generic_hint("7_8", "en")


def test_no_hint_for_copy_it_or_an_opinion(store: LocalStore) -> None:
    from heygilli_agents.schemas import Option, Question, QuestionPlan

    plan = QuestionPlan(video_id="v", age_band="4_6", language="en", questions=[
        Question(t_sec=130, type="copy_it", input="copy", text="Roar!", expected="roar"),
        Question(t_sec=520, type="pick_it", input="pick", text="How did that feel?",
                 expected="whichever", options=[
                     Option(icon_id="icon_happy", label="happy"),
                     Option(icon_id="icon_sleepy", label="sleepy"),
                     Option(icon_id="icon_star", label="amazed"),
                 ]),
        Question(t_sec=900, type="name_it", input="voice", text="What is that?",
                 expected="giraffe", hint="It has a looong neck."),
    ])
    eng = engine(store, "4_6", plan.questions)
    assert eng.hint(0) is None
    assert eng.hint(1) is None
    hint = eng.hint(2)
    assert hint is not None
    assert hint.text is None and hint.speak == "It has a looong neck.", "pre-readers get no text"


def test_the_answer_records_whether_a_hint_was_given(store: LocalStore) -> None:
    from heygilli_agents.schemas import ClientAnswer, Question, QuestionPlan

    plan = QuestionPlan(video_id="v", age_band="7_8", language="en", questions=[
        Question(t_sec=100, type="recall", input="voice", text="a", expected="x"),
        Question(t_sec=400, type="recall", input="voice", text="b", expected="y"),
    ])
    eng = engine(store, "7_8", plan.questions)
    eng.ask(0)
    eng.hint(0)
    eng.answer(ClientAnswer(t="answer", q=0, input="none"))
    eng.ask(1)
    eng.answer(ClientAnswer(t="answer", q=1, input="none"))
    answers = sorted(store.list_answers("hh", eng.session.id), key=lambda a: a.question_idx)
    assert [a.hinted for a in answers] == [True, False]
