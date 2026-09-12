"""Render each <section> of slides.html to a 1920x1080 PNG in slides/."""
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).parent
OUT = HERE / "slides"
OUT.mkdir(exist_ok=True)

with sync_playwright() as p:
    browser = p.chromium.launch(channel="chrome", headless=True)
    page = browser.new_page(viewport={"width": 1920, "height": 1080})
    page.goto((HERE / "slides.html").as_uri())
    page.evaluate("document.fonts.ready")
    time.sleep(2)
    for sid in page.eval_on_selector_all("section", "els => els.map(e => e.id)"):
        page.locator(f"#{sid}").screenshot(path=str(OUT / f"{sid}.png"))
        print("rendered", sid)
    browser.close()
