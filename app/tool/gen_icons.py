#!/usr/bin/env python3
"""Writes one flat SVG per entry in shared/icons.json into app/assets/icons/.

Why a generator: the pick-it library must look like one family (same stroke,
same palette, same rounded shapes) so a 4-year-old compares *concepts*, not
art styles. Hand-drawing 56 files drifts; a script does not. No text inside
any SVG: numbers are dots, colours are blobs, so pre-readers never see glyphs.

Run from the repo root:  python3 app/tool/gen_icons.py
"""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ICONS = os.path.join(ROOT, "shared", "icons.json")
OUT = os.path.join(ROOT, "app", "assets", "icons")

# Palette shared with design/generate.py and lib/core/theme.dart.
INK = "#1e1a17"
CREAM = "#fbf3e6"
MANGO = "#f5a524"
CORAL = "#e4572e"
SKY = "#8fd3ee"
BLUE = "#3b8bd6"
BLUE_D = "#2c6fb0"
GREEN = "#5f9c4a"
GREEN_D = "#3f7a2f"
YELLOW = "#ffd66b"
PURPLE = "#8e5bd1"
BROWN = "#a8471f"
BROWN_L = "#d98b4a"
TAN = "#f2c25c"
TAN_D = "#b8862e"
GREY = "#9a8f82"
PINK = "#f4a08a"
WHITE = "#ffffff"


def eye(cx, cy, r=4):
    return f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{INK}"/>'


def face(fill, mouth):
    """Round face used by the four feeling icons; only the mouth differs."""
    return (
        f'<circle cx="50" cy="50" r="38" fill="{fill}"/>'
        + eye(37, 42, 5) + eye(63, 42, 5) + mouth
    )


def dots(n):
    """Counting icons: n mango dots on a cream tile. No numerals."""
    layouts = {
        1: [(50, 50)],
        2: [(35, 50), (65, 50)],
        3: [(30, 50), (50, 50), (70, 50)],
        4: [(35, 35), (65, 35), (35, 65), (65, 65)],
        5: [(32, 32), (68, 32), (50, 50), (32, 68), (68, 68)],
    }
    body = f'<rect x="8" y="8" width="84" height="84" rx="18" fill="{CREAM}" stroke="{TAN_D}" stroke-width="3"/>'
    for x, y in layouts[n]:
        body += f'<circle cx="{x}" cy="{y}" r="9" fill="{MANGO}" stroke="{BROWN}" stroke-width="2.5"/>'
    return body


def blob(colour):
    """Colour icons: a soft paint splat, so the concept is the colour alone."""
    return (
        f'<path d="M50 12 C70 8 90 24 88 46 C94 64 78 90 54 88 C30 92 8 76 12 52 C10 30 30 14 50 12 Z" fill="{colour}"/>'
        f'<ellipse cx="38" cy="34" rx="10" ry="6" fill="{WHITE}" opacity="0.45" transform="rotate(-25 38 34)"/>'
    )


