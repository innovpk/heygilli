"""Take 12b, the half take 12 could not reach: allowing videos, then the inbox.

Take 12 filmed the questionnaire and saved it, then tried to walk out of the
policy screen to the Channels tab. `Back` fires `Navigator.maybePop`, but the
screen behind it was still re-fetching, so the taps that followed landed on a
spinner and both beats were lost. This starts from a fresh load instead, which
needs no pop at all.

`_curateNow` only starts a job -- its own comment says the work takes minutes
and its snackbar says so to the parent. So "Check for new videos" is filmed
for what it is, a request, and the review screen is then worked with the queue
that already exists rather than waiting minutes on camera for a new one.

What is written, and when:

  * Flipping a switch writes nothing. `_flip` sets local state and shows a
    "Moved to Shown" snackbar with an Undo.
  * The `Allow N videos` button is the only commit: `reviewDecide(approve:,
    hide:)`. `Allow all` is a different button that approves every suggestion
    at once, so the commit is matched by shape, never by substring.
  * Videos Gilli kept back are excluded from `_suggested`, so they are only
    ever allowed by hand, on the Hidden tab. That is the beat.

Marks every step in takes/part12b-marks.json.
"""
import json
import re
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, labels

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part12b-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = str(HERE / "profile")

#: How many of Gilli's kept-back videos this parent decides to allow.
TO_FLIP = 5

#: Every button on screen, so a control can be matched by shape rather than a
#: substring that also matches a different button ("Allow all").
BUTTONS = """
() => {
  const host = document.querySelector('flt-semantics-host') || document.body;
  return [...host.querySelectorAll('flt-semantics[role=button]')].map(b => {
    const r = b.getBoundingClientRect();
    return {label: (b.getAttribute('aria-label') || b.textContent || '').trim(),
            x: Math.round(r.left + r.width / 2),
            y: Math.round(r.top + r.height / 2),
            y0: Math.round(r.top)};
  }).filter(b => b.label);
}
"""

#: The per-video switches. Matched on the role *or* on carrying a checked
#: state, because which one Flutter emits for a `Switch` is not worth
#: assuming twice in one afternoon.
SWITCHES = """
() => {
  const host = document.querySelector('flt-semantics-host') || document.body;
  return [...host.querySelectorAll('flt-semantics')]
    .filter(e => e.getAttribute('role') === 'switch' || e.hasAttribute('aria-checked'))
    .map(e => {
      const r = e.getBoundingClientRect();
      return {role: e.getAttribute('role') || '',
              checked: e.getAttribute('aria-checked'),
              x: Math.round(r.left + r.width / 2),
              y: Math.round(r.top + r.height / 2)};
    });
}
"""

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"  mark {name} @ {marks[name]}", flush=True)
    (TAKES / "part12b-marks.json").write_text(json.dumps(marks, indent=1))


def texts(page):
    return [l.split(" | ", 1)[1] for l in labels(page) if " | " in l]


def has(page, text) -> bool:
    return any(text in t for t in texts(page))


def shot(page, name) -> None:
    page.screenshot(path=str(SHOTS / f"{name}.png"))


#: Every node with a label, whatever its role, with somewhere to click it.
NODES = """
() => {
  const host = document.querySelector('flt-semantics-host') || document.body;
  return [...host.querySelectorAll('flt-semantics')].map(e => {
    const r = e.getBoundingClientRect();
    const own = [...e.childNodes].filter(n => n.nodeType === 3)
      .map(n => n.textContent).join(' ').trim();
    return {role: e.getAttribute('role') || '-',
            label: ((e.getAttribute('aria-label') || own || '')
                     .replace(/\\s+/g, ' ').trim()),
            x: Math.round(r.left + r.width / 2),
            y: Math.round(r.top + r.height / 2),
            area: Math.round(r.width) * Math.round(r.height)};
  }).filter(n => n.label && n.area > 0);
}
"""


def tap(page, text, nth=-1, required=True) -> bool:
    """Click the smallest labelled node containing `text`, by coordinate.

    Two things this had wrong. The tabs are `role="tab"`, not "button", so
    matching buttons first and falling back to any `flt-semantics` picked a
    huge ancestor -- and `locator.click()` on that ancestor hangs forever
    with "flutter-view intercepts pointer events". Smallest-first picks the
    label itself, and a mouse click at its centre is what has never failed.
    """
    hits = [n for n in page.evaluate(NODES) if text in n["label"]]
    if hits:
        hits.sort(key=lambda n: n["area"])
        n = hits[0]
        page.mouse.click(n["x"], n["y"])
        return True
    if required:
        shot(page, f"NOTFOUND-{text[:18]}")
        for line in labels(page)[:50]:
            print("   ", line, flush=True)
        raise SystemExit(f"not found: {text}")
    return False


