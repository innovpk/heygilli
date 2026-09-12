"""Take 10: "Ask about this" answered, and "Add a question" actually reached.

Take 9 got as far as the ask sheet and then stalled on two things:

  * The sheet has no text field. It offers the questions as buttons — "Is
    anything scary in it?", "Does it try to sell them something?", "What would
    they actually learn?" — and an Ask button. Typing into it was never going
    to work.
  * "Back" did not fire, so the check screen stayed open, and the later
    coordinate clicks landed on that screen instead of the Channels tab. A
    hard reload between scenes is cheaper and more certain than unwinding
    whatever screen the last one finished on.

Coordinates are read off takes/part8-shots/channels-tab.png; the viewport is a
fixed 1920x1080 and these screens do not reflow.
"""
import json
import shutil
import time
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, labels

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part10-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile"

# Already screened for this household, so the check costs no quota.
VIDEO = "https://www.youtube.com/watch?v=0jKoOUZ1GBM"

CHANNELS_TAB = (833, 184)
ADD_BUTTON = (1597, 385)
WHAT_THEY_SEE = (1080, 282)

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"{marks[name]:7.1f}s  {name}", flush=True)


def has(page, text) -> bool:
    return page.locator("flt-semantics").filter(has_text=text).count() > 0


def dump(page, tag):
    print(f"--- {tag}", flush=True)
    for line in labels(page)[:35]:
        print("  ", line, flush=True)


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def tap(page, text, nth=-1) -> bool:
    for sel in ("flt-semantics[role=button]", "flt-semantics[role=tab]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f"{sel}[aria-label*=\"{text}\"]")
        if loc.count() == 0:
            continue
        for which in (nth, 0, -1):
            try:
                loc.nth(which).click(timeout=4000)
                return True
            except PlaywrightError:
                continue
    print(f"  (no clickable {text!r})", flush=True)
    return False


def reset(page):
    """Back to the kid's parent page from wherever we are."""
    page.goto(URL)
    semantics_on(page)
    time.sleep(6)
    if not has(page, "Enter kid mode"):
        tap(page, "Rayan")
        time.sleep(4)


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part10-video"), record_video_size={"width": W, "height": H},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        reset(page)
        mark("kid_page")

        # ---------------------------------------------------- ask about this
        page.mouse.click(*CHANNELS_TAB)
        time.sleep(4)
        page.mouse.click(*ADD_BUTTON)
        time.sleep(3)
        mark("add_sheet")
        shot(page, "add-sheet")
        if tap(page, "Check a video or channel"):
            time.sleep(3)
            mark("check_screen")
            shot(page, "check-screen")
            if page.locator("input").count():
                page.locator("input").last.click()
                page.keyboard.type(VIDEO, delay=45)
                time.sleep(1)
                tap(page, "Check")
                for _ in range(40):
                    time.sleep(3)
                    if has(page, "Ask about this"):
                        break
                time.sleep(3)
                mark("check_result")
                shot(page, "check-result")
                if tap(page, "Ask about this", nth=0):
                    time.sleep(3)
                    mark("ask_sheet")
                    shot(page, "ask-sheet")
                    # The questions are buttons, not a field.
                    picked = (tap(page, "Is anything scary in it?")
                              or tap(page, "What would they actually learn?"))
                    time.sleep(2)
                    mark("ask_picked")
                    shot(page, "ask-picked")
                    if picked and tap(page, "Ask"):
                        for _ in range(25):
                            time.sleep(3)
                            if has(page, "title only") or has(page, "watched") or has(page, "Gilli"):
                                break
                        time.sleep(3)
                        mark("ask_answered")
                        dump(page, "ask answered")
                        shot(page, "ask-answered")
                        time.sleep(5)

        # --------------------------------------------------- add a question
        reset(page)
        page.mouse.click(*CHANNELS_TAB)
        time.sleep(4)
        shot(page, "channels")
        page.mouse.click(*WHAT_THEY_SEE)
        time.sleep(6)
        mark("shown_list")
        dump(page, "shown and hidden")
        shot(page, "shown-list")
        if tap(page, "Add a question", nth=0):
            time.sleep(3)
            mark("own_question_sheet")
            dump(page, "add a question")
            shot(page, "own-question-sheet")
            if page.locator("input").count():
                page.locator("input").last.click()
                page.keyboard.type("What made the lava move so slowly?", delay=50)
                time.sleep(2)
                mark("own_question_typed")
                shot(page, "own-question-typed")
                if tap(page, "Add it"):
                    time.sleep(5)
                    mark("own_question_added")
                    dump(page, "added")
                    shot(page, "own-question-added")
                    time.sleep(4)
            else:
                print("  (add-a-question sheet had no text field)", flush=True)

        time.sleep(2)
        mark("end")
        (TAKES / "part10-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part10.webm")
        print("video", TAKES / "part10.webm")


if __name__ == "__main__":
    main()
