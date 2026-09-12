"""Take 12, the parent's half: answer every question, then approve videos.

Three beats the cut is missing, in the order a parent actually meets them:

  1. The questionnaire, answered all the way through rather than the first
     card.
  2. "Check for new videos", which is the Curator being told to go and read.
  3. "What Rayan will see", where the verdicts are and where a parent allows
     some of what Gilli kept back.

Then the inbox, last, because the point of it is what arrives on its own.

What the screens actually are, since three attempts were written against a
guess at them (the tree is in takes/policy-dump.txt):

  * The Rules tab opens `PolicyScreen` as a `ListView` of ten cards, not the
    paged wizard with a "Next" button -- that is `PolicyScreen(setup: true)`,
    reached only while adding a child.
  * Each card is a `group` whose three buttons are its children. Its label is
    on text nodes, not `aria-label`, and Flutter joins the merged parts with
    newlines: question, `why`, then the chosen `effect`. The question is the
    first line; matching keywords against the whole label would match channel
    names quoted in the `why`.
  * The list is virtualised, so a card can only be tapped while it is near
    the viewport. Small scroll steps: one big scroll takes a card from below
    the fold to above it without ever stopping in reach.
  * `_choose` toggles, and nothing on the screen saves until the button. Both
    are used here: the answers are cleared and re-entered so the answering is
    on camera, and because the end state matches what is stored, every
    answer keeps the weight it had earned (`_save` only resets the weight of
    a choice that actually changed).
  * On the review screen `Allow all` and the `Allow N videos` button both
    contain "Allow ". Only the second commits the switches this take flips
    by hand; the first approves every suggestion at once. Matched by shape.

Marks every step in takes/part12-marks.json.
"""
import json
import re
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, W, H, semantics_on, labels

HERE = Path(__file__).parent
TAKES = HERE / "takes"
SHOTS = TAKES / "part12-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = str(HERE / "profile")

# What this household says, decided from the question rather than its
# position: the Coach drafts these fresh on each visit, so the wording and the
# order both move between runs and a fixed list of ten answers would land on
# whatever happened to be third that morning.
RATHER_NOT = ("prank", "violence", "violent", "scary", "horror", "fight",
              "weight", "diet", "appearance", "makeup", "gambl")
SOMETIMES = ("compilation", "entertain", "unboxing", "challenge", "reaction",
             "game", "gaming", "cartoon", "toy", "vlog", "viral", "followers",
             "popular online", "news", "politic")
NOTES = "Nothing about weight or diets, please."

#: `PolicyChoice.effect`, the line that appears under a chosen button. It is
#: merged into the card's own label, so it says both whether a tap registered
#: and which answer a card already carries.
EFFECT = {
    "Fine": "These go straight through",
    "Sometimes": "Gilli reads these more closely",
    "Rather not": "These come to your inbox to decide",
}
CHOICES = tuple(EFFECT)

#: One entry per question card: its label, and whichever of the three buttons
#: are currently rendered, each tagged so Playwright can click it.
#:
#: A card is the *innermost* node whose label holds a "?" -- the list and the
#: scaffold above it carry every question merged into one label, and would
#: otherwise look like a single card holding every button on the screen.
CARDS = """
() => {
  const CH = ['Fine', 'Sometimes', 'Rather not'];
  const host = document.querySelector('flt-semantics-host') || document.body;
  const all = [...host.querySelectorAll('flt-semantics')];
  const lab = e => {
    const a = e.getAttribute('aria-label');
    if (a && a.trim()) return a.trim();
    return [...e.childNodes].filter(n => n.nodeType === 3)
      .map(n => n.textContent).join('\\n').trim();
  };
  all.forEach(e => e.removeAttribute('data-hgtake'));
  const out = [];
  let tag = 0;
  for (const n of all) {
    const label = lab(n);
    if (!label.includes('?')) continue;
    const inner = [...n.querySelectorAll('flt-semantics')];
    if (inner.some(d => lab(d).includes('?'))) continue;   // an ancestor
    const buttons = [];
    for (const b of inner) {
      const l = lab(b);
      if (!CH.includes(l)) continue;
      const r = b.getBoundingClientRect();
      b.setAttribute('data-hgtake', String(++tag));
      buttons.push({
        label: l, tag: String(tag),
        x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2),
      });
    }
    out.push({label, buttons});
  }
  return out;
}
"""

