"""Buddy: the live session engine behind the WebSocket (SPEC §7.4, §7.5).

Deterministic where the spec says so (pick, copy, pre-reader phonetics), a
Strands structured-output call where a child's sentence needs judgement.
Nothing a child says is kept beyond the Score result and a <=10-word paraphrase.
"""
from __future__ import annotations

import logging
import re
import time
from collections.abc import Callable

from strands import Agent

from . import rules
from .llm import LLMError, make_agent, structured
from .planner import SAFETY_RULES
from .schemas import (
    Answer,
    ClientAnswer,
    Gesture,
    Kid,
    Option,
    Question,
    QuestionPlan,
    Result,
    Score,
    ScoredReply,
    ServerAsk,
    ServerEnd,
    ServerHint,
    ServerReady,
    ServerReply,
    Session,
)
from .store import Store
from .tools.icons import find_icon, label_for
from .tools.tts import synthesize

log = logging.getLogger(__name__)

BUDDY_SYSTEM_PROMPT = f"""You are Gilli, a curious, warm, slightly silly co-watching buddy. A child
just answered a question about a video they are watching. Score the answer against the expected
answer and its variants, then write what Gilli says back: one or two short sentences, spoken in
under 6 seconds. Never repeat the question.

Results: correct = the idea is there even if the words differ; partial = part of it or a near miss;
off_topic = an answer about something else; unclear = too little to judge (a word or two of noise).
Reply style by result: correct -> warm confirmation plus ONE extra fact (use the follow-up given);
partial -> build on what they said and complete the idea; off_topic -> accept it warmly, then gently
redirect to the video's idea; unclear -> reassure ("no worries") and move on.

Register: band 7_8 is playful and curious. Band 9_11 drops all baby talk and talks like an older
cousin who finds the topic genuinely interesting; mild humour is fine.
If the child answered in Urdu, reply in Urdu. The paraphrase is at most 10 words and is the only
record kept of what the child said.

{SAFETY_RULES}
""".strip()

PREREADER_MAX_EMPTY = 2  # SPEC §7.4: two empty mic results -> remaining voice questions become pick
SUCCESS: tuple[Result, ...] = ("correct", "partial")


def buddy_agent(model=None) -> Agent:
    return make_agent("buddy", BUDDY_SYSTEM_PROMPT, model=model)


# --- deterministic scoring ------------------------------------------------------------------------


def _norm(text: str) -> str:
    return re.sub(r"[^a-z؀-ۿ0-9 ]", "", text.lower()).strip()


def score_pick(q: Question, option: int | None) -> Score:
    """Which card they tapped, and whether there was a right one to tap.

    A pick with nothing marked correct is a question with no right answer —
    "how did that make you feel?", "would you watch another?" — and a child
    cannot get one of those wrong. Without this it was graded like any other
    pick, so every honest answer came back `off_topic` and Gilli replied to a
    child's own opinion as though they had misunderstood the video.
    """
    if option is None or not (0 <= option < len(q.options)):
        return Score(result="unclear")
    chosen = q.options[option]
    asks_for_an_opinion = not any(o.correct for o in q.options)
    result: Result = "correct" if (asks_for_an_opinion or chosen.correct) else "off_topic"
    return Score(result=result, paraphrase=chosen.label, word_said=None)


def phonetic_match(said: str, expected: str, variants: list[str]) -> Result | None:
    """Forgiving pre-reader matching. None means 'inconclusive, ask the model'."""
    s = _norm(said)
    if not s:
        return "silence"
    targets = [_norm(expected), *(_norm(v) for v in variants)]
    targets = [t for t in targets if t]
    words = s.split()
    for t in targets:
        if t in words or t == s:
            return "correct"
    for t in targets:
        for w in words:
            if w[:1] and w[:1] == t[:1]:  # shared first sound
                return "partial"
            if len(w) >= 3 and any(w[i : i + 3] in t for i in range(len(w) - 2)):  # shared syllable
                return "partial"
    if len(words) == 1 and len(words[0]) <= 2:
        return "unclear"
    return None


# --- reply lines (SPEC §7.4) --------------------------------------------------------------------------


def card_word(q: Question, chosen: str, language: str) -> str:
    """The tapped card's own word, in the language being spoken.

    `score_pick` reports `chosen.label`, which is deliberately English -- the
    client draws the card from the icon library, which carries both languages.
    Echoing the label straight back would put an English word in an Urdu reply.
    """
    for o in q.options:
        if o.label == chosen:
            return label_for(o.icon_id, language)
    return chosen


