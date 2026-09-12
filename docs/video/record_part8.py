"""Take 8: the parent-side scenes the cut has no footage of yet.

  19-ask          asking Gilli about a video in your own words (Explainer)
  20-own-question adding a question of your own to a video, asked as typed
  21-break        the parent's own break line, and the PIN on the way out
  22-import       bringing existing subscriptions in

What the first three attempts got wrong, all of it mine:

  * Attempt 1 clicked a bare `flt-semantics` container, which sits under the
    flutter-view and can never take a click: Playwright retried for thirty
    seconds and raised, so one bad label cost the whole take.
  * Attempt 2 over-corrected to role=button at nth=0, and the sheets takes 1b
    and 4 opened are reached at nth=-1.
  * Attempt 3 found an "Add" — the sidebar's "Add a kid" — because the
    Channels tab has two of them. The channels one is labelled exactly "Add".
    And the screened list is not a tab at all: it is behind the card that says
    "What Rayan will see".

Kid mode is a one-way door (leaving wants a parent PIN this household has not
set), so the break-and-PIN scene stays last.
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
SHOTS = TAKES / "part8-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile"

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"{marks[name]:7.1f}s  {name}", flush=True)


def has(page, text) -> bool:
    return page.locator("flt-semantics").filter(has_text=text).count() > 0


def dump(page, tag):
    print(f"--- {tag}", flush=True)
    for line in labels(page)[:40]:
        print("  ", line, flush=True)


def click(loc, which=0) -> bool:
    try:
        loc.nth(which).click(timeout=4000)
        return True
    except PlaywrightError:
        return False


def tap_exact(page, label: str) -> bool:
    """The control whose aria-label is exactly this.

    "Add" on the Channels tab is the channels one; "Add a kid" in the sidebar
    also contains "Add", and a substring match finds that one first.
    """
    loc = page.locator(f'flt-semantics[role=button][aria-label="{label}"]')
    if loc.count() and click(loc, -1):
        return True
    print(f"  (no exact {label!r})", flush=True)
    return False


def tap(page, text, nth=-1) -> bool:
    for sel in ("flt-semantics[role=button]", "flt-semantics[role=tab]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f"{sel}[aria-label*=\"{text}\"]")
        if loc.count() == 0:
            continue
        for which in (nth, 0, -1):
            if click(loc, which):
                return True
    print(f"  (no clickable {text!r})", flush=True)
    return False


def first(page, *texts) -> bool:
    return any(tap(page, t) for t in texts)


def typing(page, text: str) -> bool:
    if not page.locator("input").count():
        print("  (no text field on screen)", flush=True)
        return False
    try:
        page.locator("input").last.click(timeout=5000)
    except PlaywrightError:
        return False
    page.keyboard.type(text, delay=55)
    return True


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def home(page):
    for _ in range(4):
        if has(page, "Enter kid mode"):
            return
        if not first(page, "Back", "Close", "Done"):
            try:
                page.go_back()
            except PlaywrightError:
                pass
        time.sleep(2)


def scene(name):
    def wrap(fn):
        try:
            fn()
        except Exception as e:  # noqa: BLE001 - a take is worth more than a scene
            print(f"!! {name} failed: {type(e).__name__}: {e}", flush=True)
        return fn
    return wrap


def open_add_sheet(page) -> bool:
    """Channels tab -> the channels Add sheet (not "Add a kid")."""
    if not tap(page, "Channels"):
        return False
    time.sleep(4)
    if tap_exact(page, "Add"):
        time.sleep(3)
        return True
    return tap(page, "Or add one yourself")


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(PROFILE), channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part8-video"), record_video_size={"width": W, "height": H},
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
        shot(page, "kid-page")

        # --- 19: ask Gilli about a video, in your own words.
        @scene("19-ask")
        def _ask():
            if not open_add_sheet(page):
                return
            mark("add_sheet")
            dump(page, "add sheet")
            shot(page, "add-sheet")
            if not first(page, "Check a video or channel", "Check a link"):
                return
            time.sleep(3)
            mark("check_screen")
            shot(page, "check-screen")
            if not tap(page, "Ask about this"):
                return
            time.sleep(3)
            mark("ask_sheet")
            shot(page, "ask-sheet")
            if not typing(page, "Is there anything scary in this one?"):
                return
            time.sleep(2)
            shot(page, "ask-typed")
            if first(page, "Ask Gilli", "Ask"):
                for _ in range(20):
                    time.sleep(3)
                    if has(page, "title only") or has(page, "watched"):
                        break
                mark("ask_answered")
                dump(page, "ask answered")
                shot(page, "ask-answered")
                time.sleep(4)

        home(page)

        # --- 22: bringing existing subscriptions in.
        @scene("22-import")
        def _import():
            if not open_add_sheet(page):
                return
            mark("add_sheet2")
            shot(page, "add-sheet2")
            if first(page, "subscriptions", "Import", "Takeout"):
                time.sleep(4)
                mark("import_screen")
                dump(page, "import")
                shot(page, "import")
                time.sleep(4)

        home(page)

        # --- 20: a question of the parent's own, on a video already screened.
        @scene("20-own-question")
        def _own_question():
            if not tap(page, "Channels"):
                return
            time.sleep(3)
            # Not a tab: the card that says what the child will see.
            if not first(page, "What Rayan will see", "Shown and hidden videos"):
                return
            time.sleep(5)
            mark("shown_list")
            dump(page, "shown and hidden")
            shot(page, "shown-list")
            page.mouse.move(W / 2, H * 0.6)
            page.mouse.wheel(0, 400)
            time.sleep(3)
            shot(page, "shown-list-scrolled")
            if not tap(page, "Add a question"):
                return
            time.sleep(3)
            mark("own_question_sheet")
            shot(page, "own-question-sheet")
            if not typing(page, "What did the volcano do to the rocks?"):
                return
            time.sleep(2)
            mark("own_question_typed")
            shot(page, "own-question-typed")
            if tap(page, "Add it"):
                time.sleep(4)
                mark("own_question_added")
                shot(page, "own-question-added")

        home(page)

        # --- 21: the parent's own break line, then the PIN on the way out.
        @scene("21-break")
        def _break():
            if tap(page, "Rules"):
                time.sleep(3)
                page.mouse.move(W / 2, H * 0.6)
                page.mouse.wheel(0, 500)
                time.sleep(3)
                mark("break_messages")
                shot(page, "break-messages")
                page.mouse.wheel(0, -2000)
                time.sleep(2)
            tap(page, "Overview")
            time.sleep(2)
            if not tap(page, "Enter kid mode"):
                return
            time.sleep(7)
            mark("kid_mode")
            shot(page, "kid-mode")
            if first(page, "Parent", "Leave kid mode"):
                time.sleep(4)
                mark("pin_gate")
                shot(page, "pin-gate")
                time.sleep(3)

        time.sleep(2)
        mark("end")
        (TAKES / "part8-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / "part8.webm")
        print("video", TAKES / "part8.webm")


if __name__ == "__main__":
    main()
