"""Bilingual word seeding (PROTOCOL.md "Bilingual word seeding").

For a child whose languages include Urdu, Gilli may offer the Urdu word for
something they have just shown they understand in English, and ask for it back
in a later session. This is the one place the product teaches rather than
checks, and it is opt-in by virtue of the language list.

Where the word comes from matters more than anything else here. **No model
translates anything.** The term is looked up in `shared/icons.json`, the curated
list of concepts that already carries an `en` and a `ur` for each entry, and the
lookup is exact: `find_icon`'s fuzzy matching is right for choosing a picture and
wrong for teaching a word, because a confidently wrong word is worse than no
word. Everything a child hears in the second language was written by a person.

The rules, all enforced here:

- **At most one new word per session.** A child who hears six new words remembers
  none.
- **Never a word for a concept the child has not already got right** in the
  language they are watching in. Candidates come only from answers they got
  right.
- **Asked back only in a later session**, and only for a word Gilli has actually
  modelled and the child has never said.

Delivery is split for a reason. The offer rides on `ServerReply.word` rather than
inside the reply text, because Polly has no Urdu voice: the client speaks the
term with the device's own voice, or drops it and the child simply gets the
English reply (PROTOCOL.md "TTS"). Nothing is ever spoken in silence.
"""
from __future__ import annotations

import logging
from datetime import UTC, date, datetime

from . import analytics
from .schemas import (
    Kid,
    Language,
    Question,
    QuestionPlan,
    ServerReply,
    WordSeed,
    WordTag,
)
from .store import Store
from .tools.icons import library

log = logging.getLogger(__name__)

SECOND_LANGUAGE: Language = "ur"
WINDOW_DAYS = 30  # how far back a word the child got right still counts
MAX_WORD_WORDS = 2  # "ice cream" is a word to learn; a sentence is not


def _today(today: date | None = None) -> str:
    return (today or datetime.now(UTC).date()).isoformat()


def curated_term(word: str, language: Language = SECOND_LANGUAGE) -> str:
    """The curated second-language word for an English one, or "".

    Exact match only, on the icon library's `concept` and `en` fields. The fuzzy
    matching `find_icon` does is fine for picking a picture and not for teaching
    a word: "mouse" fuzzily matching "house" costs a wrong picture in one case
    and a wrong word taught to a child in the other.
    """
    key = " ".join(word.split()).casefold()
    if not key:
        return ""
    for entry in library():
        if key in (entry["concept"].casefold(), entry["en"].casefold()):
            return str(entry.get(language) or "")
    return ""


def seeds(kid: Kid, store: Store) -> dict[str, WordSeed]:
    return {s.term: s for s in store.list_word_seeds(kid.household_id, kid.id)}


def wants_seeding(kid: Kid, language: Language) -> bool:
    """Only for a household that asked, and only into the other language."""
    return SECOND_LANGUAGE in kid.languages and language != SECOND_LANGUAGE


def known_words(
    kid: Kid, store: Store, language: Language = "en", days: int = WINDOW_DAYS,
    today: date | None = None,
) -> list[tuple[str, str]]:
    """`(english, urdu)` for every word this child has actually got right.

    "Got right" is the whole gate: a word is only offered for a concept the
    child has already shown they have in the language they are watching in.
    """
    sessions, answers, plans, _, _ = analytics.load_window(kid, days, store, today)
    by_id = {a.session_id: [] for a in answers}
    for a in answers:
        by_id[a.session_id].append(a)

    out: dict[str, str] = {}
    for s in sessions:
        if s.language != language:
            continue
        plan = plans.get(QuestionPlan.key(s.video_id, s.age_band, s.language))
        if plan is None:
            continue
        for a in by_id.get(s.id, []):
            if a.result not in analytics.UNDERSTOOD or not (0 <= a.question_idx < len(plan.questions)):
                continue
            english = " ".join(plan.questions[a.question_idx].expected.split())
            if not english or len(english.split()) > MAX_WORD_WORDS:
                continue
            term = curated_term(english)
            if term:
                out.setdefault(english.casefold(), term)
    return [(english, term) for english, term in out.items()]


def pick_new(kid: Kid, store: Store, language: Language = "en") -> WordTag | None:
    """One word the child has never been offered, or None."""
    already = seeds(kid, store)
    for english, term in known_words(kid, store, language):
        if term not in already:
            return WordTag(term=term, language=SECOND_LANGUAGE, gloss=english, first_heard=True)
    return None