#: The one control on the policy screen that writes. Reads "Saved" and does
#: nothing while the shown answers match the stored ones.
SAVE = """
() => {
  const host = document.querySelector('flt-semantics-host') || document.body;
  for (const b of host.querySelectorAll('flt-semantics[role=button]')) {
    const t = (b.getAttribute('aria-label') || b.textContent || '').trim();
    if (t === 'Saved' || t.startsWith('Save these')) {
      const r = b.getBoundingClientRect();
      return {label: t, x: Math.round(r.left + r.width / 2),
              y: Math.round(r.top + r.height / 2)};
    }
  }
  return null;
}
"""

#: Every button on screen, so a control can be matched by shape rather than by
#: a substring that also matches a different button ("Allow all").
BUTTONS = """
() => {
  const host = document.querySelector('flt-semantics-host') || document.body;
  return [...host.querySelectorAll('flt-semantics[role=button]')].map(b => {
    const r = b.getBoundingClientRect();
    return {label: (b.getAttribute('aria-label') || b.textContent || '').trim(),
            x: Math.round(r.left + r.width / 2),
            y: Math.round(r.top + r.height / 2)};
  }).filter(b => b.label);
}
"""

marks: dict[str, float] = {}
t0 = 0.0


def mark(name: str) -> None:
    marks[name] = round(time.time() - t0, 2)
    print(f"  mark {name} @ {marks[name]}", flush=True)
    (TAKES / "part12-marks.json").write_text(json.dumps(marks, indent=1))


def texts(page):
    return [l.split(" | ", 1)[1] for l in labels(page) if " | " in l]


def has(page, text) -> bool:
    return any(text in t for t in texts(page))


