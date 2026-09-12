"""Playmate: Gilli's games, and the agent that runs them.

Two games a child can play from the kid shelf: "Find Gilli", where he hides
behind one of a few trees, and "Catch Gilli", where he pops up and a child
taps him before he ducks away. Short on purpose: five rounds a game and a cap
a day, so a game is a pause between videos and never a second thing to be
glued to.

The split is the same as everywhere else in HeyGilli. The agent decides how
hard the next round should be for this child, from how the last ones went,
and what Gilli says about it. The code turns that level into numbers it clamps
per age band, picks where Gilli hides (a model is a poor source of randomness,
and a child would learn its favourite tree), counts the rounds and checks every
line before a child hears it. A model call that fails or is slow falls back to
a fixed rule that does the same job less warmly.

Nothing about the child is sent or stored beyond round results: which round,
whether they won, how many taps. The only thing kept is a count of rounds per
day, for the cap.
"""
from __future__ import annotations

import logging
import random
import re
from typing import Literal

from pydantic import BaseModel, Field
from strands import Agent

from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES
from .schemas import AgeBand, Kid
from .tools.screening import BLOCK_WORDS

log = logging.getLogger(__name__)

#: "find" and "catch" are Gilli's own; the rest are card games the device
#: builds for itself — letters, sums, an animal from a clue, an animal in a
#: crowd — where the gateway's part is the level, the line and the day's count.
GameKind = Literal["find", "catch", "abc", "sums", "guess", "spot"]
QUIZ_GAMES = ("abc", "sums", "guess", "spot")

ROUNDS_PER_GAME = 5
ROUNDS_PER_DAY = 40  # eight games; a pause between videos, not an afternoon
LEVELS = (1, 2, 3, 4, 5)
POPS_PER_ROUND = 5

#: Trees on screen at each level, and the most a band ever gets. A five-year-old
#: with eight trees taps for a minute and gives up; a ten-year-old with three
#: finds him on the first go every time and stops playing.
TREES_BY_LEVEL = {1: 3, 2: 4, 3: 5, 4: 6, 5: 8}
MAX_TREES = {"4_6": 4, "7_8": 6, "9_11": 8}

#: How long Gilli stays up in "Catch", in ms, and the floor for each band.
SHOW_MS_BY_LEVEL = {1: 2200, 2: 1800, 3: 1400, 4: 1100, 5: 850}
MIN_SHOW_MS = {"4_6": 1600, "7_8": 1100, "9_11": 850}

MAX_WORDS = {"4_6": 10, "7_8": 16, "9_11": 18}

PLAYMATE_SYSTEM_PROMPT = f"""You are Gilli, a cheeky, warm palm squirrel playing a quick game with a
child. The game is one of: "find" (Gilli hides behind one of some trees and the child taps trees to
find him), "catch" (Gilli pops up in random places and the child taps him before he ducks away),
"abc" (find a letter, or the word that starts with one), "sums" (counting for the little ones, adding
and taking away, then times and sharing for the older ones), "guess" (Gilli gives a clue and the
child picks the animal), "spot" (find the named animal among many). In the card games a "tap" is one
try at the answer, and Gilli is the one asking, delighted when they get it and cheerfully sneaky
when they do not.

You are given the child's age band, the language, the round about to start, and how the last rounds went.
Decide two things:
- level: 1 (easiest) to 5 (hardest) for the next round. Aim for a child who wins most rounds but has to
  try. After a quick, easy win go up one. After a struggle go down one. Never jump more than one level.
  A child who lost twice in a row goes down, whatever else happened.
- line: what Gilli says out loud as the next round starts, reacting to how the last one went. One short
  sentence, playful and in character (hiding, giggling, being caught, sneaking). Never mention scores,
  numbers or losing; a miss is Gilli being sneaky, never the child being slow. Never ask the child
  anything about themselves. For band 4_6 use very simple words, at most 10. If the language is ur,
  write the line in Urdu.

{SAFETY_RULES}
""".strip()


class PlayRound(BaseModel):
    """What happened in one round, as the app reports it. Nothing else is sent."""

    round: int = Field(ge=1, le=ROUNDS_PER_GAME)
    won: bool = False
    taps: int = Field(default=0, ge=0, le=50)  # "find": taps it took, including the right one
    caught: int = Field(default=0, ge=0, le=POPS_PER_ROUND)  # "catch": how many times he was caught
    level: int = Field(default=1, ge=1, le=5)


class PlayIn(BaseModel):
    game: GameKind
    #: The rounds of this game so far, oldest first; empty when the game starts.
    rounds: list[PlayRound] = Field(default_factory=list, max_length=ROUNDS_PER_GAME)


class PlayDraft(BaseModel):
    """The agent's decision for the next round."""

    level: int = Field(ge=1, le=5)
    line: str = Field(max_length=200)


