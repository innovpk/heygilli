"""Take 16: Lisa, five, in the household take 15 set up. Pictures, a tap, a reply.

Reuses take 15's signed-in profile. The Dr. Binocs yawn video is allowed
for her through the API and its pre-reader plan pre-warmed. The browser is
told it has no recogniser, so the gateway turns a spoken question into
picture cards, which is the scene this beat is about. The cards carry no
semantics, so the screen is watched for them. Marks in takes/part16-marks.json.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, dump, semantics_on
from record_part15 import FIND_TOKEN, API, allow_and_warm, api, card_centres, has, mark, marks, tap, wait_for
import record_part15 as r15

HERE = Path(__file__).parent
TAKES = HERE / "takes"
TAKE = "part16"
SHOTS = TAKES / f"{TAKE}-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile15"  # take 15's household, still signed in
W, H = 1280, 720
VIDEO = "0lsySXHa5l0"  # Dr. Binocs, Why Do We Yawn?, 8:36
TITLE = "Why Do We Yawn"


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def main() -> None:
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1.5,
            record_video_dir=str(TAKES / f"{TAKE}-video"),
            record_video_size={"width": 1920, "height": 1080},
            args=["--autoplay-policy=no-user-gesture-required"],
        )
        ctx.add_init_script("""
          for (const k of ['webkitSpeechRecognition', 'SpeechRecognition']) {
            try { Object.defineProperty(window, k, {get: () => undefined, configurable: true}); } catch (e) {}
          }
        """)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        r15.t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        wait_for(page, ["Lisa", "Hi Rayan", "Hi Lisa"], 40)
        time.sleep(2)
        found = page.evaluate(FIND_TOKEN, API)
        if not found:
            dump(page, "no token")
            raise SystemExit(1)
        key, token = found
        _, kids = api(page, token, "/kids")
        items = kids["kids"] if isinstance(kids, dict) and "kids" in kids else kids
        lisa = next(k for k in items if k["nickname"] == "Lisa")
        allow_and_warm(page, token, lisa, VIDEO)
        api(page, token, f"/kids/{lisa['id']}/limits", "PATCH", {"max_video_minutes": 30})
        mark("warmed")
        page.goto(URL)
        semantics_on(page)
        wait_for(page, ["Lisa"], 40)
        time.sleep(2)
        if has(page, "Hi Rayan"):
            tap(page, "Parent", nth=0, required=False)
            time.sleep(3)
        tap(page, "Lisa", nth=0, required=False)
        time.sleep(3)
        tap(page, "Enter kid mode", required=False)
        time.sleep(7)
        mark("shelf")
        dump(page, "shelf")
        shot(page, "shelf")
        if not has(page, TITLE):
            page.mouse.click(300, 62)
            time.sleep(1.2)
            page.keyboard.type("yawn", delay=150)
            time.sleep(3.5)
        if not has(page, TITLE):
            page.mouse.move(1250, 400)
            for _ in range(20):
                page.mouse.wheel(0, 400)
                time.sleep(0.6)
                if has(page, TITLE):
                    break
            time.sleep(1.5)
        tap(page, TITLE, nth=0)
        time.sleep(9)
        mark("session_start")
        shot(page, "session")
        centres = []
        for _ in range(290):
            time.sleep(2)
            shot(page, "poll")
            centres = card_centres(SHOTS / "poll.png", W, H)
            if len(centres) >= 2:
                break
        mark("question")
        dump(page, "question")
        shot(page, "question")
        print("  cards at", [(round(x), round(y)) for x, y in centres], flush=True)
        time.sleep(2.5)
        if centres:
            x, y = centres[0]
            page.mouse.click(x, y)
            mark("picked")
        else:
            mark("no_pick")
        time.sleep(1.2)
        shot(page, "picked")
        time.sleep(3)
        mark("reply")
        shot(page, "reply")
        time.sleep(6)
        mark("resumed")
        mark("end")
        (TAKES / f"{TAKE}-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / f"{TAKE}.webm")
        print("video", TAKES / f"{TAKE}.webm")


if __name__ == "__main__":
    main()