def shot(page, name) -> None:
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def tap(page, text, nth=-1, required=True) -> bool:
    for sel in ("flt-semantics[role=button]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f'{sel}[aria-label*="{text}"]')
        if loc.count():
            loc.nth(nth).click()
            return True
    if required:
        shot(page, f"NOTFOUND-{text[:18]}")
        for line in labels(page)[:60]:
            print("   ", line, flush=True)
        raise SystemExit(f"not found: {text}")
    return False


def tap_matching(page, pattern: str, required=True) -> str | None:
    """Click the one button whose whole label matches, and say which it was."""
    hit = [b for b in page.evaluate(BUTTONS) if re.fullmatch(pattern, b["label"])]
    if not hit:
        if required:
            shot(page, f"NOMATCH-{pattern[:14]}")
            print("    buttons:", [b["label"] for b in page.evaluate(BUTTONS)],
                  flush=True)
            raise SystemExit(f"no button matching {pattern!r}")
        return None
    page.mouse.click(hit[0]["x"], hit[0]["y"])
    return hit[0]["label"]


def question_of(label: str) -> str:
    """The question itself: the first line, without the `why` under it."""
    return label.split("\n")[0].strip()


def chosen_in(label: str) -> str | None:
    """Which answer this card already carries, read off its effect line."""
    return next((c for c in CHOICES if EFFECT[c] in label), None)


def wanted(question: str) -> str:
    """This household's answer to a question.

    Checked strongest-first, so "cartoon or game violence" is a "Rather not"
    on the violence rather than a "Sometimes" on the cartoons.
    """
    q = question.lower()
    if any(w in q for w in RATHER_NOT):
        return "Rather not"
    if any(w in q for w in SOMETIMES):
        return "Sometimes"
    return "Fine"


def scroll(page, dy: int = 300) -> None:
    page.mouse.move(W // 2, H // 2)
    page.mouse.wheel(0, dy)
    time.sleep(0.6)


def to_top(page) -> None:
    page.mouse.move(W // 2, H // 2)
    for _ in range(8):
        page.mouse.wheel(0, -900)
        time.sleep(0.25)
    time.sleep(0.8)


def sweep(page, act, pace: float, limit: int = 80) -> dict[str, str]:
    """Scroll the list top to bottom, letting `act` deal with each card once.

    `act(card, question)` returns the answer it settled on, or None to leave
    the card for a later turn. A button is only offered while it sits in the
    middle of the window: one under the top bar or half off the bottom is a
    worse click and a worse shot.
    """
    done: dict[str, str] = {}
    idle = 0
    for _ in range(limit):
        found = False
        # One card per read of the tree. Clearing an answer takes away its
        # effect and weight lines, so the card shrinks by about 60px and
        # everything below it slides up: coordinates captured for a whole
        # screenful are stale after the first tap, and the sixth click of a
        # batch lands between the chips instead of on one.
        for _ in range(20):
            todo = None
            for card in page.evaluate(CARDS):
                q = question_of(card["label"])
                if q in done or not card["buttons"]:
                    continue
                if not all(130 < b["y"] < H - 150 for b in card["buttons"]):
                    continue
                todo = (card, q)
                break
            if todo is None:
                break
            card, q = todo
            got = act(card, q)
            if got is None:
                done[q] = "skipped"
                continue
            done[q] = got
            found = True
            time.sleep(pace)
        idle = 0 if found else idle + 1
        if page.evaluate(SAVE) and idle >= 3:
            return done
        scroll(page)
    return done


def clear_all(page) -> dict[str, str]:
    """Take every answer off, so the answering itself can be filmed.

    Local state only -- `_choose` just mutates `_choices`, and nothing here
    reaches the server until the save button. A run that dies in the middle
    of this leaves the stored policy untouched.
    """
    def act(card, q):
        cur = chosen_in(card["label"])
        if cur is None:
            return "already clear"
        target = next((b for b in card["buttons"] if b["label"] == cur), None)
        if target is None:
            return None
        page.mouse.click(target["x"], target["y"])
        time.sleep(0.35)
        after = next((c for c in page.evaluate(CARDS)
                      if question_of(c["label"]) == q), None)
        if after is not None and chosen_in(after["label"]) is not None:
            raise SystemExit(f"could not clear {q[:58]!r}")
        return cur

    return sweep(page, act, pace=0.15)


def answer_all(page) -> dict[str, str]:
    """Answer every question, checking each tap before the card scrolls away."""
    def act(card, q):
        choice = wanted(q)
        if chosen_in(card["label"]) == choice:
            print(f"  = {choice:<11} {q[:62]}", flush=True)
            return choice
        target = next((b for b in card["buttons"] if b["label"] == choice), None)
        if target is None:
            print(f"  ! no {choice!r} button on {q[:58]!r}", flush=True)
            return None
        page.mouse.click(target["x"], target["y"])
        time.sleep(0.8)
        after = next((c for c in page.evaluate(CARDS)
                      if question_of(c["label"]) == q), None)
        got = chosen_in(after["label"]) if after else "card gone"
        if got != choice:
            shot(page, "tap-missed")
            raise SystemExit(f"tap did not register on {q[:58]!r}: "
                             f"wanted {choice}, card shows {got}")
        print(f"  + {choice:<11} {q[:62]}", flush=True)
        return choice

    return sweep(page, act, pace=0.45)


def value_of(page) -> str:
    return page.evaluate(
        "() => (document.activeElement && document.activeElement.value) || ''")


def write_notes(page) -> None:
    """Replace the parent's own words, emptying the box first.

    The last run pressed Meta+A, Control+A, Backspace and typed. Only the "N"
    was deleted, so the stored note became the sentence twice over -- and the
    check was `NOTES in got`, which a doubled string passes. The box is
    emptied a character at a time here, and both the empty and the final
    value are compared exactly.
    """
    save = page.evaluate(SAVE)
    if not save:
        raise SystemExit("no save button, so no notes card above it")
    field = page.locator("textarea, input[type=text]")
    if field.count():
        field.last.click()
    else:
        page.mouse.click(save["x"], save["y"] - 60)
    time.sleep(0.6)
    tag = page.evaluate(
        "() => (document.activeElement && document.activeElement.tagName) || ''")
    if tag not in ("TEXTAREA", "INPUT"):
        shot(page, "notes-no-focus")
        raise SystemExit(f"notes box never took focus (active: {tag!r})")

    page.keyboard.press("Meta+A")
    page.keyboard.press("Backspace")
    if value_of(page):
        page.keyboard.press("End")
        for _ in range(len(value_of(page)) + 5):
            page.keyboard.press("Backspace")
    left = value_of(page)
    if left:
        shot(page, "notes-not-cleared")
        raise SystemExit(f"notes box would not empty: {left[:70]!r}")

    page.keyboard.type(NOTES, delay=28)
    time.sleep(1)
    got = value_of(page)
    if got != NOTES:                       # exact: a doubled string is not a pass
        shot(page, "notes-wrong")
        raise SystemExit(f"notes wrong.\n  wanted {NOTES!r}\n  got    {got!r}")
    print(f"notes: {got!r}", flush=True)


def beat(name: str, fn) -> None:
    """A step after the questionnaire. One that misses must not cost the rest.

    Catches SystemExit too: `tap` raises it, and the last run lost the whole
    back half of the take to one missing label.
    """
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
            record_video_dir=str(TAKES / "part12-video"),
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
        shot(page, "kid-page")

        # --- 1. every question, not the first one
        tap(page, "Rules", nth=-1)
        time.sleep(3)
        mark("rules_tab")
        shot(page, "rules")
        tap(page, "What your household wants", nth=0)
        time.sleep(7)
        mark("questions_open")
        shot(page, "question-first")

        # Off camera, in effect: fast, and trimmed in the cut. Only so the
        # answering that follows is a parent answering rather than a parent
        # looking at answers they gave last week.
        cleared = clear_all(page)
        mark("cleared")
        print(f"cleared {len(cleared)} questions", flush=True)
        to_top(page)
        mark("back_to_top")

        done = answer_all(page)
        mark("answered_all")
        # Only real answers count. A card `act` gave up on is marked done so
        # the sweep stops retrying it, and counting those as answered would
        # let a half-filled questionnaire reach the save button.
        answered = {q: v for q, v in done.items() if v in CHOICES}
        skipped = sorted(q for q, v in done.items() if v not in CHOICES)
        tally = {c: sum(1 for v in answered.values() if v == c) for c in CHOICES}
        print(f"answered {len(answered)} of {len(cleared)}: {tally}", flush=True)
        if skipped:
            print(f"  skipped: {skipped}", flush=True)
        if len(answered) < len(cleared):
            shot(page, "too-few-answered")
            raise SystemExit(
                f"cleared {len(cleared)} but answered only {len(answered)}")

        write_notes(page)
        mark("notes_typed")
        shot(page, "notes")

        save = page.evaluate(SAVE)
        if save and save["label"].startswith("Save these"):
            page.mouse.click(save["x"], save["y"])
            time.sleep(7)
            now = page.evaluate(SAVE)
            mark("saved")
            shot(page, "saved")
            print("saved" if now and now["label"] == "Saved"
                  else f"! button still reads {now and now['label']!r}", flush=True)
        else:
            print(f"! nothing to save: button reads {save and save['label']!r}",
                  flush=True)
            shot(page, "already-saved")

        # --- 2. tell the Curator to go and read. Back first: the policy
        # screen is a pushed route, and the tabs are on the page under it.
        def curator():
            tap(page, "Back", nth=0)
            time.sleep(3)
            mark("back_to_kid")
            tap(page, "Channels", nth=-1)
            time.sleep(3)
            mark("channels_tab")
            shot(page, "channels")
            tap(page, "Check for new videos", nth=0)
            time.sleep(4)
            mark("check_pressed")
            shot(page, "checking")
        beat("check for new videos", curator)

        # --- 3. the verdicts, and allowing some of what Gilli kept back
        def verdicts():
            tap(page, "will see", nth=0)
            time.sleep(10)
            mark("review_open")
            shot(page, "review")
            # Kept-back videos are never seeded into the answers, so this tab
            # is the only place they can be switched on by hand.
            tap(page, "Hidden (", nth=0, required=False)
            time.sleep(4)
            mark("hidden_tab")
            shot(page, "hidden")
            switches = page.locator('flt-semantics[role=switch]')
            n = switches.count()
            if not n:
                print("    no switches; buttons here:",
                      [b["label"] for b in page.evaluate(BUTTONS)][:14], flush=True)
            flipped = 0
            for i in range(min(5, n)):
                switches.nth(i).click()
                flipped += 1
                time.sleep(1.0)
            mark("flipped")
            print(f"flipped {flipped} of {n} switches", flush=True)
            shot(page, "flipped")
            # "Allow 7 videos", never "Allow all".
            got = tap_matching(page, r"Allow \d+ videos?", required=False)
            print(f"committed with {got!r}", flush=True)
            if got:
                time.sleep(6)
                mark("allowed")
                shot(page, "allowed")
        beat("verdicts", verdicts)

        # --- 4. the inbox, last: what arrived without being asked for
        def inbox():
            page.goto(URL)
            semantics_on(page)
            time.sleep(6)
            tap(page, "Inbox", nth=0)
            time.sleep(7)
            mark("inbox")
            shot(page, "inbox")
            empty = has(page, "All caught up")
            print("inbox is empty" if empty else "inbox has videos waiting",
                  flush=True)
        beat("inbox", inbox)

        mark("end")
        ctx.close()
    print(json.dumps(marks, indent=1))


if __name__ == "__main__":
    main()
