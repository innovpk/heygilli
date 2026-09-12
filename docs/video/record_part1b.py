"""Take 1b on live heygilli.com, same household: the finished screening, and a link check.

Opens "What Rayan will see" from the Channels tab, waits until the Curator has
finished ("Still reading" gone), films the verdicts, a reason and the Hidden
tab, allows, then checks a channel link from the Add channels sheet.
Marks every step's time in takes/part1b-marks.json.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, dump

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part1b-shots"
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


def open_channels(page) -> None:
    if not has(page, "Enter kid mode"):
        tap(page, "Rayan", nth=0)
        time.sleep(4)
    tap(page, "Channels", nth=0)
    time.sleep(3)


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part1b-video"), record_video_size={"width": W, "height": H},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)
        open_channels(page)
        mark("channels_tab")
        tap(page, "What Rayan will see")
        time.sleep(4)
        for i in range(120):  # up to 10 minutes for the Curator to finish
            if not has(page, "Still reading"):
                break
            if i % 12 == 0:
                shot(page, f"reading-{i:03d}")
            time.sleep(5)
        time.sleep(3)
        mark("review_ready")
        dump(page, "review")
        shot(page, "review")
        time.sleep(3)
        page.mouse.move(W / 2, H * 0.6)
        page.mouse.wheel(0, 500)
        time.sleep(3)
        page.mouse.wheel(0, -500)
        time.sleep(2)
        if tap(page, "Why", nth=0, required=False):
            time.sleep(5)
            mark("why_open")
            shot(page, "why")
        if tap(page, "Hidden (", required=False):
            time.sleep(5)
            mark("hidden_tab")
            shot(page, "hidden")
            if tap(page, "Why", nth=0, required=False):
                time.sleep(5)
                mark("hidden_why")
                shot(page, "hidden-why")
        tap(page, " videos")
        time.sleep(8)
        mark("allowed")
        shot(page, "after-allow")

        # Check a link before allowing it, from the Add channels sheet.
        open_channels(page)
        if not tap(page, "Or add one yourself", required=False):
            tap(page, "Add", nth=0, required=False)
        time.sleep(2)
        if tap(page, "Check a video or channel", required=False):
            time.sleep(3)
            mark("check_screen")
            page.locator("input").last.click()
            page.keyboard.type("https://www.youtube.com/@SciShowKids", delay=45)
            time.sleep(1)
            tap(page, "Check")
            mark("check_pressed")
            for _ in range(60):
                time.sleep(3)
                if has(page, "Add this channel") or has(page, "read below") or has(page, "Fits your answers"):
                    break
            time.sleep(4)
            mark("check_result")
            dump(page, "check result")
            shot(page, "check-result")
            page.mouse.move(W / 2, H * 0.6)
            page.mouse.wheel(0, 400)
            time.sleep(4)
        mark("end")
        (TAKES / "part1b-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part1b.webm")
        print("video", TAKES / "part1b.webm")


if __name__ == "__main__":
    main()
