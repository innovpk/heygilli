"""Take 7: the shelf, the search, and one question asked over a video still playing.

Takes 2 and 6 both filmed the question sitting beside a black end card, and
that was never a recording bug. For band 9_11 the last question is pinned to
`duration - END_MARGIN_S`, and an earlier slot only survives when
`first_question_s <= (duration - END_MARGIN_S) - min_gap` — 90 <= duration-183,
so a mid-video question needs a video of at least 273 seconds. Every video on
the shelf was 2-4 minutes, so every take got the end-of-video question.

fix_shelf.py put a 21-minute one there. This films the shelf and the search
again (take 2's shelf still has the spider on it), then opens the long video
and stops the moment the question appears — 90 seconds in, with minutes of
picture left to run.

Marks every step in takes/part7-marks.json.
"""
import json
import re
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, dump, labels

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part7-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile"
API = "https://heygilli-gateway.onrender.com"

marks: dict[str, float] = {}
t0 = 0.0

FIND_TOKEN = """
async (api) => {
  for (const [k, v] of Object.entries(localStorage)) {
    if (!/token/i.test(k)) continue;
    const cands = [String(v), String(v).replace(/^"+|"+$/g, '')];
    try { const p = JSON.parse(v); if (typeof p === 'string') cands.push(p); } catch (e) {}
    for (const tok of cands) {
      const r = await fetch(api + '/kids', {headers: {'Authorization': 'Bearer ' + tok}});
      if (r.status === 200) return tok;
    }
  }
  return null;
}
"""

CALL = """
async ([api, path, token]) => {
  const r = await fetch(api + path, {headers: {'Authorization': 'Bearer ' + token}});
  return JSON.parse(await r.text());
}
"""


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"{marks[name]:7.1f}s  {name}", flush=True)


def has(page, text) -> bool:
    return page.locator("flt-semantics").filter(has_text=text).count() > 0


def tap(page, text, nth=-1, required=True):
    for sel in ("flt-semantics[role=button]", "flt-semantics[role=tab]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f"{sel}[aria-label*=\"{text}\"]")
        if loc.count():
            loc.nth(nth).click()
            return True
    if required:
        dump(page, f"NOT FOUND: {text}")
        raise SystemExit(1)
    print(f"  (skipped, not found: {text})", flush=True)
    return False


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def buttons(page) -> list[str]:
    return [l.split(" | ", 1)[1] for l in labels(page) if l.startswith("button | ")]


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part7-video"), record_video_size={"width": W, "height": H},
            args=["--autoplay-policy=no-user-gesture-required"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)

        # Ask the API which video is the long one, rather than reading "N min"
        # off a tile: that text is a separate widget from the tile's own label,
        # which is why take 6's sort saw every video as zero minutes long.
        title = ""
        token = page.evaluate(FIND_TOKEN, API)
        if token:
            kids = page.evaluate(CALL, [API, "/kids", token])
            items = kids["kids"] if isinstance(kids, dict) and "kids" in kids else kids
            kid = next((k for k in items if k.get("nickname") == "Rayan"), items[0])
            q = page.evaluate(CALL, [API, f"/kids/{kid['id']}/review", token])
            shelf = sorted(
                ((it["video"].get("duration_s") or 0, it["video"].get("title", ""))
                 for it in q.get("items", []) if it.get("status") == "approve"),
                reverse=True,
            )
            print("shelf:", [(d, t[:45]) for d, t in shelf[:5]], flush=True)
            if shelf:
                longest, title = shelf[0]
                print(f"opening {longest}s: {title}", flush=True)

        if not has(page, "Enter kid mode"):
            tap(page, "Rayan", nth=0, required=False)
            time.sleep(4)
        tap(page, "Enter kid mode")
        time.sleep(7)
        mark("shelf")
        dump(page, "shelf")
        shot(page, "shelf")

        # The search, on a shelf with no spider on it.
        tiles = [b for b in buttons(page) if len(b) > 20 and not any(
            s in b for s in ("Play a game with Gilli", "Parent", "Gilli", "Say it"))]
        word = next((w for t in tiles for w in re.findall(r"[A-Za-z]{5,}", t)), "")
        if word and page.locator("input").count():
            page.locator("input").first.click()
            page.keyboard.type(word.lower(), delay=140)
            time.sleep(4)
            mark("searched")
            shot(page, "searched")
            time.sleep(2)
            page.keyboard.press("Meta+a")
            page.keyboard.press("Backspace")
            time.sleep(4)
            mark("search_cleared")

        # Fall back to the longest-looking tile if the API was no help.
        if not title:
            title = max(tiles, key=len) if tiles else ""
        tap(page, title[:40], nth=0)
        time.sleep(8)
        mark("session_start")
        dump(page, "session opened")
        shot(page, "session-opened")

        # The question should arrive about 90s in. Poll tightly so the hold
        # starts while the picture is still moving.
        for i in range(90):
            time.sleep(3)
            if i % 10 == 9:
                shot(page, f"wait-{i:02d}")
            bs = buttons(page)
            if any("Say it again" in b for b in bs) or has(page, "Hold the mic"):
                mark("question")
                dump(page, "question")
                shot(page, "question")
                time.sleep(9)
                mark("question_held")
                shot(page, "question-held")
                # Hearing it again is its own beat in the cut.
                if tap(page, "Say it again", nth=0, required=False):
                    time.sleep(7)
                    mark("said_again")
                    shot(page, "said-again")
                picks = [b for b in bs if b not in ("Back", "Say it again", "Turn the sound on")
                         and "questions in this video" not in b]
                if picks:
                    tap(page, picks[0], nth=0, required=False)
                    mark("answered")
                    time.sleep(10)
                    mark("reply")
                    shot(page, "reply")
                    # The video carries on afterwards, which is the point of
                    # the beat: picture, question, picture again.
                    time.sleep(9)
                    mark("resumed")
                    shot(page, "resumed")
                break
        time.sleep(3)
        mark("end")
        (TAKES / "part7-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part7.webm")
        print("video", TAKES / "part7.webm")


if __name__ == "__main__":
    main()
