"""Take 17: Rayan's session again on take 15's household, with the scrub working:
the first question (about the video), the hint after silence, then the second
question with written cards, a tap, and the reply. Marks in takes/part17-marks.json.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, dump, semantics_on
from record_part15 import FIND_TOKEN, API, card_centres, has, mark, marks, scrub_forward, tap, wait_for
import record_part15 as r15

HERE = Path(__file__).parent
TAKES = HERE / "takes"
TAKE = "part17"
SHOTS = TAKES / f"{TAKE}-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile15"  # take 15's household, still signed in
W, H = 1280, 720


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def main() -> None:
    tok = json.loads((TAKES / "part15-token.json").read_text())
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1.5,
            record_video_dir=str(TAKES / f"{TAKE}-video"),
            record_video_size={"width": 1920, "height": 1080},
            args=["--autoplay-policy=no-user-gesture-required",
                  "--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream"],
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        r15.t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        wait_for(page, ["Rayan"], 40)
        time.sleep(2)
        tap(page, "Rayan", nth=0, required=False)
        time.sleep(3)
        tap(page, "Enter kid mode")
        time.sleep(7)
        mark("shelf")
        if not has(page, "Why do we Yawn"):
            page.mouse.click(300, 62)  # the search field, under the greeting
            time.sleep(1.2)
            page.keyboard.type("yawn", delay=150)
            time.sleep(3.5)
            shot(page, "searched")
            dump(page, "searched")
        if not has(page, "Why do we Yawn"):
            page.mouse.move(1250, 400)
            for _ in range(20):
                page.mouse.wheel(0, 400)
                time.sleep(0.6)
                if has(page, "Why do we Yawn"):
                    break
            time.sleep(1.5)
        tap(page, "Why do we Yawn", nth=0)
        time.sleep(10)
        mark("session_start")
        shot(page, "session")
        def until(present: bool, seconds: int) -> bool:
            for _ in range(seconds):
                if has(page, "Say it again") == present:
                    return True
                time.sleep(1)
            return False

        # First question, about 110 s into the video.
        until(True, 150)
        mark("question")
        shot(page, "question")
        time.sleep(11.0)
        mark("hint")
        shot(page, "hint")
        time.sleep(3)
        mark("hint_held")
        until(False, 60)
        mark("silence_reply")
        shot(page, "silence-reply")
        time.sleep(6)
        mark("resumed")
        shot(page, "resumed")
        # Second question, at 8:00: written cards.
        until(True, 460)
        time.sleep(1.5)
        mark("pick")
        shot(page, "pick")
        dump(page, "pick")
        centres = card_centres(SHOTS / "pick.png", W, H)
        print("  cards at", [(round(x), round(y)) for x, y in centres], flush=True)
        time.sleep(2.0)
        if len(centres) >= 2:
            x, y = centres[1]
            page.mouse.click(x, y)
            mark("picked")
        else:
            mark("no_pick")
        time.sleep(1.2)
        shot(page, "picked")
        time.sleep(3.5)
        mark("reply")
        shot(page, "reply")
        time.sleep(7)
        mark("resumed2")
        mark("end")
        (TAKES / f"{TAKE}-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / f"{TAKE}.webm")
        print("video", TAKES / f"{TAKE}.webm")


if __name__ == "__main__":
    main()
