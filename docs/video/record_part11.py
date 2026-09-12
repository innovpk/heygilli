"""Take 11: the parent's own question, typed and added.

Take 10 opened the right sheet — "Ask something of your own", 200 characters
remaining, a yes/no switch, and an Add it button — and then failed to type
into it, because that field is not an `<input>`. Flutter renders a multi-line
field as a textarea, and on web it can also be a contenteditable, so this
tries both and falls back to clicking the field's own coordinates and typing
blind.

Only the one flow, so it is quick to re-run if a label moves.
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
SHOTS = TAKES / "part11-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile"

CHANNELS_TAB = (833, 184)
WHAT_THEY_SEE = (1080, 282)
QUESTION = "What made the lava move so slowly?"

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


def write_question(page) -> bool:
    """Type into whatever kind of field this sheet actually uses."""
    for what, sel in (("textarea", "textarea"), ("input", "input"),
                      ("contenteditable", "[contenteditable='true']")):
        loc = page.locator(sel)
        if loc.count() == 0:
            continue
        try:
            loc.last.click(timeout=4000)
            page.keyboard.type(QUESTION, delay=55)
            print(f"  typed into {what}", flush=True)
            return True
        except PlaywrightError:
            continue
    # Nothing matched: click where the field is drawn and type anyway.
    print("  no field matched; clicking the sheet body", flush=True)
    page.mouse.click(960, 470)
    page.keyboard.type(QUESTION, delay=55)
    return True


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part11-video"), record_video_size={"width": W, "height": H},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)
        if not has(page, "Enter kid mode"):
            tap(page, "Rayan")
            time.sleep(4)
        mark("kid_page")

        page.mouse.click(*CHANNELS_TAB)
        time.sleep(4)
        page.mouse.click(*WHAT_THEY_SEE)
        time.sleep(6)
        mark("shown_list")
        shot(page, "shown-list")

        if tap(page, "Add a question", nth=0):
            time.sleep(3)
            mark("sheet")
            dump(page, "add a question")
            shot(page, "sheet")
            if write_question(page):
                time.sleep(2)
                mark("typed")
                dump(page, "typed")
                shot(page, "typed")
                if tap(page, "Add it"):
                    time.sleep(5)
                    mark("added")
                    dump(page, "added")
                    shot(page, "added")
                    time.sleep(4)

        time.sleep(2)
        mark("end")
        (TAKES / "part11-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part11.webm")
        print("video", TAKES / "part11.webm")


if __name__ == "__main__":
    main()
