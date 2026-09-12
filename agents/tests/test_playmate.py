"""Gilli's games: the Playmate agent decides, the code clamps and counts. Offline."""
from __future__ import annotations

import random

import pytest
from fastapi.testclient import TestClient

from heygilli_agents import gateway, playmate
from heygilli_agents.fake_model import FakeModel
from heygilli_agents.llm import make_agent
from heygilli_agents.playmate import (
    MAX_TREES,
    MIN_SHOW_MS,
    ROUNDS_PER_DAY,
    ROUNDS_PER_GAME,
    PlayIn,
    PlayRound,
    check_line,
    next_turn,
    rule_level,
    settle_level,
)
from heygilli_agents.schemas import Kid


def kid(age: int, languages=("en",)) -> Kid:
    return Kid(household_id="hh", nickname="k", age=age, languages=list(languages))


def agent_saying(level: int, line: str):
    model = FakeModel(lambda name, text: {"level": level, "line": line})
    return make_agent("playmate", "sys", model=model)


def failing_agent():
    def boom(name, text):
        raise RuntimeError("model down")

    return make_agent("playmate", "sys", model=FakeModel(boom))


# --- the rule ------------------------------------------------------------------------------------------


def test_the_first_round_is_easy() -> None:
    assert rule_level("find", []) == 1


def test_rule_goes_up_after_a_breeze_and_down_after_a_struggle() -> None:
    assert rule_level("find", [PlayRound(round=1, won=True, taps=1, level=2)]) == 3
    assert rule_level("find", [PlayRound(round=1, won=True, taps=5, level=2)]) == 1
    assert rule_level("find", [PlayRound(round=1, won=True, taps=2, level=2)]) == 2
    assert rule_level("catch", [PlayRound(round=1, caught=5, level=3)]) == 4
    assert rule_level("catch", [PlayRound(round=1, caught=1, level=3)]) == 2
    assert rule_level("catch", [PlayRound(round=1, caught=1, level=1)]) == 1


def test_the_agent_moves_one_level_at_a_time() -> None:
    rounds = [PlayRound(round=1, won=True, taps=1, level=2)]
    assert settle_level(5, "find", rounds) == 3
    assert settle_level(1, "find", rounds) == 1
    assert settle_level(4, "find", []) == 2  # the first round never starts hard


def test_two_losses_in_a_row_always_come_down() -> None:
    rounds = [PlayRound(round=1, caught=1, level=3), PlayRound(round=2, caught=0, level=3)]
    assert settle_level(4, "catch", rounds) == 2


# --- what a child hears --------------------------------------------------------------------------------


@pytest.mark.parametrize("line,why", [
    ("", "empty"),
    ("You got 3 of 5!", "a number"),
    ("Visit www.example.com for more", "a link or handle"),
    ("What is your name, friend?", "asks about the child"),
    ("That was a horror of a hiding place", "blocked word 'horror'"),
])
def test_lines_a_child_must_not_hear(line: str, why: str) -> None:
    assert check_line(line, "7_8") == why


def test_prereader_lines_are_short() -> None:
    assert check_line("Hee hee, you found me!", "4_6") is None
    assert check_line("Hee hee, you found me hiding behind that great big leafy tree!", "4_6") == "too long"


# --- one turn -------------------------------------------------------------------------------------------


def test_agent_line_and_level_are_used_when_they_pass() -> None:
    turn = next_turn(kid(8), PlayIn(game="find"), 10, agent=agent_saying(2, "Shh! Find me!"))
    assert turn.decided_by == "agent" and turn.line == "Shh! Find me!"
    assert turn.round == 1 and turn.level == 2 and not turn.done


def test_a_refused_line_falls_back_but_keeps_the_level() -> None:
    rounds = [PlayRound(round=1, won=True, taps=1, level=2)]
    turn = next_turn(kid(8), PlayIn(game="find", rounds=rounds), 10, agent=agent_saying(3, "You scored 10 points!"))
    assert turn.decided_by == "rule" and turn.level == 3
    assert not any(ch.isdigit() for ch in turn.line)


def test_a_failing_model_still_gives_a_round() -> None:
    turn = next_turn(kid(10), PlayIn(game="catch"), 10, agent=failing_agent())
    assert turn.decided_by == "rule" and turn.pops == 5 and turn.show_ms > 0


@pytest.mark.parametrize("age,band", [(5, "4_6"), (8, "7_8"), (11, "9_11")])
def test_numbers_are_clamped_per_band(age: int, band: str) -> None:
    hard = [PlayRound(round=r, won=True, taps=1, level=5) for r in (1, 2, 3)]
    rng = random.Random(1)
    find = next_turn(kid(age), PlayIn(game="find", rounds=hard), 10, agent=agent_saying(5, "Find me!"), rng=rng)
    assert 1 <= find.trees <= MAX_TREES[band] and 0 <= find.spot < find.trees
    catch_rounds = [PlayRound(round=r, caught=5, level=5) for r in (1, 2, 3)]
    catch = next_turn(kid(age), PlayIn(game="catch", rounds=catch_rounds), 10, agent=agent_saying(5, "Zoom!"))
    assert catch.show_ms >= MIN_SHOW_MS[band]


def test_a_prereader_always_sees_his_tail() -> None:
    hard = [PlayRound(round=1, won=True, taps=1, level=5)]
    assert next_turn(kid(5), PlayIn(game="find", rounds=hard), 10).peek is True
    assert next_turn(kid(10), PlayIn(game="find", rounds=hard), 10).peek is False