class PlayTurn(BaseModel):
    """`POST /kids/{id}/play`: the next round, or the end of the game."""

    game: GameKind
    round: int  # the round about to start; 0 once the game is over
    done: bool = False
    level: int = 1
    trees: int = 0  # "find"
    spot: int = 0  # "find": which tree, 0-based
    peek: bool = False  # "find": his tail shows beside the tree
    pops: int = 0  # "catch"
    show_ms: int = 0  # "catch"
    line: str = ""
    tts_url: str = ""
    rounds_left_today: int = 0
    decided_by: Literal["agent", "rule"] = "rule"


def playmate_agent(model=None) -> Agent:
    return make_agent("playmate", PLAYMATE_SYSTEM_PROMPT, model=model)


def band_of(kid: Kid) -> AgeBand:
    return kid.age_band or "7_8"


def language_of(kid: Kid) -> str:
    return kid.languages[0] if kid.languages else "en"


# --- the rule the agent can be replaced by -------------------------------------------------------


def _struggled(r: PlayRound, game: GameKind) -> bool:
    if game in QUIZ_GAMES:
        return not r.won or r.taps >= 3
    if game == "find":
        return not r.won or r.taps >= 4
    return r.caught <= 2


def _breezed(r: PlayRound, game: GameKind) -> bool:
    if game in QUIZ_GAMES:
        return r.won and r.taps <= 1
    if game == "find":
        return r.won and r.taps <= 1
    return r.caught >= POPS_PER_ROUND - 1


def rule_level(game: GameKind, rounds: list[PlayRound]) -> int:
    """The deterministic fallback: up after a breeze, down after a struggle."""
    if not rounds:
        return 1
    last = rounds[-1]
    level = last.level
    if _breezed(last, game):
        level += 1
    elif _struggled(last, game):
        level -= 1
    return max(1, min(5, level))


def settle_level(proposed: int, game: GameKind, rounds: list[PlayRound]) -> int:
    """What the agent proposed, held to the rules it was given.

    One step at a time, and never up after two losses in a row. The prompt
    says both, and this is where they are kept.
    """
    if not rounds:
        return max(1, min(2, proposed))
    last = rounds[-1].level
    level = max(last - 1, min(last + 1, proposed))
    if len(rounds) >= 2 and all(_struggled(r, game) for r in rounds[-2:]):
        level = min(level, last - 1)
    return max(1, min(5, level))


_FIND_START = {
    "en": ["Ready or not, I am hiding!", "Shh! Where did I go?", "I found a new tree. Find me!"],
    "ur": ["میں چھپ گیا! مجھے ڈھونڈو!", "شش! میں کہاں ہوں؟"],
}
_CATCH_START = {
    "en": ["Catch me if you can!", "I am quick today. Try and catch me!", "Here I come, zoom zoom!"],
    "ur": ["پکڑ سکو تو پکڑو!", "میں آ رہا ہوں، جلدی!"],
}
_QUIZ_START = {
    "abc": {"en": ["Letters! Ready?", "Let us play with letters!", "Which one is it? Look closely."],
            "ur": ["حروف کا کھیل! تیار؟"]},
    "sums": {"en": ["Number time! Let us count.", "I love numbers. Ready?", "Here comes a sum!"],
             "ur": ["گنتی کا وقت! تیار؟"]},
    "guess": {"en": ["Who am I? Listen to my clue.", "Guess the animal! Here is a clue.",
                     "I am thinking of an animal..."],
              "ur": ["بوجھو تو جانو! میں کون ہوں؟"]},
    "spot": {"en": ["So many animals! Find the right one.", "Can you spot it? Look carefully.",
                    "Eyes sharp! Find the one I say."],
             "ur": ["اتنے سارے جانور! ڈھونڈو تو۔"]},
}
_QUIZ_WIN = {
    "en": ["You got it! Next one.", "Yes! That is the one. Again?", "Clever! Here comes another."],
    "ur": ["بالکل ٹھیک! اگلا؟", "واہ! یہی تھا۔"],
}
_QUIZ_MISS = {
    "en": ["Tricky one! Let us try another.", "Nearly! Here is a new one.", "Hee hee, sneaky. One more?"],
    "ur": ["مشکل تھا! ایک اور؟", "قریب تھا! نیا سوال۔"],
}
_AFTER_WIN = {
    "en": ["You found me! Again, again!", "Got me! I will hide better now.", "Hee hee! You are good at this."],
    "ur": ["تم نے مجھے ڈھونڈ لیا! پھر سے!", "واہ! تم بہت اچھے ہو۔"],
}
_AFTER_MISS = {
    "en": ["I was so sneaky! One more go.", "Hee hee, I was hiding well. Try again!"],
    "ur": ["میں بہت چالاک تھا! ایک بار اور۔"],
}