def opinion_reply(q: Question, chosen: str, language: str) -> tuple[str, Gesture]:
    """Say back what they chose. Never grade an opinion, and never read
    `expected` aloud: on these questions it is a note to the grader."""
    word = card_word(q, chosen, language)
    if language == "ur":
        return (f"واہ! {word}۔" if word else "واہ!"), "cheer"
    return (f"{word.capitalize()}! Thanks for telling me." if word
            else "Thanks for telling me!"), "cheer"


def prereader_reply(q: Question, result: Result, said: str, language: str) -> tuple[str, Gesture]:
    """Every outcome ends with the answer word said clearly once."""
    if q.is_opinion:
        return opinion_reply(q, said, language)
    word = q.expected
    model_line = q.model_line or rules.default_model_line(q, language)
    if q.type == "copy_it":
        if result == "silence":
            return (f"Listen to mine, {word.upper()}!" if language == "en" else f"میری سنو، {word}!"), "roar"
        return (f"Great {word}!" if language == "en" else f"واہ! زبردست {word}!"), "cheer"
    if language == "ur":
        lines = {
            "correct": f"ہاں! {model_line} {q.followup}".strip(),
            "partial": model_line,
            "off_topic": f"میں {word} دیکھ رہا ہوں! {model_line}",
        }
        other = f"{model_line} کیا تم {word} کہہ سکتے ہو؟"
    else:
        heard = said.strip().split()[0].capitalize() if said.strip() else ""
        lines = {
            "correct": f"Yes! {model_line} {q.followup}".strip(),
            "partial": model_line,
            "off_topic": f"{heard}? I see a {word}! {model_line}" if heard else f"I see a {word}! {model_line}",
        }
        other = f"{model_line} Can you say {word}?"
    gestures: dict[str, Gesture] = {"correct": "cheer", "partial": "cheer", "off_topic": "point"}
    return lines.get(result, other), gestures.get(result, q.gesture if q.gesture != "idle" else "point")


def older_silence_reply(band: str, language: str) -> str:
    if language == "ur":
        return "کوئی بات نہیں، چلو دیکھتے رہیں۔"
    return "No worries, let's keep watching." if band == "7_8" else "All good, let's see what happens next."


# --- the engine -------------------------------------------------------------------------------------------


