#!/usr/bin/env python3
"""Fail the deploy if the structured data has drifted from the page.

The FAQ schema is what an answer engine quotes, and it is a copy of questions
that live in the HTML a few hundred lines below it. A copy is only true while
someone checks: edit an answer on the page and the schema keeps serving the
old wording to Google and to every model that reads it, which is worse than
having no schema at all — it is a confident wrong answer with a site behind it.
"""
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).parent


def fail(msg: str) -> None:
    print(f"SEO check failed: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    page = (HERE / "about.html").read_text()

    block = re.search(r'<script type="application/ld\+json">(.*?)</script>', page, re.S)
    if not block:
        fail("no JSON-LD on the landing page")
    try:
        graph = json.loads(block.group(1))["@graph"]
    except (ValueError, KeyError) as e:
        fail(f"JSON-LD does not parse: {e}")

    # The JSON-LD has to come out before the tags do. Stripping tags leaves
    # the contents of every <script> behind, so the schema's own questions end
    # up in the "page text" and every one of them matches itself — the check
    # passed while the page and the schema said different things.
    body = page.replace(block.group(0), "")
    body = re.sub(r"<script.*?</script>", " ", body, flags=re.S)
    plain = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", body))

    faq = next((n for n in graph if n.get("@type") == "FAQPage"), None)
    if faq is None:
        fail("no FAQPage in the JSON-LD")

    on_page = len(re.findall(r"<details class=\"faq\"", page))
    if len(faq["mainEntity"]) != on_page:
        fail(f"{on_page} questions on the page, {len(faq['mainEntity'])} in the schema")

    for entry in faq["mainEntity"]:
        question = entry["name"]
        answer = entry["acceptedAnswer"]["text"]
        if question not in plain:
            fail(f"schema asks a question the page does not: {question!r}")
        # Prefix rather than the whole string: the page wraps and the schema
        # does not, and a link in an answer is text here and markup there.
        if answer[:60] not in plain:
            fail(f"schema answers {question!r} with wording the page does not use")

    # Matched to the closing quote. "og:image" on its own is a substring of
    # og:image:width, so deleting the real tag still looked present.
    required = [
        r'rel="canonical"',
        r'property="og:image"',
        r'property="og:url"',
        r'property="og:title"',
        r'property="og:description"',
        r'name="twitter:card"',
        r'name="description"',
    ]
    for tag in required:
        if not re.search(re.escape(tag) + r"[\s>]", page):
            fail(f"missing {tag}")

    try:
        ET.parse(HERE / "sitemap.xml")
    except ET.ParseError as e:
        fail(f"sitemap.xml is malformed: {e}")

    for name in ("robots.txt", "llms.txt", "og.png", "favicon.png"):
        if not (HERE / name).exists():
            fail(f"{name} is referenced but not in app/web/")

    print(f"SEO check passed: {len(faq['mainEntity'])} FAQ entries match the page")


if __name__ == "__main__":
    main()
