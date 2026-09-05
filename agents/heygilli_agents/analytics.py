"""Parent analytics: a kid's window of sessions -> the Analytics payload in PROTOCOL.md.

Two halves, deliberately separated:

* `aggregate()` and everything above it are **pure functions** over records handed in.
  No store, no network, no model. That is what `tests/test_analytics.py` exercises.
* `write_note()` makes the single model call (Digest agent, structured output) and
  `cached_note()` memoises it per (kid, window end date, rounded inputs) so re-opening
  the parent screen costs nothing. `run_analytics()` wires both to the store.

Privacy (SPEC 12): the only child-derived strings that leave this module are the words
Gilli asked for (`Question.expected`) and concept labels derived from the *question*, never
from what the child said. The note model is given counts, never speech.
"""
from __future__ import annotations

import hashlib
import json
import logging
import re
from collections import defaultdict
from collections.abc import Mapping, Sequence
from datetime import UTC, date, datetime, timedelta

from strands import Agent

from .llm import make_agent, structured
from .planner import SAFETY_RULES
from .schemas import (
    Analytics,
    AnalyticsDay,
    AnalyticsNote,
    AnalyticsTotals,
    AnalyticsVocabulary,
    Answer,
    Channel,
    ChannelStat,
    ConceptStat,
    EmergingWord,
    Kid,
    NeedsAnotherLook,
    Question,
    QuestionPlan,
    Session,
    Video,
    VocabWord,
    now_iso,
)
from .store import Store

log = logging.getLogger(__name__)

MIN_DAYS = 7
MAX_DAYS = 90
DEFAULT_DAYS = 14
NEW_WORD_DAYS = 7  # "new this week"
VOCAB_MAX_WORDS = 3  # "Olympus Mons" is a word to learn; a 9_11 explain answer is a sentence
SHAKY_DAYS_FOR_REVIEW = 2  # shaky on 2+ separate days before a concept is worth surfacing
CONCEPT_MAX_WORDS = 6
ANSWERED = ("correct", "partial", "off_topic")  # the child produced something
UNDERSTOOD = ("correct",)
SHAKY = ("partial", "off_topic", "unclear")  # silence is not evidence of not understanding


def clamp_days(days: int) -> int:
    return max(MIN_DAYS, min(MAX_DAYS, days))


