"""Take 2 on live heygilli.com, in the household take 1 made: check a link, the limits,
kid mode, search, a session question, and the games.

Marks every step's time in the recording (takes/part2-marks.json) and logs the
labels on screen at the moments that decide what to tap, so a first run also
shows what to fix.
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
SHOTS = TAKES / "part2-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile"

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"{marks[name]:7.1f}s  {name}", flush=True)


def has(page, text) -> bool:
    return page.locator("flt-semantics").filter(has_text=text).count() > 0


def tap(page, text, nth=-1, required=True):
    for sel in ("flt-semantics[role=button]", "flt-semantics"):
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
            record_video_dir=str(TAKES / "part2-video"), record_video_size={"width": W, "height": H},
            args=["--autoplay-policy=no-user-gesture-required"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)
        dump(page, "home")
        if has(page, "Rayan") and not has(page, "Enter kid mode"):
            tap(page, "Rayan", nth=0)
            time.sleep(4)
        mark("kid_page")
        shot(page, "kid-page")

        # Check before you allow is filmed in take 1b now.
        if False:
            time.sleep(3)
            mark("check_screen")
            page.locator("input").last.click()
            page.keyboard.type("https://www.youtube.com/@SciShowKids", delay=45)
            time.sleep(1)
            tap(page, "Check")
            for _ in range(40):
                time.sleep(3)
                if has(page, "Add this channel") or has(page, "read below") or has(page, "Fits your answers"):
                    break
            time.sleep(3)
            mark("check_result")
            dump(page, "check result")
            shot(page, "check-result")
            time.sleep(4)
            page.go_back()
            time.sleep(3)

        # The limits, on the Rules tab.
        tap(page, "Rules", nth=0, required=False)
        time.sleep(3)
        page.mouse.wheel(0, 700)
        time.sleep(3)
        mark("rules_tab")
        shot(page, "rules")
        page.mouse.wheel(0, -2000)
        time.sleep(1)
        tap(page, "Overview", nth=0, required=False)
        time.sleep(2)

        # Kid mode.
        tap(page, "Enter kid mode")
        time.sleep(6)
        mark("shelf")
        dump(page, "shelf")
        shot(page, "shelf")
        skip = ("Play a game with Gilli", "Parent", "Gilli", "Say it")
        titles = [b for b in buttons(page)
                  if len(b) > 20 and not any(s in b for s in skip)]
        print("titles:", titles[:8], flush=True)
        word = next((w for t in titles for w in re.findall(r"[A-Za-z]{5,}", t)), "")
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

        # A session: open the first video and wait for Gilli's question.
        if titles:
            tap(page, titles[0][:40], nth=0)
            time.sleep(8)
            mark("session_start")
            dump(page, "session opened")
            shot(page, "session-opened")
            asked = False
            for i in range(48):  # up to 4 minutes
                time.sleep(5)
                bs = buttons(page)
                if i % 4 == 3:
                    shot(page, f"session-{i:02d}")
                if any("Say it again" in b or "Hold" in b for b in bs) or has(page, "?"):
                    if not asked:
                        asked = True
                        mark("question")
                        dump(page, "question")
                        shot(page, "question")
                        time.sleep(3)
                        picks = [b for b in bs if b not in ("Back", "Say it again", "Turn the sound on")
                                 and "questions in this video" not in b and "Hold" not in b]
                        print("pick candidates:", picks, flush=True)
                        if picks:
                            tap(page, picks[0], nth=0, required=False)
                            mark("answered")
                        time.sleep(10)
                        mark("reply")
                        shot(page, "reply")
                        break
            time.sleep(4)
            page.go_back()
            time.sleep(5)

        # The games.
        if tap(page, "Play a game with Gilli", required=False):
            time.sleep(4)
            mark("games")
            shot(page, "games")
            tap(page, "Find Gilli", nth=0, required=False)
            time.sleep(4)
            mark("find_gilli")
            dump(page, "find gilli")
            for round_ in range(3):
                trees = [b for b in buttons(page) if "tree" in b.lower() or "Tree" in b]
                if not trees:
                    break
                tap(page, trees[round_ % len(trees)], nth=0, required=False)
                time.sleep(3)
            mark("games_played")
            shot(page, "games-played")
            time.sleep(3)

        mark("end")
        (TAKES / "part2-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part2.webm")
        print("video", TAKES / "part2.webm")


if __name__ == "__main__":
    main()
