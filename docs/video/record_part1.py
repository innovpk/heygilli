"""Take 1 on live heygilli.com: parent setup, the real screening, the verdicts, allowing.

Uses a persistent browser profile so the next take returns to the same trial
household. Every step is marked with its time in the recording, in
takes/part1-marks.json, so the edit can cut on exact moments.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, dump

HERE = Path(__file__).parent
TAKES = HERE / "takes"
TAKES.mkdir(exist_ok=True)
SHOTS = TAKES / "part1-shots"
SHOTS.mkdir(exist_ok=True)
PROFILE = HERE / "profile"

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"{marks[name]:7.1f}s  {name}", flush=True)


def has(page, text) -> bool:
    return page.locator("flt-semantics").filter(has_text=text).count() > 0


def tap(page, text, nth=-1):
    for sel in ("flt-semantics[role=button]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f"{sel}[aria-label*=\"{text}\"]")
        if loc.count():
            loc.nth(nth).click()
            return
    dump(page, f"NOT FOUND: {text}")
    raise SystemExit(1)


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def main() -> None:
    global t0
    if PROFILE.exists():
        shutil.rmtree(PROFILE)  # a fresh household for this take
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part1-video"), record_video_size={"width": W, "height": H},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(3)
        mark("signin_screen")
        tap(page, "Set up without Google")
        time.sleep(5)
        mark("kids_empty")
        tap(page, "Add your first kid")
        time.sleep(2)
        page.locator("input[aria-label='What you call them at home']").click()
        page.keyboard.type("Rayan", delay=110)
        tap(page, "monkey")
        time.sleep(0.6)
        box = page.locator("input").nth(1).locator("xpath=..").bounding_box()
        page.mouse.click(box["x"] + box["width"] * 0.57, box["y"] + box["height"] / 2)
        time.sleep(1)
        for _ in range(4):
            if has(page, "Band 9"):
                break
            page.keyboard.press("ArrowRight")
            time.sleep(0.4)
        time.sleep(1.2)
        mark("kid_filled")
        tap(page, "Save kid")
        time.sleep(4)
        mark("questions")

        answers = ["Rather not", "Sometimes", "Fine", "Rather not", "Sometimes"]
        for i in range(8):
            if not has(page, "What Rayan may watch"):
                break
            if has(page, "Anything else, in your own words?"):
                page.locator("textarea, input").last.click()
                page.keyboard.type("Nothing about weight or diets, please.", delay=70)
                time.sleep(1.2)
                mark("free_text")
                tap(page, "Save and go on")
                time.sleep(3)
                break
            time.sleep(1.4)
            tap(page, answers[i % len(answers)])
            time.sleep(1.0)
            tap(page, "Next")
            time.sleep(1.6)
        mark("interests")
        time.sleep(1.5)
        for interest in ["Science", "Animals"]:
            if has(page, interest):
                tap(page, interest)
                time.sleep(0.8)
        time.sleep(1.2)
        tap(page, "Next")
        time.sleep(2.5)
        mark("breaks")
        time.sleep(2.5)
        tap(page, "Find videos")
        mark("find_videos")

        for i in range(96):  # up to 8 minutes
            time.sleep(5)
            if i % 6 == 5:
                shot(page, f"wait-{i:02d}")
            if has(page, "Shown (") and has(page, " videos"):
                break
        time.sleep(3)
        mark("review_ready")
        dump(page, "review")
        shot(page, "review")
        time.sleep(4)
        if has(page, "Why"):
            tap(page, "Why", nth=0)
            time.sleep(4)
            mark("why_open")
            shot(page, "why")
        if has(page, "Hidden ("):
            tap(page, "Hidden (")
            time.sleep(5)
            mark("hidden_tab")
            shot(page, "hidden")
        tap(page, " videos")
        time.sleep(8)
        mark("kid_page")
        dump(page, "kid page")
        shot(page, "kid-page")
        time.sleep(4)
        mark("end")
        (TAKES / "part1-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        src = Path(video.path())
        shutil.copy(src, TAKES / "part1.webm")
        print("video", TAKES / "part1.webm")


if __name__ == "__main__":
    main()