def window_dates(days: int, today: date | None = None) -> list[str]:
    """Every date in the window, oldest first, so the client can draw one bar per day."""
    end = today or datetime.now(UTC).date()
    start = end - timedelta(days=clamp_days(days) - 1)
    return [(start + timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]


# --- concept labels ------------------------------------------------------------------------------
#
# A "concept" is what a question was about. It is derived from the question, never from the answer
# the child gave, in this order:
#
#   1. `Question.expected` when it is already short (<= 6 words after dropping a leading
#      "because"/"to"/"the"). The expected answer *is* the idea being tested, which is the same
#      shape SPEC 6.5 uses for digest `understood` ("volcanoes erupt when pressure builds").
#   2. otherwise the subject of `Question.text`: drop the question stem ("Can you remember"),
#      drop leading filler and auxiliaries, cut at the first clause marker, cap at 6 words.
#   3. otherwise the video title, otherwise "This video".
#
# Two questions that produce the same label (case-insensitively) are the same concept, so the
# 7_8 and 9_11 plans for one video usually converge on one label, which is what a parent wants.

_STEMS: tuple[tuple[str, ...], ...] = tuple(
    sorted(
        (
            tuple(s.split())
            for s in (
                "can you remember", "do you remember", "can you explain why", "can you explain",
                "can you tell me", "what do you think", "why do you think", "how do you think",
                "what might you", "what would happen", "what happens", "can you",
                "what is", "what are", "what was", "what were", "what did", "what does", "what do",
                "why is", "why are", "why was", "why do", "why did", "why can", "why does",
                "how is", "how are", "how do", "how does", "how did", "how can",
                "what", "why", "how", "which", "who", "where", "when",
            )
        ),
        key=len,
        reverse=True,
    )
)
# Dropped from the front (and the back) of a label: they carry no meaning on their own.
_FILLER = frozenset((
    "a", "an", "the", "that", "this", "it", "its", "if", "so", "about", "of", "to", "in", "on",
    "at", "for", "by", "with", "like", "and", "or", "but", "then", "because",
    "you", "your", "me", "my", "we", "our", "there", "here",
    "just", "really", "very", "much", "ever", "some", "any", "many", "more", "most", "other",
    "be", "been", "being", "is", "are", "was", "were", "am", "do", "does", "did", "done",
    "have", "has", "had", "might", "may", "would", "could", "will", "shall", "should", "can",
    "must", "go", "goes", "going", "get", "gets", "happen", "happens", "happened",
    "think", "thinks", "tell", "tells", "remember", "explain", "explains",
))
_CLAUSE_MARKERS = frozenset((
    "because", "than", "that", "which", "when", "while", "if", "so", "and", "but", "or",
    "where", "after", "before", "until", "since",
))


def _clean(text: str) -> str:
    return text.strip().strip(" \t\n\r?.!,:;\"'“”«»۔؟-")


def _words(text: str) -> list[str]:
    return [w for w in re.split(r"\s+", _clean(text)) if w]


def _key(word: str) -> str:
    return _clean(word).lower()


def _drop_filler(words: list[str]) -> list[str]:
    lo, hi = 0, len(words)
    while lo < hi and _key(words[lo]) in _FILLER:
        lo += 1
    while hi > lo + 1 and _key(words[hi - 1]) in _FILLER:
        hi -= 1
    return words[lo:hi]


def _strip_stem(words: list[str]) -> list[str]:
    """Peel question stems off the front: "Can you remember what causes..." -> "causes..."."""
    for _ in range(3):
        lower = [_key(w) for w in words]
        for stem in _STEMS:  # longest first
            if len(words) > len(stem) and tuple(lower[: len(stem)]) == stem:
                words = words[len(stem) :]
                break
        else:
            return words
    return words


def _cut_at_clause(words: list[str]) -> list[str]:
    """Trim "Olympus Mons is so much taller than..." down to "Olympus Mons is".

    The cut is refused when it would leave nothing but auxiliaries ("Might happen"), so a
    badly placed marker cannot turn a real subject into noise.
    """
    for i, w in enumerate(words):
        if i and _key(w) in _CLAUSE_MARKERS:
            head = _drop_filler(words[:i])
            if len(head) >= 1 and any(_key(h) not in _FILLER for h in head):
                return words[:i]
            return words
    return words


def _from_expected(expected: str) -> str:
    words = _drop_filler(_words(expected))
    return " ".join(words) if 1 <= len(words) <= CONCEPT_MAX_WORDS else ""


def _from_text(text: str) -> str:
    """A short complete clause is a fine label; half of a long one is not.

    Slicing a long question down to the cap produced labels like "New planet was
    discovered with similar", which reads as a bug to a parent. When the cleaned text
    does not fit, we emit nothing and let the caller fall back to the expected answer.
    """
    words = _drop_filler(_strip_stem(_words(text)))
    words = _drop_filler(_cut_at_clause(words))
    if not words or len(words) > CONCEPT_MAX_WORDS:
        return ""
    return " ".join(words)


def _from_title(title: str) -> str:
    """A video title is an acceptable last resort, minus the channel suffix YouTube adds."""
    return _clean(title.split("|")[0])


def concept_label(q: Question, fallback: str = "") -> str:
    for candidate in (_from_expected(q.expected), _from_text(q.text), _from_title(fallback)):
        if candidate:
            return candidate[:1].upper() + candidate[1:]
    return "This video"


# --- aggregation ---------------------------------------------------------------------------------


def _plan_for(plans: Mapping[str, QuestionPlan], s: Session) -> QuestionPlan | None:
    return plans.get(QuestionPlan.key(s.video_id, s.age_band, s.language))


def _question_for(plan: QuestionPlan | None, idx: int) -> Question | None:
    if plan is None or not (0 <= idx < len(plan.questions)):
        return None
    return plan.questions[idx]


def _totals(sessions: Sequence[Session], answers: Sequence[Answer]) -> AnalyticsTotals:
    asked = len(answers)
    answered = sum(1 for a in answers if a.result in ANSWERED)
    return AnalyticsTotals(
        minutes=round(sum(s.watched_sec for s in sessions) / 60),
        videos=len({s.video_id for s in sessions}),
        sessions=len(sessions),
        asked=asked,
        answered=answered,
        answer_rate=round(answered / asked, 2) if asked else 0.0,  # no divide by zero
    )


def _daily(
    dates: Sequence[str],
    sessions: Sequence[Session],
    by_session: Mapping[str, list[Answer]],
) -> list[AnalyticsDay]:
    secs: dict[str, int] = defaultdict(int)
    videos: dict[str, set[str]] = defaultdict(set)
    asked: dict[str, int] = defaultdict(int)
    answered: dict[str, int] = defaultdict(int)
    for s in sessions:
        secs[s.date] += s.watched_sec
        videos[s.date].add(s.video_id)
        for a in by_session.get(s.id, []):
            asked[s.date] += 1
            answered[s.date] += a.result in ANSWERED
    return [
        AnalyticsDay(
            date=d,
            minutes=round(secs[d] / 60),
            videos=len(videos[d]),
            asked=asked[d],
            answered=answered[d],
        )
        for d in dates  # every date present, zeros included
    ]


def _vocabulary(
    dates: Sequence[str],
    sessions: Sequence[Session],
    by_session: Mapping[str, list[Answer]],
    plans: Mapping[str, QuestionPlan],
) -> AnalyticsVocabulary:
    """Heard = Gilli asked the child for the word. Said = the child produced it.

    Two exclusions keep this a vocabulary list rather than a transcript:
      * copy_it questions ("clap", "roar") are a sound Gilli models, not a word the child is
        learning to say (same rule as `digest.py`);
      * an `expected` longer than VOCAB_MAX_WORDS is a sentence, not a word. Bands 7_8 and 9_11
        mostly answer in sentences, so their vocabulary is usually and correctly empty.
    """
    heard: dict[str, int] = defaultdict(int)
    said: dict[str, int] = defaultdict(int)
    first: dict[str, str] = {}
    display: dict[str, str] = {}

    for s in sessions:
        plan = _plan_for(plans, s)
        for a in by_session.get(s.id, []):
            q = _question_for(plan, a.question_idx)
            if q is None or q.type == "copy_it":
                continue
            word = _clean(q.expected)
            if not word or len(word.split()) > VOCAB_MAX_WORDS:
                continue
            k = _key(word)
            display.setdefault(k, word)
            heard[k] += 1
            spoke = bool(a.word_said) or (a.input_used == "voice" and a.result in ("correct", "partial"))
            if spoke:
                said[k] += 1
                first[k] = min(first.get(k, s.date), s.date)

    recent_from = dates[-NEW_WORD_DAYS] if len(dates) >= NEW_WORD_DAYS else dates[0]
    words = [
        VocabWord(word=display[k], times_said=said[k], first_said=first[k])
        for k in sorted(said, key=lambda k: (first[k], display[k]), reverse=True)
    ]
    return AnalyticsVocabulary(
        total_said=len(words),
        new_this_week=sum(1 for w in words if w.first_said >= recent_from),
        said=words,
        emerging=[
            EmergingWord(word=display[k], times_heard=heard[k])
            for k in sorted(heard, key=lambda k: (-heard[k], display[k]))
            if k not in said  # heard, never said back
        ],
    )


def _concepts(
    sessions: Sequence[Session],
    by_session: Mapping[str, list[Answer]],
    plans: Mapping[str, QuestionPlan],
    videos: Mapping[str, Video],
) -> tuple[list[ConceptStat], list[NeedsAnotherLook]]:
    asked: dict[str, int] = defaultdict(int)
    understood: dict[str, int] = defaultdict(int)
    shaky: dict[str, int] = defaultdict(int)
    shaky_days: dict[str, set[str]] = defaultdict(set)
    last_seen: dict[str, str] = {}
    display: dict[str, str] = {}

    for s in sessions:
        plan = _plan_for(plans, s)
        video = videos.get(s.video_id)
        for a in by_session.get(s.id, []):
            q = _question_for(plan, a.question_idx)
            if q is None:
                continue
            label = concept_label(q, video.title if video else "")
            k = label.lower()
            display.setdefault(k, label)
            asked[k] += 1
            last_seen[k] = max(last_seen.get(k, s.date), s.date)
            if a.result in UNDERSTOOD:
                understood[k] += 1
            elif a.result in SHAKY:
                shaky[k] += 1
                shaky_days[k].add(s.date)

    order = sorted(asked, key=lambda k: (-shaky[k], -asked[k], display[k]))
    stats = [
        ConceptStat(
            concept=display[k],
            asked=asked[k],
            understood=understood[k],
            shaky=shaky[k],
            last_seen=last_seen[k],
        )
        for k in order
    ]
    review = [
        NeedsAnotherLook(concept=display[k], times_shaky=shaky[k], last_seen=last_seen[k])
        for k in order
        if len(shaky_days[k]) >= SHAKY_DAYS_FOR_REVIEW  # one bad day is noise, two is a pattern
    ]
    return stats, review


def _channels(
    sessions: Sequence[Session],
    videos: Mapping[str, Video],
    channels: Mapping[str, Channel],
) -> list[ChannelStat]:
    secs: dict[str, int] = defaultdict(int)
    seen: dict[str, set[str]] = defaultdict(set)
    for s in sessions:
        video = videos.get(s.video_id)
        cid = (video.channel_id if video else "") or "unknown"
        secs[cid] += s.watched_sec
        seen[cid].add(s.video_id)
    return [
        ChannelStat(
            channel_id=cid,
            title=channels[cid].title if cid in channels else cid,
            minutes=round(secs[cid] / 60),
            videos=len(seen[cid]),
        )
        for cid in sorted(secs, key=lambda c: (-secs[c], c))
    ]


QUIET_EMPTY = AnalyticsNote(kind="quiet", text="Nothing to show yet — no sessions in this window.")
QUIET_FALLBACK = AnalyticsNote(kind="quiet", text="Nothing new stands out this time.")


def aggregate(
    kid: Kid,
    days: int,
    sessions: Sequence[Session],
    answers: Sequence[Answer],
    plans: Mapping[str, QuestionPlan],
    videos: Mapping[str, Video],
    channels: Mapping[str, Channel],
    today: date | None = None,
) -> Analytics:
    """The whole payload except `note`, from records only. Pure: no store, no model."""
    days = clamp_days(days)
    dates = window_dates(days, today)
    in_window = sorted(
        (s for s in sessions if s.kid_id == kid.id and dates[0] <= s.date <= dates[-1]),
        key=lambda s: (s.date, s.started_at),
    )
    ids = {s.id for s in in_window}
    by_session: dict[str, list[Answer]] = defaultdict(list)
    for a in answers:
        if a.session_id in ids:
            by_session[a.session_id].append(a)
    window_answers = [a for s in in_window for a in by_session[s.id]]

    band = kid.age_band or "7_8"
    concepts, review = ([], []) if band == "4_6" else _concepts(in_window, by_session, plans, videos)
    return Analytics(
        kid_id=kid.id,
        band=band,
        days=days,
        generated_at=now_iso(),
        totals=_totals(in_window, window_answers),
        daily=_daily(dates, in_window, by_session),
        vocabulary=_vocabulary(dates, in_window, by_session, plans),
        concepts=concepts,
        needs_another_look=review,
        channels=_channels(in_window, videos, channels),
        note=QUIET_EMPTY,
    )


# --- the note (one model call, cached) -------------------------------------------------------------

NOTE_SYSTEM_PROMPT = f"""You write the one short note a parent reads at the top of their child's
co-watching summary. You are given counts only: minutes, videos, questions, words, concept labels.
You never see anything the child said and must not invent any.

Write one or two plain sentences, then pick a kind.

Hard rules:
- Never shame the parent and never shame the child. No "only", no "too much", no "should have".
- Never compare this child to another child, to a sibling, to an average, or to a target.
- Never tell a parent to cut screen time as a moral judgement. Watching together is the point of
  this product; if a number is worth mentioning, mention it as a fact, not a verdict.
- Prefer ONE concrete thing the parent could do today (a word to use at breakfast, a question to
  ask in the car about something the child watched) over a general observation.
- If nothing meaningful changed, say so plainly and use kind "quiet". A quiet week is fine.
- Silence on a question is not failure. A child who watched and said nothing is still watching.

kind: "praise" when something genuinely went well, "suggestion" when you have one concrete thing to
try, "watch" when something is worth keeping an eye on (said gently, never alarming), "quiet" when
there is nothing to act on.

{SAFETY_RULES}
""".strip()


def note_agent(model=None) -> Agent:
    return make_agent("digest", NOTE_SYSTEM_PROMPT, model=model)


def note_prompt(a: Analytics, kid: Kid) -> str:
    t = a.totals
    active = sum(1 for d in a.daily if d.minutes or d.asked)
    lines = [
        f"nickname: {kid.nickname}",
        f"age_band: {a.band}",
        f"window: {a.days} days, {a.daily[0].date} to {a.daily[-1].date}, active on {active} of them",
        (
            f"totals: {t.minutes} minutes, {t.videos} videos, {t.sessions} sessions, "
            f"{t.asked} questions asked, {t.answered} answered (rate {t.answer_rate})"
        ),
        f"channels: {', '.join(f'{c.title} {c.minutes}m' for c in a.channels) or '-'}",
    ]
    if a.band == "4_6":
        lines += [
            f"words said: {_join(w.word for w in a.vocabulary.said)}",
            f"new words this week: {a.vocabulary.new_this_week}",
            f"words heard but not said yet: {_join(w.word for w in a.vocabulary.emerging)}",
        ]
    else:
        lines += [
            "concepts (asked/understood/shaky): "
            + (
                "; ".join(f"{c.concept} {c.asked}/{c.understood}/{c.shaky}" for c in a.concepts[:8])
                or "-"
            ),
            f"needs another look: {_join(c.concept for c in a.needs_another_look)}",
        ]
    lines.append("\nReturn the AnalyticsNote.")
    return "\n".join(lines)


def _join(items) -> str:
    return ", ".join(items) or "-"


def write_note(a: Analytics, kid: Kid, agent: Agent | None = None) -> AnalyticsNote:
    """One model call. No sessions -> a deterministic quiet note and no call at all.

    Nobody-answered is handled here rather than in the prompt: a weaker model reliably
    writes "great questions this week!" over a window where the child said nothing, and a
    note that contradicts the numbers under it costs the parent their trust in both.
    """
    if a.totals.sessions == 0:
        return QUIET_EMPTY
    if a.totals.asked > 0 and a.totals.answered == 0:
        return AnalyticsNote(
            kind="watch",
            text=(
                f"Gilli asked {a.totals.asked} "
                f"{'question' if a.totals.asked == 1 else 'questions'} and heard nothing back. "
                "Worth checking the microphone works, or sitting in for one video."
            ),
        )
    try:
        return structured(agent or note_agent(), note_prompt(a, kid), AnalyticsNote)
    except Exception as e:  # noqa: BLE001 - LLMError, or any provider error: the screen still renders
        log.warning("analytics note failed for %s: %s", kid.id, e)
        return QUIET_FALLBACK


def note_cache_key(a: Analytics) -> str:
    """(kid, window end date, rounded inputs). Small changes reuse the note; real ones do not."""
    t = a.totals
    shape = {
        "days": a.days,
        "minutes": t.minutes // 5,  # 5-minute buckets: a minute more is not a new note
        "videos": t.videos,
        "sessions": t.sessions,
        "asked": t.asked,
        "answered": t.answered,
        "rate": round(t.answer_rate, 1),
        "said": [w.word for w in a.vocabulary.said],
        "new": a.vocabulary.new_this_week,
        "emerging": [w.word for w in a.vocabulary.emerging],
        "concepts": [[c.concept, c.understood, c.shaky] for c in a.concepts],
        "review": [c.concept for c in a.needs_another_look],
        "channels": [[c.channel_id, c.minutes // 5] for c in a.channels],
    }
    digest = hashlib.sha1(json.dumps(shape, sort_keys=True).encode()).hexdigest()[:16]
    return f"{a.kid_id}#{a.daily[-1].date}#{digest}"


def cached_note(
    a: Analytics,
    kid: Kid,
    store: Store,
    refresh: bool = False,
    agent: Agent | None = None,
) -> AnalyticsNote:
    key = note_cache_key(a)
    if not refresh:
        hit = store.get_analytics_note(kid.household_id, key)
        if hit:
            return AnalyticsNote(kind=hit["kind"], text=hit["text"])
    note = write_note(a, kid, agent)
    store.put_analytics_note(kid.household_id, key, {**note.model_dump(), "created_at": now_iso()})
    return note


# --- store wiring ----------------------------------------------------------------------------------


def load_window(kid: Kid, days: int, store: Store, today: date | None = None):
    """Everything `aggregate` needs, read once from the store."""
    dates = window_dates(days, today)
    household = kid.household_id
    sessions = [
        s for s in store.list_sessions(household, kid.id) if dates[0] <= s.date <= dates[-1]
    ]
    answers = [a for s in sessions for a in store.list_answers(household, s.id)]
    plans: dict[str, QuestionPlan] = {}
    videos: dict[str, Video] = {}
    for s in sessions:
        key = QuestionPlan.key(s.video_id, s.age_band, s.language)
        if key not in plans:
            plan = store.get_plan(s.video_id, s.age_band, s.language)
            if plan:
                plans[key] = plan
        if s.video_id not in videos:
            video = store.get_video(s.video_id)
            if video:
                videos[s.video_id] = video
    channels = {c.id: c for c in store.list_channels(household, kid.id)}
    return sessions, answers, plans, videos, channels


def run_analytics(
    kid: Kid,
    days: int,
    store: Store,
    refresh: bool = False,
    agent: Agent | None = None,
    today: date | None = None,
) -> Analytics:
    """The endpoint's whole job: read the window, aggregate, attach the cached note."""
    sessions, answers, plans, videos, channels = load_window(kid, days, store, today)
    a = aggregate(kid, days, sessions, answers, plans, videos, channels, today)
    a.note = cached_note(a, kid, store, refresh=refresh, agent=agent)
    return a