def pick_ask_back(kid: Kid, store: Store, today: date | None = None) -> WordTag | None:
    """A word Gilli has modelled that the child has never said back.

    Never in the session it was first heard in: "then ask for it in a later
    session" is the point, and asking two minutes after modelling it tests
    memory of the last sentence rather than a word learnt.
    """
    day = _today(today)
    waiting = [
        s for s in seeds(kid, store).values()
        if s.times_heard > 0 and s.times_said == 0 and s.last_heard and s.last_heard < day
    ]
    if not waiting:
        return None
    oldest = min(waiting, key=lambda s: (s.last_heard, s.term))
    return WordTag(term=oldest.term, language=oldest.language, gloss=oldest.gloss, first_heard=False)


# --- putting it in the session ------------------------------------------------


def ask_back_question(tag: WordTag, replacing: Question, language: Language = "en") -> Question:
    """The question that asks for the word back, written in code.

    No model writes this. The English half is a fixed sentence and the answer is
    the curated term, so there is no way for a wrong word to reach the child
    through it.
    """
    text = (
        f"What do we say for {tag.gloss} in Urdu?" if language == "en"
        else f"{tag.gloss} کو اردو میں کیا کہتے ہیں؟"
    )
    return replacing.model_copy(update={
        "text": text,
        "expected": tag.term,
        "variants": [],
        "model_line": tag.term,
        "followup": "",
        "options": [],
        "input": "voice",
        "type": "name_it" if replacing.type in ("name_it", "copy_it", "pick_it") else replacing.type,
        "revisit": None,
        "word": tag,
    })


def seed(
    plan: QuestionPlan, kid: Kid, store: Store, language: Language | None = None,
    today: date | None = None,
) -> QuestionPlan:
    """A copy of this plan carrying at most one word seed, for this session only.

    Like a revisit, this is never written into the cached plan, which is shared
    by every household. An ask-back replaces the last question, and gives way to
    a revisit that is already there: one special question per session is the
    limit, because two makes a session feel like a test.
    """
    language = language or plan.language
    if not wants_seeding(kid, language):
        return plan

    questions = list(plan.questions)
    changed = False

    ask_back = pick_ask_back(kid, store, today)
    if ask_back is not None and len(questions) >= 2 and questions[-1].revisit is None:
        questions[-1] = ask_back_question(ask_back, questions[-1], language)
        changed = True
        log.info("asking %s for the word %r back", kid.id, ask_back.gloss)

    offer = pick_new(kid, store, language)
    if offer is not None:
        for i, q in enumerate(questions):
            if q.revisit is None and q.word is None:
                questions[i] = q.model_copy(update={"word": offer})
                changed = True
                log.info("offering %s the word for %r", kid.id, offer.gloss)
                break

    return plan.model_copy(update={"questions": questions}) if changed else plan


# --- recording what actually happened -----------------------------------------


def record_heard(kid: Kid, store: Store, tag: WordTag, today: date | None = None) -> WordSeed:
    """Gilli modelled the word. Counted when it is actually said out loud to the
    child, not when it was planned."""
    day = _today(today)
    existing = seeds(kid, store).get(tag.term)
    seed_record = WordSeed(
        kid_id=kid.id, term=tag.term, language=tag.language, gloss=tag.gloss or (existing.gloss if existing else ""),
        times_heard=(existing.times_heard if existing else 0) + 1,
        times_said=existing.times_said if existing else 0,
        first_heard=(existing.first_heard if existing and existing.first_heard else day),
        last_heard=day,
    )
    store.put_word_seed(kid.household_id, seed_record)
    return seed_record


def record_said(kid: Kid, store: Store, tag: WordTag) -> WordSeed | None:
    """The child said it back. A word with no record was never modelled, so
    there is nothing honest to count it against."""
    existing = seeds(kid, store).get(tag.term)
    if existing is None:
        return None
    said = existing.model_copy(update={"times_said": existing.times_said + 1})
    store.put_word_seed(kid.household_id, said)
    return said


def after_answer(
    reply: ServerReply, question: Question, kid: Kid, store: Store, today: date | None = None
) -> ServerReply:
    """Attach the offer to the reply, or count the word the child just said.

    The offer only happens on a correct answer: the word is for something the
    child has *just shown they understand*, and following a wrong answer with a
    new word in another language is the opposite of that.
    """
    tag = question.word
    if tag is None:
        return reply
    if tag.first_heard:
        if reply.result != "correct":
            return reply
        record_heard(kid, store, tag, today)
        return reply.model_copy(update={"word": tag})
    if reply.result in ("correct", "partial"):
        record_said(kid, store, tag)
    return reply
