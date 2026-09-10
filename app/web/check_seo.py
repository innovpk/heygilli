#!/usr/bin/env python3
"""Fail the deploy if the public pages' structured data has drifted from them.

Three pages are meant to be found and quoted: the home page, /try and /faq.
Each needs the tags a link preview and a search result are built from, a
canonical that says which URL it is, and a place in the sitemap.

The FAQ schema is what an answer engine quotes, and it is a copy of questions
that live in the HTML of /faq. A copy is only true while someone checks: edit
an answer on the page and the schema keeps serving the old wording to Google
and to every model that reads it, which is worse than no schema at all — a
confident wrong answer with a site behind it. It also has to live in exactly
one place: the same questions on two pages are two sources competing to be the
answer.
"""
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).parent

#: Page file -> the canonical URL it must declare, and the sitemap must list.
PAGES = {
    "about.html": "https://heygilli.com/",
    "try.html": "https://heygilli.com/try",
    "faq.html": "https://heygilli.com/faq",
}
FAQ_PAGE = "faq.html"


def fail(msg: str) -> None:
    print(f"SEO check failed: {msg}", file=sys.stderr)
    sys.exit(1)


def graph_of(name: str, page: str) -> tuple[list[dict], str]:
    block = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
    if not block:
        fail(f"no JSON-LD on {name}")
    try:
        return json.loads(block.group(1))["@graph"], block.group(0)
    except (ValueError, KeyError) as e:
        fail(f"JSON-LD on {name} does not parse: {e}")


def plain_text(page: str, ld_block: str) -> str:
    # The JSON-LD has to come out before the tags do. Stripping tags leaves the
    # contents of every <script> behind, so the schema's own questions end up in
    # the "page text" and every one of them matches itself — the check passed
    # while the page and the schema said different things.
    body = page.replace(ld_block, "")
    body = re.sub(r"<script.*?</script>", " ", body, flags=re.S)
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", body))


def main() -> None:
    # Matched to the closing quote. "og:image" on its own is a substring of
    # og:image:width, so deleting the real tag still looked present.
    required = [
        r'property="og:image"',
        r'property="og:url"',
        r'property="og:title"',
        r'property="og:description"',
        r'name="twitter:card"',
        r'name="description"',
    ]
    faq_entries = 0
    for name, url in PAGES.items():
        path = HERE / name
        if not path.exists():
            fail(f"{name} is missing")
        page = path.read_text()
        for tag in required:
            if not re.search(re.escape(tag) + r"[\s>]", page):
                fail(f"{name}: missing {tag}")
        canon = re.search(r'<link rel="canonical" href="([^"]+)"', page)
        if not canon or canon.group(1) != url:
            fail(f"{name}: canonical should be {url}, is {canon.group(1) if canon else 'missing'}")
        graph, ld_block = graph_of(name, page)
        has_faq = any(n.get("@type") == "FAQPage" for n in graph)
        if name != FAQ_PAGE and has_faq:
            fail(f"{name} carries an FAQPage; it belongs on {FAQ_PAGE} only")
        if name != FAQ_PAGE:
            continue

        if not has_faq:
            fail(f"no FAQPage in the JSON-LD on {FAQ_PAGE}")
        faq = next(n for n in graph if n.get("@type") == "FAQPage")
        on_page = len(re.findall(r'<details class="faq"', page))
        if len(faq["mainEntity"]) != on_page:
            fail(f"{on_page} questions on {FAQ_PAGE}, {len(faq['mainEntity'])} in its schema")
        plain = plain_text(page, ld_block)
        for entry in faq["mainEntity"]:
            question = entry["name"]
            answer = entry["acceptedAnswer"]["text"]
            if question not in plain:
                fail(f"schema asks a question the page does not: {question!r}")
            # Prefix rather than the whole string: the page wraps and the schema
            # does not, and a link in an answer is text here and markup there.
            if answer[:60] not in plain:
                fail(f"schema answers {question!r} with wording the page does not use")
        faq_entries = len(faq["mainEntity"])

    try:
        tree = ET.parse(HERE / "sitemap.xml")
    except ET.ParseError as e:
        fail(f"sitemap.xml is malformed: {e}")
    locs = {el.text for el in tree.iter("{http://www.sitemaps.org/schemas/sitemap/0.9}loc")}
    for name, url in PAGES.items():
        if url not in locs:
            fail(f"{url} ({name}) is not in sitemap.xml")

    for name in ("robots.txt", "llms.txt", "og.png", "favicon.png", "site.css"):
        if not (HERE / name).exists():
            fail(f"{name} is referenced but not in app/web/")

    print(f"SEO check passed: {len(PAGES)} pages, {faq_entries} FAQ entries match {FAQ_PAGE}")


if __name__ == "__main__":
    main()
