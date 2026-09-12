"""Take 15 on live heygilli.com: a reader's session with a video question, the
hint after silence, a written pick card, and the six games.

Fresh household. Two kids (Rayan 8, Lisa 5). Videos are allowed through the
API rather than filmed, and their plans pre-warmed, so every kid-mode second
on film is the real thing rather than a spinner. Recorded at a tablet
viewport (1280x720 at 1.5x) so the app fills the frame.

Marks in takes/part15-marks.json. Lisa's session is take 16 (record_part16.py),
which reuses this household's token.
"""
import json
import shutil
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

from probe_live import URL, dump, labels, semantics_on

HERE = Path(__file__).parent
TAKES = HERE / "takes"
TAKE = sys.argv[1] if len(sys.argv) > 1 else "part15"
SHOTS = TAKES / f"{TAKE}-shots"
SHOTS.mkdir(parents=True, exist_ok=True)
PROFILE = HERE / "profile15"
API = "https://heygilli-gateway.onrender.com"
W, H = 1280, 720
YAWN = "aQDbWyQ07Eg"   # 14 min, plan cached for 7_8: Q1 recall at 110s, Q2 written pick at 480s
CAT = "PJG7U1m8dyY"    # Wonder Kids, for Lisa

marks: dict[str, float] = {}
t0 = 0.0

FIND_TOKEN = """
async (api) => {
  for (const [k, v] of Object.entries(localStorage)) {
    if (!/token/i.test(k)) continue;
    const cands = [String(v), String(v).replace(/^"+|"+$/g, '')];
    try { const p = JSON.parse(v); if (typeof p === 'string') cands.push(p); } catch (e) {}
    for (const tok of cands) {
      const r = await fetch(api + '/kids', {headers: {'Authorization': 'Bearer ' + tok}});
      if (r.status === 200) return [k, tok];
    }
  }
  return null;
}
"""
CALL = """
async ([api, path, token, method, body]) => {
  const r = await fetch(api + path, {method, headers: {'Authorization': 'Bearer ' + token,
    'content-type': 'application/json'}, body: body ? JSON.stringify(body) : undefined});
  const t = await r.text();
  try { return [r.status, JSON.parse(t)]; } catch (e) { return [r.status, t]; }
}
"""


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
            try:
                loc.nth(nth).click(timeout=8000)
            except Exception:
                loc.nth(nth).click(force=True)
            return True
    if required:
        dump(page, f"NOT FOUND: {text}")
        raise SystemExit(1)
    print(f"  (skipped, not found: {text})", flush=True)
    return False


def shot(page, name):
    page.screenshot(path=str(SHOTS / f"{name}.png"))


def buttons(page) -> list[str]:
    return [l.split(" | ", 1)[1] for l in labels(page) if l.startswith("button | ")]


def api(page, token, path, method="GET", body=None):
    for attempt in range(4):
        try:
            status, data = page.evaluate(CALL, [API, path, token, method, body])
            break
        except Exception as e:  # a dropped fetch on a sleepy gateway; ask again
            print(f"  fetch failed ({attempt}): {str(e)[:80]}", flush=True)
            time.sleep(4)
    else:
        return 599, "fetch failed"
    if status >= 300:
        print(f"  API {method} {path} -> {status}: {str(data)[:200]}", flush=True)
    return status, data


def add_kid(page, name: str, band_text: str, steps: int) -> None:
    tap(page, "Add your first kid" if has(page, "Add your first kid") else "Add a kid", nth=0)
    time.sleep(2)
    page.locator("input[aria-label='What you call them at home']").click()
    page.keyboard.type(name, delay=90)
    time.sleep(0.5)
    if steps:
        slider = page.locator("input[type=range]").first
        slider.focus()
        for _ in range(steps + 2):
            if has(page, band_text):
                break
            slider.press("ArrowRight")
            time.sleep(0.4)
        print(f"  {name}: band text present = {has(page, band_text)}", flush=True)
    time.sleep(0.8)
    tap(page, "Save kid")
    time.sleep(4)
    if has(page, "Skip for now"):
        tap(page, "Skip for now")
        time.sleep(3)
    if has(page, "Next"):
        tap(page, "Next")
        time.sleep(2.5)
    if has(page, "Find videos"):
        tap(page, "Find videos")
        time.sleep(6)
    # Back to the household from the app root: the review screen's own back
    # lands on the kid page, where "Add a kid" sits under the rail.
    page.goto(URL)
    semantics_on(page)
    time.sleep(5)