def test_where_he_hides_is_not_the_models_choice() -> None:
    spots = {next_turn(kid(10), PlayIn(game="find"), 10, rng=random.Random(s)).spot for s in range(40)}
    assert len(spots) > 1


def test_a_game_ends_after_five_rounds() -> None:
    rounds = [PlayRound(round=r, won=True, taps=2) for r in range(1, ROUNDS_PER_GAME + 1)]
    turn = next_turn(kid(8), PlayIn(game="find", rounds=rounds), 10, agent=failing_agent())
    assert turn.done and turn.round == 0 and turn.line == "That was fun! Back to your videos."


def test_urdu_fallback_lines_are_urdu() -> None:
    turn = next_turn(kid(8, languages=("ur",)), PlayIn(game="catch"), 10)
    assert not any("a" <= ch.lower() <= "z" for ch in turn.line)


# --- the endpoint ---------------------------------------------------------------------------------------


@pytest.fixture
def client() -> TestClient:
    return TestClient(gateway.app)


@pytest.fixture
def auth(client: TestClient) -> dict:
    body = client.post("/auth/dev", json={"name": "Play Parent"}).json()
    return {"Authorization": f"Bearer {body['token']}"}


@pytest.fixture
def child(client: TestClient, auth: dict) -> dict:
    return client.post("/kids", json={"nickname": "Abu", "age": 7}, headers=auth).json()


@pytest.fixture(autouse=True)
def fake_playmate(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(playmate, "playmate_agent", lambda: agent_saying(2, "Catch me if you can!"))


def test_play_needs_a_parent_token(client: TestClient, child: dict) -> None:
    assert client.post(f"/kids/{child['id']}/play", json={"game": "find"}).status_code == 401


def test_play_returns_a_round_and_counts_it(client: TestClient, auth: dict, child: dict) -> None:
    r = client.post(f"/kids/{child['id']}/play", json={"game": "catch"}, headers=auth)
    assert r.status_code == 200
    turn = r.json()
    assert turn["round"] == 1 and turn["pops"] == 5 and turn["line"] == "Catch me if you can!"
    assert turn["rounds_left_today"] == ROUNDS_PER_DAY - 1


def test_the_end_of_a_game_is_not_counted(client: TestClient, auth: dict, child: dict) -> None:
    rounds = [{"round": r, "won": True, "taps": 1} for r in range(1, ROUNDS_PER_GAME + 1)]
    turn = client.post(f"/kids/{child['id']}/play", json={"game": "find", "rounds": rounds}, headers=auth).json()
    assert turn["done"] is True and turn["rounds_left_today"] == ROUNDS_PER_DAY


def test_a_day_of_games_runs_out(client: TestClient, auth: dict, child: dict, store) -> None:
    hid = child["household_id"]
    store.put(hid, "play_rounds", gateway._play_key(child["id"]), {"used": ROUNDS_PER_DAY})
    turn = client.post(f"/kids/{child['id']}/play", json={"game": "find"}, headers=auth).json()
    assert turn["done"] is True and turn["line"] == "Gilli is sleepy now. More games tomorrow!"


def test_no_games_once_the_day_is_spent(client: TestClient, auth: dict, child: dict, monkeypatch) -> None:
    from heygilli_agents.schemas import WatchState

    spent = WatchState(watching_allowed=False, blocked_reason="daily_limit", minutes_left_today=0)
    monkeypatch.setattr(gateway, "_watch_state", lambda hid, kid, extra_seconds=0: spent)
    r = client.post(f"/kids/{child['id']}/play", json={"game": "find"}, headers=auth)
    assert r.status_code == 409


def test_a_bad_round_report_is_refused(client: TestClient, auth: dict, child: dict) -> None:
    r = client.post(f"/kids/{child['id']}/play", json={"game": "find", "rounds": [{"round": 9}]}, headers=auth)
    assert r.status_code == 422


# --- the card games: letters, sums, guess, spot -------------------------------------------------


def test_card_games_get_a_level_and_a_line_and_nothing_to_hide_behind() -> None:
    import random

    kid = Kid(household_id="hh", nickname="Zara", age=8)
    for game in playmate.QUIZ_GAMES:
        turn = playmate.next_turn(kid, playmate.PlayIn(game=game, rounds=[]), 40,
                                 rng=random.Random(1))
        assert turn.game == game and turn.round == 1 and turn.level == 1
        assert turn.line and playmate.check_line(turn.line, "7_8") is None
        assert turn.trees == 0 and turn.pops == 0, "card games carry no meadow"


def test_a_card_game_goes_up_after_a_first_try_and_down_after_a_struggle() -> None:
    won_first = [playmate.PlayRound(round=1, won=True, taps=1, level=2)]
    assert playmate.rule_level("abc", won_first) == 3
    three_tries = [playmate.PlayRound(round=1, won=True, taps=3, level=2)]
    assert playmate.rule_level("sums", three_tries) == 1
    two_tries = [playmate.PlayRound(round=1, won=True, taps=2, level=2)]
    assert playmate.rule_level("guess", two_tries) == 2
    assert "sneaky" in playmate.rule_line("spot", three_tries, "en", 3) or "Tricky" in playmate.rule_line(
        "spot", three_tries, "en", 3) or "Nearly" in playmate.rule_line("spot", three_tries, "en", 3)