class SessionEngine:
    """Per-session state: which questions were asked, what happened, when to switch modes."""

    def __init__(
        self,
        session: Session,
        plan: QuestionPlan,
        kid: Kid,
        store: Store,
        agent_factory: Callable[[], Agent] | None = None,
    ) -> None:
        self.session = session
        self.kid = kid
        self.store = store
        self.band = plan.age_band
        self.language = plan.language
        self.questions: list[Question] = list(plan.questions)
        self.asked: set[int] = set()
        self.answered: set[int] = set()
        self.empty_count = 0
        self.switched_to_pick = False
        self.words_said: list[str] = []
        self.position_s = 0.0
        self._agent: Agent | None = None
        self._agent_factory = agent_factory or buddy_agent
        self._ask_started: dict[int, float] = {}
        self.hinted: set[int] = set()

    # -- lifecycle
    @property
    def agent(self) -> Agent:
        if self._agent is None:
            self._agent = self._agent_factory()  # lazy: pick/copy sessions never build one
        return self._agent

    @property
    def finished(self) -> bool:
        return len(self.answered) >= len(self.questions)

    def ready(self) -> ServerReady:
        return ServerReady(
            plan_questions=len(self.questions),
            age_band=self.band,
            language=self.language,
            question_times=[q.t_sec for q in self.questions],
        )

    def due_question(self, position_s: float) -> int | None:
        self.position_s = max(self.position_s, position_s)
        for i, q in enumerate(self.questions):
            if i not in self.asked and position_s >= q.t_sec:
                return i
        return None

    def ask(self, idx: int) -> ServerAsk:
        q = self.questions[idx]
        self.asked.add(idx)
        self._ask_started[idx] = time.monotonic()
        slow = self.band == "4_6"
        return ServerAsk(
            q=idx,
            type=q.type,
            input=q.input,
            text=None if self.band == "4_6" else q.text,  # pre-readers get no text on screen
            speak=q.text,  # spoken by the device if Polly has no voice for this language (Urdu)
            tts_url=synthesize(q.text, self.language, slow),
            listen_ms=rules.listen_ms(self.band),
            options=q.options if q.input == "pick" else None,
            gesture=q.gesture,
        )

    def hint(self, idx: int) -> ServerHint | None:
        """What Gilli says when the child has gone quiet on question `idx`.

        Once per question. None for a question that has nothing to hint at:
        a copy-it ("can you roar?") has no answer to nudge towards, and an
        opinion pick has no wrong card. Everything else gets the Planner's
        hint for this moment of the video, or the band's general nudge when
        the question came from the bank or a plan older than hints.
        """
        q = self.questions[idx]
        if idx in self.hinted or q.input == "copy" or q.is_opinion:
            return None
        self.hinted.add(idx)
        text = q.hint.strip() or rules.generic_hint(self.band, self.language)
        slow = self.band == "4_6"
        return ServerHint(
            q=idx,
            text=None if slow else text,
            speak=text,
            tts_url=synthesize(text, self.language, slow),
            listen_ms=rules.listen_ms(self.band),
        )

    def answer(self, msg: ClientAnswer) -> ServerReply:
        q = self.questions[msg.q]
        self.answered.add(msg.q)
        latency = int((time.monotonic() - self._ask_started.get(msg.q, time.monotonic())) * 1000)
        said = (msg.transcript or "").strip()

        if q.input == "copy" or msg.input == "copy":
            score = Score(result="silence" if msg.input == "none" else "correct")
            text, gesture = prereader_reply(q, score.result, "", self.language)
            score = Score(result="correct")  # copy-it is never scored; keep the count as answered
        elif q.input == "pick":
            score = score_pick(q, msg.option if msg.input == "pick" else None)
            if msg.input == "none":
                score = Score(result="silence")
            text, gesture = self._reply_for(q, score, said)
        else:
            score = self._score_voice(q, said if msg.input == "voice" else "")
            text, gesture = self._reply_for(q, score, said)

        self._track_empty(score.result)
        self._persist(msg, q, score, latency)
        return ServerReply(
            text=None if self.band == "4_6" else text,
            tts_url=synthesize(text, self.language, slow=self.band == "4_6"),
            result=score.result,
            gesture=gesture,
            model_word=q.expected if self.band == "4_6" and q.type != "copy_it"
            and not q.is_opinion else None,
        )

    def end(self, line: str | None = None) -> ServerEnd:
        """The goodbye. `line` overrides it when the session is ending for a
        reason of its own — a video stopped for its length says so rather than
        signing off as though it had simply finished."""
        if line is not None:
            return ServerEnd(summary_tts_url=synthesize(line, self.language, self.band == "4_6"),
                             summary_text=line,
                             words_said=list(dict.fromkeys(self.words_said)))
        if self.language == "ur":
            line = "بہت اچھا! پھر ملیں گے۔"
        elif self.band == "4_6":
            line = "That was fun! Bye bye!" if not self.words_said else f"You said {self.words_said[-1]}! Bye bye!"
        else:
            line = "Great watching with you. See you next time!"
        return ServerEnd(summary_tts_url=synthesize(line, self.language, self.band == "4_6"),
                         summary_text=line,
                         words_said=list(dict.fromkeys(self.words_said)))

    # -- internals
    def _score_voice(self, q: Question, said: str) -> Score:
        if not said:
            return Score(result="silence")
        if self.band == "4_6":
            result = phonetic_match(said, q.expected, q.variants)
            if result is not None:
                paraphrase = said if result != "silence" else ""
                return Score(result=result, paraphrase=paraphrase,
                             word_said=q.expected if result in SUCCESS else None)
            score = self._model_score(q, said, Score)
            # Spec: any near miss is a success for a pre-reader; a model "correct" still counts.
            if score.result in SUCCESS:
                score = score.model_copy(update={"result": "partial", "word_said": q.expected})
            return score
        return self._model_score(q, said, ScoredReply)

    def _model_score(self, q: Question, said: str, output_model):
        prompt = (
            f"age_band: {self.band}\nlanguage: {self.language}\n"
            f"question: {q.text}\nexpected: {q.expected}\nvariants: {', '.join(q.variants) or '-'}\n"
            f"follow-up fact to use if correct: {q.followup or '-'}\n"
            f'child said: "{said}"'
        )
        try:
            return structured(self.agent, prompt, output_model)
        except LLMError as e:
            log.warning("buddy scoring failed, treating as unclear: %s", e)
            return output_model(result="unclear", paraphrase="", reply_text="") if output_model is ScoredReply \
                else Score(result="unclear")

    def _reply_for(self, q: Question, score: Score, said: str) -> tuple[str, Gesture]:
        if self.band == "4_6":
            heard = score.paraphrase if q.input == "pick" else said
            return prereader_reply(q, score.result, heard, self.language)
        if score.result == "silence":
            return older_silence_reply(self.band, self.language), "think"
        if isinstance(score, ScoredReply) and score.reply_text:
            g: Gesture = "cheer" if score.result in SUCCESS else "think"
            return score.reply_text, g
        if q.input == "pick":
            if q.is_opinion:
                return opinion_reply(q, score.paraphrase, self.language)
            chose = card_word(q, score.paraphrase, self.language)
            if score.result == "correct":
                return (f"Yes, {chose}! {q.followup}".strip()), "cheer"
            right = next((o for o in q.options if o.correct), None)
            shown = label_for(right.icon_id, self.language) if right else ""
            return f"{chose}? The video showed {shown}. {q.followup}".strip(), "point"
        return older_silence_reply(self.band, self.language), "think"

    def _track_empty(self, result: Result) -> None:
        if self.band != "4_6":
            return
        if result in ("silence", "unclear"):
            self.empty_count += 1
            if self.empty_count >= PREREADER_MAX_EMPTY and not self.switched_to_pick:
                self._switch_to_pick()

    def no_microphone(self) -> None:
        """This device cannot hear anything, so nothing may be asked by voice.

        `_track_empty` reaches the same place after two empty windows, but only
        for pre-readers and only after a child has sat through two questions
        they had no way to answer. A device that says up front it cannot listen
        is not a child being quiet: there is nothing to wait for, at any age.
        """
        if self.switched_to_pick:
            return
        log.info("session %s reported no microphone", self.session.id)
        self._switch_to_pick()

    def _switch_to_pick(self) -> None:
        """SPEC §7.4: remaining voice questions become pick-it for this session."""
        self.switched_to_pick = True
        for i, q in enumerate(self.questions):
            if i in self.asked or q.input != "voice":
                continue
            converted = to_pick(q, self.language)
            if converted is None:
                self.asked.add(i)  # nothing this device can put in front of them
                continue
            self.questions[i] = converted
        log.info("session %s switched remaining voice questions to pick", self.session.id)

    def _persist(self, msg: ClientAnswer, q: Question, score: Score, latency_ms: int) -> None:
        word_said = score.word_said if self.band == "4_6" else None
        if word_said:
            self.words_said.append(word_said)
        self.store.put_answer(
            self.session.household_id,
            Answer(
                session_id=self.session.id,
                question_idx=msg.q,
                input_used=msg.input,
                result=score.result,
                paraphrase=score.paraphrase,
                word_said=word_said,
                latency_ms=latency_ms,
                hinted=msg.q in self.hinted,
            ),
        )