def allow_and_warm(page, token, kid, video_id) -> None:
    status, res = api(page, token, f"/kids/{kid['id']}/check", "POST",
                      {"url": f"https://www.youtube.com/watch?v={video_id}"})
    print(f"  check {video_id} for {kid['nickname']}: {status} {str(res)[:120]}", flush=True)
    api(page, token, f"/kids/{kid['id']}/review", "POST", {"approve": [video_id], "hide": []})
    for i in range(30):
        status, s = api(page, token, "/sessions", "POST",
                        {"kid_id": kid["id"], "video_id": video_id, "device": "warm"})
        if status == 200:
            api(page, token, f"/sessions/{s['session_id']}/end", "POST", {})
            if s.get("plan_ready"):
                print(f"  plan ready for {kid['nickname']}/{video_id} after {i} polls", flush=True)
                return
        time.sleep(8)
    print("  plan never became ready", flush=True)


def scrub_forward(page) -> bool:
    """Drag the question strip to its end: the app clamps it to the next question."""
    loc = page.locator("flt-semantics[role=button]").filter(has_text="questions in this video")
    if loc.count() == 0:
        loc = page.locator("flt-semantics").filter(has_text="questions in this video")
    if loc.count() == 0:
        dump(page, "no track")
        return False
    box = loc.last.bounding_box()
    print(f"  track box {box}", flush=True)
    # The box reaches down over the back arrow's row: start on the strip
    # itself, near its top, and well clear of the arrow at the left.
    y = box["y"] + 5
    x0 = box["x"] + 70
    x1 = box["x"] + box["width"] - 3
    page.mouse.move(x0, y)
    page.mouse.down()
    for k in range(1, 16):
        page.mouse.move(x0 + (x1 - x0) * k / 15, y)
        time.sleep(0.04)
    page.mouse.up()
    return True


def card_centres(path: Path, page_w: int, page_h: int) -> list[tuple[float, float]]:
    """Where the pick cards are, from a screenshot: the white rounded squares.

    The cards carry no semantics, so they are found by eye. Rows are scanned
    for runs of near-white pixels at least 60 css px wide in the lower two
    thirds of the frame; runs with the same left and right edges are one
    card, whatever sits in the middle of it (an icon breaks the white into
    two shorter runs on those rows, which is why the rows are not required
    to be consecutive).
    """
    from PIL import Image

    im = Image.open(path).convert("RGB")
    sx, sy = im.width / page_w, im.height / page_h
    px = im.load()
    step = 4
    groups: list[list[float]] = []  # x0, x1, y_first, y_last, rows
    for y in range(int(im.height * 0.3), im.height, step):
        x = 0
        while x < im.width:
            if all(c > 232 for c in px[x, y]):
                x_start = x
                while x < im.width and all(c > 222 for c in px[x, y]):
                    x += step
                if x - x_start >= 60 * sx:
                    for g in groups:
                        if abs(g[0] - x_start) < 10 * sx and abs(g[1] - x) < 10 * sx:
                            g[3] = y
                            g[4] += 1
                            break
                    else:
                        groups.append([x_start, x, y, y, 1])
            x += step
    cards = [g for g in groups if (g[3] - g[2]) >= 60 * sy and g[4] >= 8]
    cards.sort(key=lambda g: (round(g[2] / (40 * sy)), g[0]))
    return [((g[0] + g[1]) / 2 / sx, (g[2] + g[3]) / 2 / sy) for g in cards]


def wait_for(page, texts, seconds, every=1.0) -> str:
    for _ in range(int(seconds / every)):
        for t in texts:
            if has(page, t):
                return t
        time.sleep(every)
    return ""


