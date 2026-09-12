"""Probe the live site: set up a reader kid, run Find videos, and watch the real screening.

Records video of the whole run and saves a screenshot every 30 seconds while
waiting, so the timings and screens are known before the real takes.
"""
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).parent
OUT = HERE / "probe"
OUT.mkdir(exist_ok=True)
URL = "https://heygilli.com/app/"
W, H = 1920, 1080


def semantics_on(page):
    page.wait_for_selector("flt-semantics-placeholder", state="attached", timeout=60000)
    page.evaluate("document.querySelector('flt-semantics-placeholder').click()")
    time.sleep(1)


def labels(page):
    return page.evaluate(
        """() => [...new Set([...document.querySelectorAll('flt-semantics')]
        .map(e => ((e.getAttribute('role')||'') + ' | ' + (e.getAttribute('aria-label') || e.innerText || '').trim().replace(/\\s+/g,' ').slice(0, 90)))
        .filter(t => t.length > 4))]"""
    )


def dump(page, tag):
    print(f"--- {tag}")
    for line in labels(page)[:60]:
        print("  ", line)


def tap(page, text, nth=-1):
    for sel in ("flt-semantics[role=button]", "flt-semantics"):
        loc = page.locator(sel).filter(has_text=text)
        if loc.count() == 0:
            loc = page.locator(f"{sel}[aria-label*=\"{text}\"]")
        if loc.count():
            loc.nth(nth).click()
            return
    dump(page, f"NOT FOUND: {text}")
    raise SystemExit(1)


def shot(page, name):
    page.screenshot(path=str(OUT / f"{name}.png"))
    print("saved", name)


def main():
  with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome", headless=True)
    ctx = browser.new_context(viewport={"width": W, "height": H}, device_scale_factor=1,
                              record_video_dir=str(OUT / "video"), record_video_size={"width": W, "height": H})
    page = ctx.new_page()
    t0 = time.time()
    page.goto(URL)
    semantics_on(page)
    time.sleep(3)
    shot(page, "00-start")
    tap(page, "Set up without Google")
    time.sleep(6)
    shot(page, "01-after-signup")
    dump(page, "after signup")
    tap(page, "Add your first kid")
    time.sleep(2)
    page.locator("input[aria-label='What you call them at home']").click()
    page.keyboard.type("Rayan", delay=80)
    tap(page, "monkey")
    box = page.locator("input").nth(1).locator("xpath=..").bounding_box()
    page.mouse.click(box["x"] + box["width"] * 0.57, box["y"] + box["height"] / 2)
    time.sleep(1)
    for _ in range(4):
        if page.locator("flt-semantics").filter(has_text="Band 9").count():
            break
        page.keyboard.press("ArrowRight")
        time.sleep(0.4)
    shot(page, "02-add-kid")
    tap(page, "Save kid")
    time.sleep(5)
    shot(page, "03-questions")
    dump(page, "questions")
    browser_state = {"t_setup": round(time.time() - t0)}
    print(browser_state)
    ctx.close()
    browser.close()


if __name__ == "__main__":
    main()