SHAPES = {
    # Yes and no. Not a concept like the others but an answer, so they are the
    # two marks a child meets before they can read a word: a tick and a cross,
    # on the green and coral already used for "went well" and "did not".
    "yes": (
        f'<circle cx="50" cy="50" r="38" fill="{GREEN_D}"/>'
        f'<path d="M32 52 L45 65 L70 37" fill="none" stroke="{CREAM}" '
        f'stroke-width="11" stroke-linecap="round" stroke-linejoin="round"/>'
    ),
    "no": (
        f'<circle cx="50" cy="50" r="38" fill="{CORAL}"/>'
        f'<path d="M36 36 L64 64 M64 36 L36 64" fill="none" stroke="{CREAM}" '
        f'stroke-width="11" stroke-linecap="round"/>'
    ),
    # animals
    "giraffe": (
        f'<rect x="58" y="22" width="14" height="52" rx="7" fill="{TAN}"/>'
        f'<ellipse cx="64" cy="18" rx="14" ry="10" fill="{TAN}"/>'
        f'<ellipse cx="42" cy="72" rx="26" ry="16" fill="{TAN}"/>'
        f'<rect x="24" y="76" width="8" height="16" rx="4" fill="{TAN}"/><rect x="50" y="76" width="8" height="16" rx="4" fill="{TAN}"/>'
        f'<g fill="{TAN_D}"><circle cx="36" cy="66" r="5"/><circle cx="50" cy="74" r="4"/><circle cx="64" cy="40" r="3.5"/><circle cx="66" cy="58" r="3"/></g>'
        f'<path d="M58 10 l-3 -7 M70 10 l3 -7" stroke="{TAN_D}" stroke-width="3" stroke-linecap="round"/>'
        + eye(70, 17, 2.5)
    ),
    "lion": (
        f'<circle cx="50" cy="52" r="40" fill="{BROWN}"/>'
        f'<circle cx="50" cy="52" r="27" fill="{TAN}"/>'
        f'<ellipse cx="50" cy="62" rx="11" ry="8" fill="{CREAM}"/>'
        f'<circle cx="50" cy="58" r="4" fill="{INK}"/>'
        + eye(40, 46) + eye(60, 46)
        + f'<path d="M44 66 q6 5 12 0" stroke="{INK}" stroke-width="2.5" fill="none" stroke-linecap="round"/>'
    ),
    "elephant": (
        f'<ellipse cx="44" cy="50" rx="34" ry="30" fill="{GREY}"/>'
        f'<circle cx="26" cy="46" r="18" fill="#b5aa9c"/>'
        f'<path d="M66 56 q22 4 20 30 q-6 4 -12 0 q2 -14 -10 -18 Z" fill="{GREY}"/>'
        f'<rect x="30" y="72" width="10" height="18" rx="5" fill="{GREY}"/><rect x="50" y="72" width="10" height="18" rx="5" fill="{GREY}"/>'
        + eye(58, 44)
    ),
    "monkey": (
        f'<circle cx="22" cy="46" r="11" fill="{BROWN}"/><circle cx="78" cy="46" r="11" fill="{BROWN}"/>'
        f'<circle cx="50" cy="50" r="32" fill="{BROWN}"/>'
        f'<path d="M26 56 a24 22 0 0 0 48 0 a18 14 0 0 0 -48 0 Z" fill="{PINK}"/>'
        f'<ellipse cx="50" cy="40" rx="18" ry="12" fill="{PINK}"/>'
        + eye(42, 40) + eye(58, 40)
        + f'<path d="M42 62 q8 8 16 0" stroke="{INK}" stroke-width="2.5" fill="none" stroke-linecap="round"/>'
    ),
    "fish": (
        f'<path d="M14 50 q28 -32 56 0 q-28 32 -56 0 Z" fill="{BLUE}"/>'
        f'<path d="M68 50 l20 -18 v36 Z" fill="{BLUE_D}"/>'
        f'<path d="M40 30 q6 8 0 16" stroke="{BLUE_D}" stroke-width="3" fill="none" stroke-linecap="round"/>'
        + eye(32, 46, 4.5)
    ),
    "bird": (
        f'<ellipse cx="50" cy="56" rx="28" ry="22" fill="{SKY}"/>'
        f'<circle cx="68" cy="40" r="15" fill="{SKY}"/>'
        f'<path d="M80 40 l14 4 -14 4 Z" fill="{MANGO}"/>'
        f'<path d="M34 52 q-16 -6 -20 10 q14 2 20 -10 Z" fill="{BLUE}"/>'
        f'<path d="M40 78 l-4 10 M52 78 l0 10" stroke="{MANGO}" stroke-width="3.5" stroke-linecap="round"/>'
        + eye(70, 38)
    ),
    "cat": (
        f'<path d="M22 44 l4 -26 l18 16 Z M78 44 l-4 -26 l-18 16 Z" fill="{GREY}"/>'
        f'<circle cx="50" cy="56" r="32" fill="{GREY}"/>'
        + eye(40, 52, 4.5) + eye(60, 52, 4.5)
        + f'<path d="M50 62 l-4 4 h8 Z" fill="{PINK}"/>'
        f'<path d="M22 60 h16 M22 68 h16 M62 60 h16 M62 68 h16" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>'
    ),
    "dog": (
        f'<ellipse cx="24" cy="50" rx="10" ry="20" fill="{BROWN}"/><ellipse cx="76" cy="50" rx="10" ry="20" fill="{BROWN}"/>'
        f'<circle cx="50" cy="52" r="30" fill="{BROWN_L}"/>'
        f'<ellipse cx="50" cy="66" rx="14" ry="10" fill="{CREAM}"/>'
        f'<ellipse cx="50" cy="62" rx="6" ry="4.5" fill="{INK}"/>'
        + eye(40, 46) + eye(60, 46)
        + f'<path d="M50 66 v6 M44 72 q6 5 12 0" stroke="{INK}" stroke-width="2.5" fill="none" stroke-linecap="round"/>'
    ),
    "cow": (
        f'<rect x="14" y="30" width="72" height="50" rx="24" fill="{WHITE}" stroke="{INK}" stroke-width="3"/>'
        f'<path d="M22 30 q-10 -14 -2 -18 q6 6 12 12 Z M78 30 q10 -14 2 -18 q-6 6 -12 12 Z" fill="{TAN_D}"/>'
        f'<ellipse cx="50" cy="66" rx="18" ry="11" fill="{PINK}"/>'
        f'<circle cx="43" cy="66" r="3" fill="{INK}"/><circle cx="57" cy="66" r="3" fill="{INK}"/>'
        f'<path d="M24 44 q8 -10 18 0 q-6 12 -18 0 Z" fill="{INK}"/>'
        + eye(62, 48) + eye(40, 46, 3)
    ),
    "duck": (
        f'<ellipse cx="46" cy="64" rx="32" ry="20" fill="{YELLOW}"/>'
        f'<circle cx="66" cy="38" r="16" fill="{YELLOW}"/>'
        f'<path d="M80 38 l16 6 -16 6 Z" fill="{MANGO}"/>'
        f'<path d="M20 60 q-14 -6 -12 8 q8 4 12 -8 Z" fill="{MANGO}"/>'
        + eye(70, 34)
    ),
    "frog": (
        f'<circle cx="32" cy="34" r="12" fill="{GREEN}"/><circle cx="68" cy="34" r="12" fill="{GREEN}"/>'
        f'<ellipse cx="50" cy="58" rx="36" ry="26" fill="{GREEN}"/>'
        f'<circle cx="32" cy="34" r="7" fill="{WHITE}"/><circle cx="68" cy="34" r="7" fill="{WHITE}"/>'
        + eye(33, 35) + eye(67, 35)
        + f'<path d="M30 62 q20 16 40 0" stroke="{GREEN_D}" stroke-width="3.5" fill="none" stroke-linecap="round"/>'
    ),
    "butterfly": (
        f'<path d="M50 50 C30 10 6 24 14 46 C6 70 30 84 50 50 Z" fill="{PURPLE}"/>'
        f'<path d="M50 50 C70 10 94 24 86 46 C94 70 70 84 50 50 Z" fill="{PURPLE}"/>'
        f'<circle cx="30" cy="40" r="6" fill="{YELLOW}"/><circle cx="70" cy="40" r="6" fill="{YELLOW}"/>'
        f'<rect x="47" y="30" width="6" height="44" rx="3" fill="{INK}"/>'
        f'<path d="M48 30 q-6 -10 -12 -12 M52 30 q6 -10 12 -12" stroke="{INK}" stroke-width="2.5" fill="none" stroke-linecap="round"/>'
    ),
    "squirrel": (
        f'<path d="M26 78 C-2 66 4 26 26 26 C42 26 38 50 30 60 C26 66 28 74 26 78 Z" fill="{BROWN}"/>'
        f'<ellipse cx="58" cy="66" rx="22" ry="20" fill="{BROWN_L}"/>'
        f'<circle cx="60" cy="40" r="18" fill="{BROWN_L}"/>'
        f'<ellipse cx="48" cy="26" rx="5" ry="8" fill="{BROWN_L}"/><ellipse cx="72" cy="26" rx="5" ry="8" fill="{BROWN_L}"/>'
        f'<ellipse cx="60" cy="72" rx="12" ry="12" fill="{CREAM}"/>'
        + eye(54, 38) + eye(68, 38)
        + f'<circle cx="62" cy="46" r="2.5" fill="{INK}"/>'
    ),
    # colours
    "red": blob(CORAL),
    "blue": blob(BLUE),
    "green": blob(GREEN),
    "yellow": blob(YELLOW),
    "orange": blob(MANGO),
    "purple": blob(PURPLE),
    # counting
    "one": dots(1),
    "two": dots(2),
    "three": dots(3),
    "four": dots(4),
    "five": dots(5),
    # vehicles
    "car": (
        f'<path d="M14 62 l10 -20 h42 l16 20 Z" fill="{CORAL}"/>'
        f'<rect x="8" y="58" width="84" height="18" rx="8" fill="{CORAL}"/>'
        f'<path d="M30 46 h12 v14 h-18 Z M48 46 h14 l10 14 h-24 Z" fill="{SKY}"/>'
        f'<circle cx="30" cy="78" r="9" fill="{INK}"/><circle cx="70" cy="78" r="9" fill="{INK}"/>'
        f'<circle cx="30" cy="78" r="4" fill="{GREY}"/><circle cx="70" cy="78" r="4" fill="{GREY}"/>'
    ),
    "truck": (
        f'<rect x="8" y="34" width="52" height="36" rx="4" fill="{MANGO}"/>'
        f'<rect x="60" y="44" width="30" height="26" rx="4" fill="{CORAL}"/>'
        f'<rect x="66" y="48" width="14" height="10" rx="2" fill="{SKY}"/>'
        f'<circle cx="26" cy="76" r="9" fill="{INK}"/><circle cx="72" cy="76" r="9" fill="{INK}"/>'
        f'<circle cx="26" cy="76" r="4" fill="{GREY}"/><circle cx="72" cy="76" r="4" fill="{GREY}"/>'
    ),
    "bus": (
        f'<rect x="10" y="24" width="80" height="50" rx="10" fill="{YELLOW}"/>'
        f'<g fill="{SKY}"><rect x="18" y="32" width="16" height="16" rx="3"/><rect x="42" y="32" width="16" height="16" rx="3"/><rect x="66" y="32" width="16" height="16" rx="3"/></g>'
        f'<rect x="10" y="56" width="80" height="6" fill="{INK}" opacity="0.15"/>'
        f'<circle cx="28" cy="78" r="9" fill="{INK}"/><circle cx="72" cy="78" r="9" fill="{INK}"/>'
    ),
    "train": (
        f'<rect x="8" y="40" width="56" height="34" rx="6" fill="{BLUE}"/>'
        f'<rect x="64" y="50" width="28" height="24" rx="4" fill="{BLUE_D}"/>'
        f'<rect x="14" y="24" width="18" height="18" rx="3" fill="{BLUE_D}"/>'
        f'<rect x="40" y="48" width="14" height="12" rx="2" fill="{SKY}"/>'
        f'<path d="M22 24 q4 -12 10 -16 q-2 8 0 16 Z" fill="{GREY}"/>'
        f'<g fill="{INK}"><circle cx="22" cy="80" r="7"/><circle cx="44" cy="80" r="7"/><circle cx="78" cy="80" r="7"/></g>'
    ),
    "plane": (
        f'<path d="M10 52 h60 q14 0 16 -6 q-4 -8 -18 -8 h-58 Z" fill="{WHITE}" stroke="{GREY}" stroke-width="3"/>'
        f'<path d="M34 38 l10 -22 h10 l-6 22 Z" fill="{CORAL}"/>'
        f'<path d="M36 52 l-6 18 h10 l10 -18 Z" fill="{CORAL}"/>'
        f'<path d="M12 38 l-4 -12 h8 l6 12 Z" fill="{CORAL}"/>'
        f'<g fill="{SKY}"><circle cx="30" cy="45" r="3"/><circle cx="42" cy="45" r="3"/><circle cx="54" cy="45" r="3"/></g>'
    ),
    "rocket": (
        f'<path d="M50 8 C68 26 68 60 50 76 C32 60 32 26 50 8 Z" fill="{CREAM}" stroke="{GREY}" stroke-width="3"/>'
        f'<circle cx="50" cy="40" r="8" fill="{SKY}"/>'
        f'<path d="M36 56 l-12 16 h12 Z M64 56 l12 16 h-12 Z" fill="{CORAL}"/>'
        f'<path d="M42 76 l8 16 l8 -16 Z" fill="{MANGO}"/>'
    ),
    "boat": (
        f'<path d="M10 62 h80 l-12 20 h-56 Z" fill="{CORAL}"/>'
        f'<rect x="48" y="18" width="4" height="44" fill="{INK}"/>'
        f'<path d="M52 20 l28 36 h-28 Z" fill="{WHITE}" stroke="{GREY}" stroke-width="2"/>'
        f'<path d="M6 86 q10 -6 20 0 t20 0 t20 0 t20 0 t10 0" stroke="{BLUE}" stroke-width="4" fill="none" stroke-linecap="round"/>'
    ),
    "ball": (
        f'<circle cx="50" cy="50" r="38" fill="{CORAL}"/>'
        f'<path d="M20 38 q30 -14 60 0" stroke="{CREAM}" stroke-width="7" fill="none" stroke-linecap="round"/>'
        f'<path d="M20 62 q30 14 60 0" stroke="{CREAM}" stroke-width="7" fill="none" stroke-linecap="round"/>'
    ),
    # food
    "apple": (
        f'<path d="M50 30 C70 18 92 36 84 62 C78 84 60 92 50 84 C40 92 22 84 16 62 C8 36 30 18 50 30 Z" fill="{CORAL}"/>'
        f'<rect x="47" y="12" width="6" height="18" rx="3" fill="{BROWN}"/>'
        f'<path d="M53 22 q12 -12 22 -4 q-10 10 -22 4 Z" fill="{GREEN}"/>'
    ),
    "banana": (
        f'<path d="M18 30 C22 70 60 90 86 68 C82 62 76 62 70 66 C50 74 30 60 26 28 Z" fill="{YELLOW}" stroke="{TAN_D}" stroke-width="3" stroke-linejoin="round"/>'
        f'<path d="M18 30 l6 -6 l6 4" fill="none" stroke="{BROWN}" stroke-width="4" stroke-linecap="round"/>'
    ),
    "mango": (
        f'<path d="M30 26 C56 10 92 34 80 66 C72 88 40 92 26 72 C14 56 18 34 30 26 Z" fill="{MANGO}"/>'
        f'<path d="M30 26 C38 40 40 56 30 72" stroke="{CORAL}" stroke-width="5" fill="none" stroke-linecap="round" opacity="0.6"/>'
        f'<path d="M30 26 q-4 -12 8 -14" stroke="{GREEN_D}" stroke-width="4" fill="none" stroke-linecap="round"/>'
    ),
    "milk": (
        f'<path d="M32 30 h36 v54 a6 6 0 0 1 -6 6 h-24 a6 6 0 0 1 -6 -6 Z" fill="{WHITE}" stroke="{GREY}" stroke-width="3"/>'
        f'<path d="M32 30 l6 -14 h24 l6 14 Z" fill="{SKY}" stroke="{GREY}" stroke-width="3" stroke-linejoin="round"/>'
        f'<rect x="32" y="52" width="36" height="14" fill="{SKY}"/>'
    ),
    "water": (
        f'<path d="M50 10 C64 34 80 48 80 64 A30 30 0 0 1 20 64 C20 48 36 34 50 10 Z" fill="{BLUE}"/>'
        f'<path d="M34 64 q0 12 12 16" stroke="{WHITE}" stroke-width="4" fill="none" stroke-linecap="round" opacity="0.7"/>'
    ),
    # nature
    "sun": (
        f'<circle cx="50" cy="50" r="22" fill="{YELLOW}" stroke="{MANGO}" stroke-width="4"/>'
        f'<g stroke="{MANGO}" stroke-width="6" stroke-linecap="round">'
        f'<path d="M50 8 v12 M50 80 v12 M8 50 h12 M80 50 h12 M20 20 l8 8 M72 72 l8 8 M20 80 l8 -8 M72 28 l8 -8"/></g>'
    ),
    "moon": (
        f'<path d="M62 12 A40 40 0 1 0 88 62 A30 30 0 0 1 62 12 Z" fill="{YELLOW}" stroke="{MANGO}" stroke-width="3"/>'
        f'<circle cx="44" cy="40" r="4" fill="{MANGO}" opacity="0.5"/><circle cx="54" cy="70" r="6" fill="{MANGO}" opacity="0.5"/>'
    ),
    "star": (
        f'<path d="M50 8 l12.5 27 29.5 3.4 -22 20 6 29 -26 -15 -26 15 6 -29 -22 -20 29.5 -3.4 Z" fill="{YELLOW}" stroke="{MANGO}" stroke-width="3" stroke-linejoin="round"/>'
    ),
    "rain": (
        f'<path d="M26 56 a16 16 0 0 1 2 -32 a20 20 0 0 1 38 -4 a14 14 0 0 1 10 36 Z" fill="{GREY}"/>'
        f'<g stroke="{BLUE}" stroke-width="5" stroke-linecap="round"><path d="M30 68 l-4 12 M48 68 l-4 12 M66 68 l-4 12 M40 82 l-3 8 M58 82 l-3 8"/></g>'
    ),
    "tree": (
        f'<rect x="44" y="60" width="12" height="30" rx="4" fill="{BROWN}"/>'
        f'<circle cx="50" cy="42" r="26" fill="{GREEN}"/>'
        f'<circle cx="32" cy="52" r="16" fill="{GREEN_D}"/><circle cx="68" cy="52" r="16" fill="{GREEN_D}"/>'
    ),
    "flower": (
        f'<rect x="47" y="56" width="6" height="34" rx="3" fill="{GREEN_D}"/>'
        f'<path d="M50 78 q-16 -4 -18 -16 q14 2 18 16 Z" fill="{GREEN}"/>'
        f'<g fill="{PINK}"><circle cx="50" cy="22" r="12"/><circle cx="32" cy="34" r="12"/><circle cx="68" cy="34" r="12"/><circle cx="38" cy="54" r="12"/><circle cx="62" cy="54" r="12"/></g>'
        f'<circle cx="50" cy="40" r="11" fill="{YELLOW}"/>'
    ),
    "leaf": (
        f'<path d="M50 12 C82 20 90 60 56 88 C20 74 14 34 50 12 Z" fill="{GREEN}"/>'
        f'<path d="M52 20 L52 84" stroke="{GREEN_D}" stroke-width="5" stroke-linecap="round"/>'
        f'<path d="M52 40 l14 -8 M52 56 l14 -8 M52 40 l-14 -8 M52 56 l-14 -8" stroke="{GREEN_D}" stroke-width="3" stroke-linecap="round"/>'
    ),
    "house": (
        f'<path d="M12 50 L50 16 L88 50 Z" fill="{CORAL}"/>'
        f'<rect x="20" y="50" width="60" height="38" fill="{CREAM}" stroke="{TAN_D}" stroke-width="3"/>'
        f'<rect x="42" y="62" width="16" height="26" rx="3" fill="{BROWN}"/>'
        f'<rect x="26" y="58" width="10" height="10" fill="{SKY}"/><rect x="64" y="58" width="10" height="10" fill="{SKY}"/>'
    ),
    "volcano": (
        f'<path d="M6 88 L36 30 h28 L94 88 Z" fill="{BROWN}"/>'
        f'<path d="M36 30 h28 l-4 -6 q-10 -4 -20 0 Z" fill="{CORAL}"/>'
        f'<path d="M48 30 v30 q-6 10 0 18 M56 30 v22 q6 8 0 16" stroke="{MANGO}" stroke-width="5" fill="none" stroke-linecap="round"/>'
        f'<g fill="{MANGO}"><circle cx="30" cy="16" r="4"/><circle cx="72" cy="12" r="5"/><circle cx="50" cy="8" r="3"/></g>'
        f'<circle cx="52" cy="24" r="10" fill="{CORAL}"/>'
    ),
    "mountain": (
        f'<path d="M4 86 L36 26 L52 54 L64 38 L96 86 Z" fill="{GREY}"/>'
        f'<path d="M36 26 l8 16 l-6 4 l-4 -4 l-6 6 l-4 -4 Z" fill="{WHITE}"/>'
        f'<path d="M64 38 l6 12 l-4 2 l-4 -4 l-4 4 Z" fill="{WHITE}"/>'
    ),
    # feelings
    "happy": face(YELLOW, f'<path d="M32 58 q18 20 36 0" stroke="{INK}" stroke-width="4" fill="none" stroke-linecap="round"/>'),
    "sad": face(SKY, f'<path d="M34 68 q16 -14 32 0" stroke="{INK}" stroke-width="4" fill="none" stroke-linecap="round"/><path d="M30 52 q0 8 4 10" stroke="{BLUE}" stroke-width="4" fill="none" stroke-linecap="round"/>'),
    "angry": face(CORAL, f'<path d="M34 66 h32" stroke="{INK}" stroke-width="4" stroke-linecap="round"/><path d="M28 30 l14 6 M72 30 l-14 6" stroke="{INK}" stroke-width="4" stroke-linecap="round"/>'),
    "sleepy": (
        f'<circle cx="50" cy="52" r="38" fill="{PURPLE}"/>'
        f'<path d="M30 46 q7 5 14 0 M56 46 q7 5 14 0" stroke="{INK}" stroke-width="4" fill="none" stroke-linecap="round"/>'
        f'<ellipse cx="50" cy="66" rx="6" ry="8" fill="{INK}"/>'
        f'<g fill="none" stroke="{CREAM}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M70 14 h10 l-10 10 h10"/><path d="M84 30 h6 l-6 6 h6"/></g>'
    ),
    # size
    "big": f'<circle cx="50" cy="52" r="40" fill="{MANGO}"/><circle cx="50" cy="52" r="30" fill="{YELLOW}" opacity="0.5"/>',
    "small": f'<circle cx="50" cy="52" r="12" fill="{MANGO}"/>',
    # shapes
    "circle": f'<circle cx="50" cy="50" r="36" fill="{BLUE}"/>',
    "square": f'<rect x="16" y="16" width="68" height="68" rx="8" fill="{GREEN}"/>',
    "triangle": f'<path d="M50 14 L88 82 H12 Z" fill="{CORAL}" stroke-linejoin="round"/>',
}


def main():
    with open(ICONS) as f:
        icons = json.load(f)
    os.makedirs(OUT, exist_ok=True)
    missing = [i["file"] for i in icons if i["file"] not in SHAPES]
    if missing:
        raise SystemExit(f"no shape for: {missing}")
    for icon in icons:
        body = SHAPES[icon["file"]]
        svg = f'<svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">{body}</svg>\n'
        with open(os.path.join(OUT, icon["file"] + ".svg"), "w") as f:
            f.write(svg)
    print("wrote", len(icons), "icons to", OUT)


if __name__ == "__main__":
    main()