def to_pick(q: Question, language: str) -> Question | None:
    """Turn a voice question into a pick: one real card plus two unrelated icons.

    `expected` usually describes a good answer rather than naming one --
    "anything unexplained, or an honest no" -- and `find_icon` matches a word
    at a time, so that one draws a card saying "no". The question that results
    is coarser than the one written, which is the trade for asking a child who
    cannot answer by voice anything at all. `expected` is rewritten to the card
    actually drawn, so nothing downstream reads the note out.

    None when there is no card and nothing to repeat either: prose with no icon
    behind it would otherwise become "Can you say <the whole note> with me?".
    """
    hit = find_icon(q.expected)
    if not hit:
        if len(q.expected.split()) != 1:
            return None
        text = f"Can you say {q.expected} with me?" if language == "en" else f"میرے ساتھ کہو: {q.expected}"
        return q.model_copy(update={"type": "copy_it", "input": "copy", "text": text, "options": []})
    options = [Option(icon_id=hit["id"], label=hit.get(language) or hit["en"], correct=True)]
    for icon_id in ("icon_car", "icon_fish", "icon_sun", "icon_ball"):
        if len(options) == 3:
            break
        if icon_id != hit["id"]:
            options.append(Option(icon_id=icon_id, label=label_for(icon_id, language)))
    text = f"Show me the {hit['en']}." if language == "en" else f"مجھے {hit['ur']} دکھاؤ۔"
    return q.model_copy(update={"type": "pick_it", "input": "pick", "text": text,
                                "options": options, "expected": hit["en"]})
