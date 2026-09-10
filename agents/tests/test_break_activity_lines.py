"""Break lines built from the activities a parent picked during setup."""

from heygilli_agents import starter_channels
from heygilli_agents.schemas import BreakMessage


def test_a_line_built_from_a_pick_says_which_pick_it_was() -> None:
    # A pre-reader reads nothing on the break screen. Knowing the line is "star
    # jumps" is what lets the client show them a picture of what to do.
    lines = starter_channels.break_messages(["jump", "not-an-activity"])
    assert lines == [
        {"text": "Break time. Star jumps?", "spoken": "Break time. Star jumps?", "activity": "jump"}
    ]
    assert BreakMessage(**lines[0]).activity == "jump"


def test_a_parents_own_line_has_no_activity() -> None:
    assert BreakMessage(text="Break time. Go and say salaam to Nano.").activity == ""
