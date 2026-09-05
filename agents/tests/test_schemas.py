from __future__ import annotations

import pytest
from pydantic import TypeAdapter, ValidationError

from heygilli_agents.schemas import (
    Answer,
    ClientMessage,
    Kid,
    Option,
    Question,
    QuestionPlan,
    Score,
    ServerAsk,
    ServerReply,
    Video,
    band_for_age,
    wire,
)


@pytest.mark.parametrize("age,band", [(3, "4_6"), (6, "4_6"), (7, "7_8"), (8, "7_8"), (9, "9_11"), (12, "9_11")])
def test_band_for_age(age: int, band: str) -> None:
    assert band_for_age(age) == band


def test_kid_derives_band_and_gentle_freq() -> None:
    kid = Kid(household_id="hh", nickname="Ayaan", age=5, languages=[])
    assert kid.age_band == "4_6"
    assert kid.question_freq == "gentle"  # SPEC 7.3: cannot be raised
    assert kid.languages == ["en"]
    older = Kid(household_id="hh", nickname="Zara", age=9, question_freq="normal")
    assert older.age_band == "9_11" and older.question_freq == "normal"


def test_kid_round_trip() -> None:
    kid = Kid(household_id="hh", nickname="Zara", age=9, languages=["ur", "en"])
    assert Kid.model_validate(kid.model_dump()) == kid


def test_question_plan_round_trip_and_key() -> None:
    q = Question(
        t_sec=130, type="pick_it", input="pick", text="Show me the red one.", expected="red",
        options=[Option(icon_id="icon_red", label="red", correct=True),
                 Option(icon_id="icon_fish", label="fish"), Option(icon_id="icon_car", label="car")],
    )
    plan = QuestionPlan(video_id="abc", age_band="4_6", language="en", questions=[q])
    again = QuestionPlan.model_validate_json(plan.model_dump_json())
    assert again == plan
    assert QuestionPlan.key("abc", "4_6", "en") == "abc#4_6#en"


def test_paraphrase_is_capped_at_ten_words() -> None:
    long = " ".join(f"w{i}" for i in range(30))
    assert len(Score(result="correct", paraphrase=long).paraphrase.split()) == 10
    a = Answer(session_id="s", question_idx=0, input_used="voice", result="partial", paraphrase=long)
    assert len(a.paraphrase.split()) == 10


def test_video_public_hides_screening() -> None:
    v = Video(id="v1", title="T", description="secret", screening={"topics": ["x"]})
    pub = v.public()
    assert set(pub) == {"id", "channel_id", "title", "duration_s", "thumb_url", "age_ok", "plan_ready"}


def test_wire_drops_none_text_for_prereaders() -> None:
    ask = ServerAsk(q=0, type="name_it", input="voice", text=None, listen_ms=5000)
    assert "text" not in wire(ask)
    reply = ServerReply(result="correct", model_word="giraffe")
    assert wire(reply)["model_word"] == "giraffe" and "text" not in wire(reply)


def test_client_message_union() -> None:
    ta = TypeAdapter(ClientMessage)
    assert ta.validate_python({"t": "hello"}).t == "hello"
    ans = ta.validate_python({"t": "answer", "q": 1, "input": "pick", "option": 2})
    assert ans.option == 2
    with pytest.raises(ValidationError):
        ta.validate_python({"t": "answer", "q": 1, "input": "pick", "option": 3})
    with pytest.raises(ValidationError):
        ta.validate_python({"t": "nope"})
