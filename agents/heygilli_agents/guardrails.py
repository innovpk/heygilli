"""Guardrails: what an agent's answer must never be, checked before it is used.

Every agent call goes through `structured()`, and every answer that comes back
goes through `check()` first. A `block` violation means the answer is not
used as it is: the agent is told what it broke and asked once more, and if the
second answer breaks a rule too the caller's safe fallback is used instead. A
`warn` is used but recorded, for someone to look at.

These are checks on the output, on top of the rules each prompt already
states. A model told "never say wrong" will, one day, say wrong; this is where
that is caught rather than heard by a five-year-old.

What is checked depends on who will read it. Anything a child hears (a
question, Gilli's reply, a game line, a break line) is held to the child-text
rules. What only a parent reads is held to consistency: a Curator that
approves a video whose own title trips a safety rule, or a digest claiming a
child said a word nobody heard them say.
"""
from __future__ import annotations

import re
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Any, Literal

from .tools.screening import ASK_WORDS, BLOCK_WORDS, _hits

Severity = Literal["block", "warn"]


@dataclass(frozen=True)
class Violation:
    rule: str
    detail: str
    severity: Severity = "block"

    def as_dict(self) -> dict[str, str]:
        return asdict(self)


#: Words a child must not hear from Gilli. The screening's block list, less
#: the two a science video uses honestly ("why is blood red?", "what happens
#: when a star dies"): a question may be about a body or a star.
CHILD_WORDS = tuple(w for w in BLOCK_WORDS if w not in ("blood", "death"))

_PERSONAL = re.compile(
    r"\b(what(?:'s| is)|where(?:'s| is)?|tell me|say)\s+your\s+"
    r"(name|full name|address|school|phone|number|password|home|house|street|surname)\b",
    re.IGNORECASE,
)
_LINK = re.compile(r"https?://|www\.", re.IGNORECASE)
#: SAFETY_RULES: never mock, never "wrong" or "incorrect".
_HARSH = re.compile(r"\b(wrong|incorrect|stupid|dumb|silly you|bad job|you failed|that's not it)\b", re.IGNORECASE)


def child_text(label: str, text: str | None) -> list[Violation]:
    """The rules for anything a child will hear or see."""
    t = text or ""
    out: list[Violation] = []
    if hits := _hits(t, CHILD_WORDS):
        out.append(Violation("unsafe_word", f"{label} says {', '.join(hits)}"))
    if _PERSONAL.search(t):
        out.append(Violation("personal_question", f"{label} asks the child about themselves"))
    if _LINK.search(t):
        out.append(Violation("link", f"{label} contains a link"))
    return out


def _words(text: str) -> int:
    return len((text or "").split())


# --- per output -------------------------------------------------------------------------------------


def _curator(out: Any, ctx: dict) -> list[Violation]:
    v: list[Violation] = []
    if not (out.reason or "").strip():
        v.append(Violation("no_reason", "a verdict with no reason a parent can read", "warn"))
    if out.decision != "approve":
        return v
    seen = f"{ctx.get('title', '')} {ctx.get('description', '')}"
    if hits := _hits(seen, BLOCK_WORDS):
        v.append(Violation("approved_unsafe", f"approved a video whose title or description has: {', '.join(hits)}"))
    if hits := _hits(seen, ASK_WORDS):
        v.append(Violation("approved_without_asking", f"approved without asking, though it mentions: {', '.join(hits)}"))
    if out.concerns:
        v.append(Violation("approved_with_concerns", f"approved while naming concerns: {', '.join(out.concerns)}", "warn"))
    return v


def _plan(out: Any, ctx: dict) -> list[Violation]:
    v: list[Violation] = []
    for i, q in enumerate(out.questions, start=1):
        v += child_text(f"question {i}", q.text)
        v += child_text(f"question {i} follow-up", q.followup)
        v += child_text(f"question {i} model line", q.model_line)
        for o in q.options:
            v += child_text(f"question {i} card", o.label)
    return v


def _reply(out: Any, ctx: dict) -> list[Violation]:
    v = child_text("Gilli's reply", out.reply_text)
    if _HARSH.search(out.reply_text or ""):
        v.append(Violation("harsh_reply", "Gilli's reply tells a child they were wrong"))
    if _words(out.reply_text) > 40:
        v.append(Violation("long_reply", "Gilli's reply is longer than a child will wait for"))
    return v + _score(out, ctx)


def _score(out: Any, ctx: dict) -> list[Violation]:
    if _words(out.paraphrase) > 10:
        return [Violation("long_paraphrase", "the paraphrase, the only record of what a child said, is over ten words")]
    return []


def _play(out: Any, ctx: dict) -> list[Violation]:
    from .playmate import check_line

    why = check_line(out.line, ctx.get("band", "7_8"))
    return [Violation("game_line", f"the game line has {why}")] if why else []


def _revisit(out: Any, ctx: dict) -> list[Violation]:
    return child_text("revisit question", out.text) + child_text("revisit follow-up", out.followup)


def _break_task(out: Any, ctx: dict) -> list[Violation]:
    v = child_text("break title", out.title) + child_text("break line", out.spoken)
    for s in out.steps:
        v += child_text("break step", s)
    return v


def _break_lines(out: Any, ctx: dict) -> list[Violation]:
    v: list[Violation] = []
    for m in out.messages:
        v += child_text("break line", getattr(m, "text", "")) + child_text("break line", getattr(m, "spoken", ""))
    return v


def _digest(out: Any, ctx: dict) -> list[Violation]:
    v: list[Violation] = []
    known = {w.lower() for w in ctx.get("words", ())}
    if "words" in ctx and (invented := [w for w in out.words_heard if w.lower() not in known]):
        v.append(Violation("invented_words", f"the digest says the child heard {', '.join(invented)}, "
                                             "which no question in these sessions used"))
    if not (out.dinner_prompt or "").strip():
        v.append(Violation("no_dinner_prompt", "no dinner question for the parent", "warn"))
    return v


def _answer(out: Any, ctx: dict) -> list[Violation]:
    return [] if (out.answer or "").strip() else [Violation("empty_answer", "the parent asked and got nothing")]


CHECKS: dict[str, Callable[[Any, dict], list[Violation]]] = {
    "CuratorDecision": _curator,
    "PlanDraft": _plan,
    "QuestionPlan": _plan,
    "ScoredReply": _reply,
    "Score": _score,
    "PlayDraft": _play,
    "RevisitDraft": _revisit,
    "BreakTask": _break_task,
    "SuggestedMessages": _break_lines,
    "DigestNarrative": _digest,
    "VideoAnswer": _answer,
}


def check(output_name: str, out: Any, ctx: dict | None = None) -> list[Violation]:
    fn = CHECKS.get(output_name)
    return fn(out, ctx or {}) if fn else []


def blocking(violations: list[Violation]) -> list[Violation]:
    return [v for v in violations if v.severity == "block"]


def feedback(violations: list[Violation]) -> str:
    """What the agent is told when its answer is sent back."""
    rules = "\n".join(f"- {v.detail}" for v in violations)
    return (
        "Your last answer cannot be used, because it broke these rules:\n"
        f"{rules}\n"
        "Give the answer again in the same format, fixing those points and changing nothing else."
    )