def tap_matching(page, pattern: str, required=True) -> str | None:
    """Click the one button whose whole label matches, and say which it was."""
    hit = [b for b in page.evaluate(BUTTONS) if re.fullmatch(pattern, b["label"])]
    if not hit:
        if required:
            shot(page, f"NOMATCH-{pattern[:12]}")
            print("    buttons:", [b["label"] for b in page.evaluate(BUTTONS)],
                  flush=True)
            raise SystemExit(f"no button matching {pattern!r}")
        return None
    page.mouse.click(hit[0]["x"], hit[0]["y"])
    return hit[0]["label"]


def counts(page) -> tuple[int, int]:
    """The two segment labels: how many are shown, how many hidden."""
    shown = hidden = -1
    for t in texts(page):
        m = re.fullmatch(r"Shown \((\d+)\)", t.strip())
        if m:
            shown = int(m.group(1))
        m = re.fullmatch(r"Hidden \((\d+)\)", t.strip())
        if m:
            hidden = int(m.group(1))
    return shown, hidden


def beat(name: str, fn) -> None:
    """One missing beat must not cost the ones after it."""
    try:
        fn()
    except (Exception, SystemExit) as e:      # noqa: BLE001 - filming, not testing
        print(f"  ! {name} failed: {type(e).__name__}: {e}", flush=True)


def main() -> None:
    global t0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            PROFILE, channel="chrome", headless=True,
            viewport={"width": W, "height": H}, device_scale_factor=1,
            record_video_dir=str(TAKES / "part12b-video"),
            record_video_size={"width": W, "height": H},
            args=["--autoplay-policy=no-user-gesture-required"])
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        time.sleep(6)

        if not has(page, "Enter kid mode"):
            tap(page, "Rayan", nth=0)
            time.sleep(4)
        mark("kid_page")

        # --- 1. the Channels tab
        tap(page, "Channels", nth=-1)
        time.sleep(4)
        mark("channels_tab")
        shot(page, "channels")

        # --- 2. the Curator, told to go and read. Minutes of server work, so
        # this films the asking and the answer it gives, and moves on.
        def curator():
            tap(page, "Check for new videos", nth=0)
            time.sleep(3)
            mark("check_pressed")
            shot(page, "checking")
            if has(page, "Looking for new videos"):
                print("snackbar: the Curator says it started", flush=True)
        beat("check for new videos", curator)

        # --- 3. the verdicts
        def verdicts():
            tap(page, "will see", nth=0)
            mark("review_opening")
            for _ in range(20):               # the queue arrives a few at a time
                time.sleep(3)
                if counts(page) != (-1, -1):
                    break
            shown, hidden = counts(page)
            mark("review_open")
            shot(page, "review")
            print(f"queue: shown={shown} hidden={hidden}", flush=True)
            if hidden <= 0:
                print("! nothing kept back, so nothing to allow by hand",
                      flush=True)
                return

            tap(page, "Hidden (", nth=0)
            time.sleep(4)
            mark("hidden_tab")
            shot(page, "hidden")

            # --- 4. allowing some of what Gilli kept back, by hand
            found = page.evaluate(SWITCHES)
            print(f"switches: {len(found)} "
                  f"roles={sorted({s['role'] for s in found})}", flush=True)
            if not found:
                print("    buttons here:",
                      [b["label"] for b in page.evaluate(BUTTONS)][:16], flush=True)
                raise SystemExit("no switches on the Hidden tab")

            flipped = 0
            for _ in range(TO_FLIP):
                # Re-read every time: a flipped card leaves this tab, so every
                # coordinate below it moves. Always the first one.
                now = [s for s in page.evaluate(SWITCHES)
                       if 130 < s["y"] < H - 150]
                if not now:
                    break
                page.mouse.click(now[0]["x"], now[0]["y"])
                flipped += 1
                time.sleep(1.2)
            mark("flipped")
            print(f"flipped {flipped}", flush=True)
            shot(page, "flipped")

            # --- 5. the only control that writes
            got = tap_matching(page, r"Allow \d+ videos?", required=False)
            if not got:
                print("! no commit button; nothing written", flush=True)
                return
            print(f"committing with {got!r}", flush=True)
            time.sleep(8)
            mark("allowed")
            shot(page, "allowed")
        beat("verdicts", verdicts)

        # --- 6. the inbox, last: what arrived without being asked for
        def inbox():
            page.goto(URL)
            semantics_on(page)
            time.sleep(6)
            tap(page, "Inbox", nth=0)
            time.sleep(7)
            mark("inbox")
            shot(page, "inbox")
            print("inbox is empty" if has(page, "All caught up")
                  else "inbox has videos waiting", flush=True)
        beat("inbox", inbox)

        mark("end")
        ctx.close()
    print(json.dumps(marks, indent=1))


if __name__ == "__main__":
    main()
