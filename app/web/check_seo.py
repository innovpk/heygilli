#!/usr/bin/env python3
"""Fail the deploy if the public pages' structured data has drifted from them.

Every public page needs the tags a link preview and a search result are built
from, a canonical that says which URL it is, a place in the sitemap, and a line
in deploy_web.sh that actually copies it. The list of pages is the glob rather
than a list kept by hand: a page added to app/web/ and forgotten in the sitemap
used to deploy silently and be found by nobody, because the check only knew
about the three pages someone had thought to name.

Three of them are meant to be found and quoted — the home page, /try and /faq —
and those also carry JSON-LD.

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

SITE = "https://heygilli.com/"

#: Pages meant to be found and quoted. These carry JSON-LD on top of the tags
#: every public page needs.
RICH = {"about.html", "try.html", "faq.html"}

#: Not public pages, so not held to any of this. index.html is the Flutter
#: shell used when the app is served from app/web/ directly; the deployed
#: /app/index.html comes out of the Flutter build instead.
NOT_PUBLISHED = {"index.html"}

FAQ_PAGE = "faq.html"
DEPLOY = HERE.parent.parent / "deploy_web.sh"


def url_of(name: str) -> str:
    """The URL a page file is served at. about.html is the site root."""
    return SITE + ("" if name == "about.html" else Path(name).stem)


def public_pages() -> dict[str, str]:
    """Page file -> the canonical URL it must declare, and the sitemap must list."""
    pages = {p.name: url_of(p.name) for p in sorted(HERE.glob("*.html"))
             if p.name not in NOT_PUBLISHED}
    # The glob is the source of truth for which pages exist, but RICH names
    # three of them, and a rename that lands in one and not the other would
    # quietly stop checking a page's schema rather than fail.
    for name in sorted(RICH - pages.keys()):
        fail(f"{name} is named in RICH but is not a page in app/web/")
    return pages


def fail(msg: str) -> None:
    print(f"SEO check failed: {msg}", file=sys.stderr)
    sys.exit(1)


def graph_of(name: str, page: str, required: bool) -> tuple[list[dict], str]:
    """The page's JSON-LD @graph, or ([], "") when it has none and need not."""
    block = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
    if not block:
        if required:
            fail(f"no JSON-LD on {name}")
        return [], ""
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
    pages = public_pages()
    faq_entries = 0
    for name, url in pages.items():
        page = (HERE / name).read_text()
        for tag in required:
            if not re.search(re.escape(tag) + r"[\s>]", page):
                fail(f"{name}: missing {tag}")
        canon = re.search(r'<link rel="canonical" href="([^"]+)"', page)
        if not canon or canon.group(1) != url:
            fail(f"{name}: canonical should be {url}, is {canon.group(1) if canon else 'missing'}")
        # A page outside RICH need not carry JSON-LD, but if it does, it is
        # still held to owning at most the schema that belongs to it.
        graph, ld_block = graph_of(name, page, required=name in RICH)
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
    for name, url in sorted(pages.items()):
        if url not in locs:
            fail(f"{url} ({name}) is not in sitemap.xml")
    # And the other way: a loc left behind by a page that was renamed or
    # deleted is a URL the sitemap hands to Google for it to fetch a 404.
    for url in sorted(locs - set(pages.values())):
        fail(f"sitemap.xml lists {url}, which no page in app/web/ is served at")

    # In the sitemap and never copied is the same as not published. deploy.sh
    # names each page one at a time, so a new page is two edits, and the
    # sitemap is the one people remember.
    deploy = DEPLOY.read_text()
    for name in sorted(pages):
        if f"app/web/{name}" not in deploy:
            fail(f"{name} is a public page but {DEPLOY.name} never copies it")

    for name in ("robots.txt", "llms.txt", "og.png", "favicon.png", "site.css"):
        if not (HERE / name).exists():
            fail(f"{name} is referenced but not in app/web/")

    print(f"SEO check passed: {len(pages)} pages "
          f"({', '.join(sorted(pages))}), {faq_entries} FAQ entries match {FAQ_PAGE}")


if __name__ == "__main__":
    main()