def rule_line(game: GameKind, rounds: list[PlayRound], language: str, seed: int) -> str:
    lang = language if language in ("en", "ur") else "en"
    rng = random.Random(seed)
    if game in QUIZ_GAMES:
        if not rounds:
            return rng.choice(_QUIZ_START[game][lang])
        return rng.choice((_QUIZ_MISS if _struggled(rounds[-1], game) else _QUIZ_WIN)[lang])
    if not rounds:
        return rng.choice((_FIND_START if game == "find" else _CATCH_START)[lang])
    return rng.choice((_AFTER_MISS if _struggled(rounds[-1], game) else _AFTER_WIN)[lang])


def end_line(kid: Kid, out_of_rounds_today: bool) -> str:
    if language_of(kid) == "ur":
        return "آج کے لیے بس، میں تھک گیا ہوں۔" if out_of_rounds_today else "بہت مزا آیا! چلو ویڈیو دیکھیں۔"
    if out_of_rounds_today:
        return "Gilli is sleepy now. More games tomorrow!"
    return "That was fun! Back to your videos."


# --- checking what a child will hear ------------------------------------------------------------


def check_line(line: str, band: AgeBand) -> str | None:
    """Why a line may not be spoken to this child, or None when it may."""
    text = line.strip()
    if not text:
        return "empty"
    if len(text.split()) > MAX_WORDS.get(band, 16):
        return "too long"
    if re.search(r"https?://|www\.|@\w", text):
        return "a link or handle"
    if re.search(r"\d", text):
        return "a number"  # scores are not Gilli's business
    low = f" {text.lower()} "
    for w in BLOCK_WORDS:
        if re.search(rf"(?<![a-z]){re.escape(w)}(?![a-z])", low):
            return f"blocked word {w!r}"
    if re.search(r"\b(your|you)\s+(name|address|school|phone|mum|mom|dad|password)\b", low):
        return "asks about the child"
    return None


# --- one turn ----------------------------------------------------------------------------------------


def _params(game: GameKind, level: int, band: AgeBand, rng: random.Random) -> dict:
    if game in QUIZ_GAMES:
        # The device writes the question itself from the level and the band:
        # a letter, a sum, an animal. Nothing here to hand it.
        return {}
    if game == "find":
        trees = min(TREES_BY_LEVEL[level], MAX_TREES.get(band, 6))
        return {
            "trees": trees,
            "spot": rng.randrange(trees),
            # A pre-reader always gets his tail as a clue; others only at the start.
            "peek": band == "4_6" or level <= 2,
        }
    return {"pops": POPS_PER_ROUND, "show_ms": max(SHOW_MS_BY_LEVEL[level], MIN_SHOW_MS.get(band, 1100))}


def next_turn(
    kid: Kid,
    body: PlayIn,
    rounds_left_today: int,
    agent: Agent | None = None,
    rng: random.Random | None = None,
) -> PlayTurn:
    """The next round of `body.game`, or the end of it.

    `agent` is None when the caller wants the rule alone (tests, or no model).
    """
    band = band_of(kid)
    language = language_of(kid)
    rng = rng or random.Random()
    played = len(body.rounds)
    if played >= ROUNDS_PER_GAME or rounds_left_today <= 0:
        return PlayTurn(
            game=body.game, round=0, done=True,
            line=end_line(kid, out_of_rounds_today=rounds_left_today <= 0 and played < ROUNDS_PER_GAME),
            rounds_left_today=max(0, rounds_left_today),
        )

    level = rule_level(body.game, body.rounds)
    line = rule_line(body.game, body.rounds, language, seed=rng.randrange(1 << 30))
    decided_by: Literal["agent", "rule"] = "rule"
    if agent is not None:
        def told(r: PlayRound) -> str:
            if body.game == "find":
                return f"{'found him' if r.won else 'did not find him'} in {r.taps} taps"
            if body.game == "catch":
                return f"caught him {r.caught} of {POPS_PER_ROUND} times"
            return f"{'got it' if r.won else 'did not get it'} in {r.taps} tries"

        history = "\n".join(
            f"- round {r.round}: level {r.level}, {told(r)}" for r in body.rounds
        ) or "- none yet, this is the first round"
        prompt = (
            f"game: {body.game}\nage_band: {band}\nlanguage: {language}\n"
            f"round about to start: {played + 1} of {ROUNDS_PER_GAME}\nrounds so far:\n{history}"
        )
        try:
            draft = structured(agent, prompt, PlayDraft, context={"band": band})
            level = settle_level(draft.level, body.game, body.rounds)
            if (why := check_line(draft.line, band)) is None:
                line = draft.line.strip()
                decided_by = "agent"
            else:
                log.info("playmate line refused (%s): %r", why, draft.line)
        except LLMError as e:
            log.warning("playmate failed, the rule decides: %s", e)

    return PlayTurn(
        game=body.game,
        round=played + 1,
        level=level,
        line=line,
        rounds_left_today=rounds_left_today,
        decided_by=decided_by,
        **_params(body.game, level, band, rng),
    )
