"""Planner eval: fixtures x bands x languages -> band-rule checks (SPEC 9.5 "every provider must pass").

    uv run python eval/run_eval.py                                  # provider from env (fake: for offline)
    HEYGILLI_MODEL_PLANNER=fake: uv run python eval/run_eval.py
    HEYGILLI_MODEL_PLANNER=bedrock:us.anthropic.claude-sonnet-4-6 uv run python eval/run_eval.py

For every cell the model's *draft* is checked against the band rules (how good is the
provider on its own?), then `rules.enforce` runs and the *final* plan is checked again
(does the child ever see a violation?). A cell passes when the final plan is clean and
came from the model rather than the generic fallback. Results: eval/results/<provider>-<ts>.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[1] / ".env")

from heygilli_agents import planner, rules
from heygilli_agents.llm import LLMError, structured
from heygilli_agents.models import spec_for
from heygilli_agents.schemas import TYPES_FOR_BAND, PlanDraft, Question, Video
from heygilli_agents.tools.icons import icon_ids

HERE = Path(__file__).resolve().parent
BANDS = ("4_6", "7_8", "9_11")
LANGUAGES = ("en", "ur")
URDU_RE = re.compile(r"[؀-ۿ]")


def check(questions: list[Question], band: str, duration_s: int, language: str) -> list[str]:
    """Band-rule violations in a list of questions (empty list = clean)."""
    bad: list[str] = []
    t = rules.TIMING[band]
    ids = icon_ids()
    if len(questions) > rules.max_questions(band, duration_s):
        bad.append(f"count {len(questions)} > max {rules.max_questions(band, duration_s)}")
    if not questions:
        bad.append("no questions")
    short = 0 < duration_s < rules.SHORT_VIDEO_S
    prev: int | None = None
    for i, q in enumerate(sorted(questions, key=lambda q: q.t_sec)):
        tag = f"q{i}@{q.t_sec}s"
        if q.type not in TYPES_FOR_BAND[band]:
            bad.append(f"{tag}: type {q.type} not allowed for {band}")
        if band == "4_6" and q.type == "why":
            bad.append(f"{tag}: 'why' for a pre-reader")
        if not short and q.t_sec < t.first_question_s:
            bad.append(f"{tag}: before first-question threshold {t.first_question_s}s")
        if duration_s and q.t_sec > duration_s - rules.END_MARGIN_S:
            bad.append(f"{tag}: after the end of the video")
        if prev is not None and q.t_sec - prev < rules.min_gap_s(band):
            bad.append(f"{tag}: gap {q.t_sec - prev}s < {rules.min_gap_s(band)}s")
        prev = q.t_sec
        if q.type == "pick_it" or q.input == "pick":
            if not rules.valid_pick(q, ids):
                bad.append(f"{tag}: pick_it options not 3 distinct library icons with one correct")
        elif q.options:
            bad.append(f"{tag}: options on a non-pick question")
        if band == "4_6":
            if q.input != rules.INPUT_FOR_TYPE.get(q.type):
                bad.append(f"{tag}: input {q.input} for {q.type}")
            if q.type == "name_it" and len(q.expected.split()) != 1:
                bad.append(f"{tag}: name_it expected is not one word ({q.expected!r})")
            if q.type != "copy_it" and not q.model_line:
                bad.append(f"{tag}: no model_line")
        if not q.text.strip():
            bad.append(f"{tag}: empty text")
        if language == "ur" and q.text and not URDU_RE.search(q.text):
            bad.append(f"{tag}: text not in Urdu")
        if language == "en" and URDU_RE.search(q.text):
            bad.append(f"{tag}: text not in English")
    return bad


def run_cell(fixture: dict, band: str, language: str) -> dict:
    video = Video(id=fixture["video_id"], title=fixture["title"], duration_s=fixture["duration_s"])
    segments = fixture["segments"]
    cell = {"fixture": fixture["video_id"], "band": band, "language": language}
    t0 = time.perf_counter()
    try:
        agent = planner.planner_agent()
        draft = structured(agent, planner.plan_prompt(video, segments, band, language, None), PlanDraft)
        cell["latency_ms"] = int((time.perf_counter() - t0) * 1000)
        draft_qs = [planner.repair_pick(q, language) for q in draft.questions]
        cell["draft_n"] = len(draft_qs)
        cell["draft"] = [q.model_dump(exclude_defaults=True) for q in draft.questions]  # raw, for debugging
        cell["draft_violations"] = check(draft_qs, band, video.duration_s, language)
        final = rules.enforce(draft_qs, band, video.duration_s, language, None, icon_ids())
        cell["fallback"] = not final
        if not final:
            final = planner.fallback_plan(video, band, language).questions
        cell["final_n"] = len(final)
        cell["final_violations"] = check(final, band, video.duration_s, language)
        cell["questions"] = [q.model_dump(exclude_defaults=True) for q in final]
        cell["pass"] = not cell["final_violations"] and not cell["fallback"]
    except (LLMError, Exception) as e:  # noqa: BLE001 - one bad cell must not stop the table
        cell.update(latency_ms=int((time.perf_counter() - t0) * 1000), error=f"{type(e).__name__}: {e}",
                    draft_n=0, draft_violations=[], final_n=0, final_violations=[], fallback=True, pass_=False)
        cell["pass"] = False
        cell.pop("pass_", None)
    return cell


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--fixtures", nargs="*", help="fixture names (default: all in eval/fixtures)")
    ap.add_argument("--bands", nargs="*", default=list(BANDS), choices=BANDS)
    ap.add_argument("--languages", nargs="*", default=list(LANGUAGES), choices=LANGUAGES)
    ap.add_argument("--workers", type=int, default=int(os.getenv("HEYGILLI_EVAL_WORKERS", "3")))
    ap.add_argument("--out", type=Path, default=HERE / "results")
    args = ap.parse_args()

    files = sorted((HERE / "fixtures").glob("*.json"))
    if args.fixtures:
        files = [f for f in files if f.stem in args.fixtures]
    fixtures = [json.loads(f.read_text(encoding="utf-8")) for f in files]
    provider = spec_for("planner")
    cells = [(fx, b, lang) for fx in fixtures for b in args.bands for lang in args.languages]
    print(f"planner provider: {provider}   cells: {len(cells)}   workers: {args.workers}\n")

    t0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as pool:
        results = list(pool.map(lambda c: run_cell(*c), cells))
    total_ms = int((time.perf_counter() - t0) * 1000)

    head = f"{'fixture':<14}{'band':<6}{'lang':<5}{'draft':>6}{'final':>6}{'ms':>7}  result"
    print(head)
    print("-" * len(head))
    for r in results:
        status = "PASS" if r["pass"] else "FAIL"
        note = r.get("error") or ("fallback" if r["fallback"] else "")
        if r["draft_violations"] and not note:
            note = f"draft fixed: {len(r['draft_violations'])}"
        if r["final_violations"]:
            note = "; ".join(r["final_violations"][:2])
        print(f"{r['fixture']:<14}{r['band']:<6}{r['language']:<5}{r['draft_n']:>6}{r['final_n']:>6}"
              f"{r['latency_ms']:>7}  {status}  {note}")
    passed = sum(r["pass"] for r in results)
    print(f"\n{passed}/{len(results)} cells pass; total {total_ms} ms; "
          f"draft violations across cells: {sum(len(r['draft_violations']) for r in results)}")

    args.out.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    safe = re.sub(r"[^A-Za-z0-9._-]+", "_", provider).strip("_") or "default"
    out = args.out / f"{safe}-{stamp}.json"
    out.write_text(json.dumps({
        "provider": provider, "timestamp": stamp, "passed": passed, "total": len(results),
        "total_ms": total_ms, "cells": results,
    }, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {out}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
