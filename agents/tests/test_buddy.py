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