def main() -> None:
    global t0
    if PROFILE.exists():
        shutil.rmtree(PROFILE)
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
        t0 = time.time()
        mark("start")
        page.goto(URL)
        semantics_on(page)
        wait_for(page, ["Set up without Google"], 40)
        time.sleep(1)
        tap(page, "Set up without Google")
        time.sleep(5)
        mark("household")
        add_kid(page, "Rayan", "Band 7", 3)
        mark("rayan_added")
        add_kid(page, "Lisa", "Band 5", 0)
        mark("lisa_added")

        found = page.evaluate(FIND_TOKEN, API)
        if not found:
            dump(page, "no token")
            raise SystemExit(1)
        key, token = found
        (TAKES / f"{TAKE}-token.json").write_text(json.dumps({"key": key, "token": token}))
        _, kids = api(page, token, "/kids")
        items = kids["kids"] if isinstance(kids, dict) and "kids" in kids else kids
        rayan = next(k for k in items if k["nickname"] == "Rayan")
        lisa = next(k for k in items if k["nickname"] == "Lisa")
        allow_and_warm(page, token, rayan, YAWN)
        allow_and_warm(page, token, lisa, CAT)
        # The yawn video is fourteen minutes; the default longest-video limit
        # keeps it off the shelf.
        api(page, token, f"/kids/{rayan['id']}/limits", "PATCH", {"max_video_minutes": 30})
        mark("warmed")

        page.goto(URL)
        semantics_on(page)
        time.sleep(4)
        tap(page, "Rayan", nth=0, required=False)
        time.sleep(3)
        tap(page, "Enter kid mode")
        time.sleep(7)
        mark("shelf")
        dump(page, "shelf")
        shot(page, "shelf")
        # Search for it: the shelf is long and a tile far down has no
        # semantics until it scrolls into view.
        page.mouse.click(300, 62)  # the search field, under the greeting
        time.sleep(0.6)
        page.keyboard.type("yawn", delay=120)
        time.sleep(3)
        mark("searched")
        shot(page, "searched")
        if not has(page, "Why do we Yawn"):
            # The video sits in the last row, "More to watch"; a tile far
            # down has no semantics until it scrolls into view.
            page.mouse.move(640, 420)
            for _ in range(14):
                page.mouse.wheel(0, 400)
                time.sleep(0.7)
                if has(page, "Why do we Yawn"):
                    break
            time.sleep(1.5)
            mark("scrolled")
        tap(page, "Why do we Yawn", nth=0)
        time.sleep(9)
        mark("session_start")
        shot(page, "session")
        scrub_forward(page)
        mark("scrubbed")
        got = wait_for(page, ["Say it again", "Hold the mic"], 60)
        if not got:
            dump(page, "no question")
        mark("question")
        shot(page, "question")
        dump(page, "question")
        # The hint comes about ten seconds into the silence; its text is not
        # in the semantics, so it is marked by the clock.
        time.sleep(11.0)
        mark("hint")
        shot(page, "hint")
        time.sleep(3)
        mark("hint_held")
        # Let the restarted window run out: "no worries", then the video carries on.
        time.sleep(24)
        mark("silence_reply")
        shot(page, "silence-reply")
        time.sleep(7)
        mark("resumed")
        scrub_forward(page)
        got = wait_for(page, ["Say it again", "Hold the mic"], 60)
        time.sleep(1.5)
        mark("pick")
        shot(page, "pick")
        dump(page, "pick")
        centres = card_centres(SHOTS / "pick.png", W, H)
        print("  cards at", [(round(x), round(y)) for x, y in centres], flush=True)
        time.sleep(2.0)
        if len(centres) >= 2:
            x, y = centres[1]  # Kangaroo is the middle card in this plan
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

        # Back to the shelf (the session's back arrow, top left) and into the games.
        page.mouse.click(28, 25)
        time.sleep(4)
        if not tap(page, "Play a game with Gilli", required=False):
            page.goto(URL)
            semantics_on(page)
            time.sleep(6)
            tap(page, "Play a game with Gilli")
        time.sleep(3)
        mark("games")
        shot(page, "games")
        dump(page, "games")
        time.sleep(2)

        def play(label: str, mark_name: str, answer) -> None:
            tap(page, label, nth=0)
            time.sleep(3.5)
            mark(mark_name)
            shot(page, mark_name)
            dump(page, mark_name)
            target = answer(page)
            if target:
                time.sleep(1.0)
                tap(page, target, nth=0, required=False)
                mark(f"{mark_name}_won")
                time.sleep(3.5)
            else:
                time.sleep(4)
            tap(page, "Back", nth=0)
            time.sleep(2.5)

        def letter_answer(pg) -> str:
            for l in labels(pg):
                if "Find the small letter " in l:
                    return l.rsplit(" ", 1)[-1].strip()
                if "Find the letter " in l:
                    return l.rsplit(" ", 1)[-1].strip()
            return ""

        def sum_answer(pg) -> str:
            import re
            for l in labels(pg):
                m = re.search(r"(\d+) ([+−×÷]) (\d+) = \?", l)
                if m:
                    a, op, b = int(m.group(1)), m.group(2), int(m.group(3))
                    return str({"+": a + b, "−": a - b, "×": a * b, "÷": a // b}[op])
            return ""

        play("Letters", "letters", letter_answer)
        play("Numbers", "numbers", sum_answer)
        play("Who am I", "guess", lambda pg: "")
        play("Spot the animal", "spot", lambda pg: "")
        mark("end")
        (TAKES / f"{TAKE}-marks.json").write_text(json.dumps(marks, indent=1))
        video = page.video
        ctx.close()
        shutil.copy(Path(video.path()), TAKES / f"{TAKE}.webm")
        print("video", TAKES / f"{TAKE}.webm")


if __name__ == "__main__":
    main()
