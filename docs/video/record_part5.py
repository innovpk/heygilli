"""Take 5 on live heygilli.com, same household: the inbox, the channels, the progress screen.

Three screens the draft has no footage of yet. Marks every step's time in
takes/part5-marks.json.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, dump

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part5-shots"
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


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part5-video"), record_video_size={"width": W, "height": H},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)
        if not has(page, "Enter kid mode"):
            tap(page, "Rayan", nth=0, required=False)
            time.sleep(4)
        mark("kid_page")

        # The approved channels.
        tap(page, "Channels", nth=0)
        time.sleep(4)
        mark("channels_tab")
        shot(page, "channels")
        page.mouse.move(W / 2, H * 0.6)
        page.mouse.wheel(0, 350)
        time.sleep(3)
        mark("channels_scrolled")
        page.mouse.wheel(0, -350)
        time.sleep(1)

        # The progress screen.
        tap(page, "Progress", nth=0)
        time.sleep(5)
        mark("progress_tab")
        dump(page, "progress")
        shot(page, "progress")
        page.mouse.wheel(0, 400)
        time.sleep(4)
        mark("progress_scrolled")
        shot(page, "progress-scrolled")
        page.mouse.wheel(0, -400)
        time.sleep(1)

        # The inbox: everything waiting on the parent.
        tap(page, "Inbox", nth=0)
        time.sleep(5)
        mark("inbox")
        dump(page, "inbox")
        shot(page, "inbox")
        page.mouse.move(W / 2, H * 0.6)
        page.mouse.wheel(0, 400)
        time.sleep(4)
        mark("inbox_scrolled")
        shot(page, "inbox-scrolled")
        time.sleep(3)
        mark("end")
        (TAKES / "part5-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part5.webm")
        print("video", TAKES / "part5.webm")


if __name__ == "__main__":
    main()
