#!/usr/bin/env python3
"""Generates the Peeku mockup artboards (.dc.html) and canvas.json."""
import json, os
OUT = os.path.dirname(os.path.abspath(__file__))

FONTS = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Baloo+2:wght@600;800&amp;family=Nunito:wght@500;700;800&amp;family=Noto+Nastaliq+Urdu:wght@500&amp;display=swap">'
BASE_CSS = """
body { margin: 0; font-family: 'Nunito', 'Trebuchet MS', system-ui, sans-serif; background: #0f2a33; color: #fbf3e6; }
a { color: #f5a524; } a:hover { color: #ffbf4d; }
.display { font-family: 'Baloo 2', 'Trebuchet MS', system-ui, sans-serif; }
.ur { font-family: 'Noto Nastaliq Urdu', 'Nunito', serif; direction: rtl; }
"""

def head(extra_css=""):
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  {FONTS}
  <style>{BASE_CSS}{extra_css}</style>
</helmet>
"""

TAIL = """
</x-dc>
</body>
</html>
"""

def peeku(size=160, talking=True):
    """Peeku the palm squirrel. Simple flat shapes, big curious eyes."""
    wave = ""
    if talking:
        wave = """
  <g stroke="#f5a524" stroke-width="6" stroke-linecap="round" fill="none">
    <path d="M142 58 q6 10 0 20"></path>
    <path d="M154 50 q12 18 0 36"></path>
    <path d="M166 42 q18 26 0 52"></path>
  </g>"""
    return f"""<svg width="{size}" height="{size}" viewBox="0 0 180 180" xmlns="http://www.w3.org/2000/svg" aria-label="Peeku the squirrel">
  <path d="M40 150 C-10 130 0 60 40 60 C70 60 62 100 48 118 C40 128 44 146 40 150 Z" fill="#a8471f"></path>
  <path d="M42 140 C10 122 18 76 42 76 C58 76 54 100 46 112 C42 120 44 132 42 140 Z" fill="#c96a2b"></path>
  <ellipse cx="96" cy="126" rx="38" ry="42" fill="#d98b4a"></ellipse>
  <ellipse cx="98" cy="134" rx="22" ry="28" fill="#f6dcbf"></ellipse>
  <g stroke="#7a3a14" stroke-width="3" stroke-linecap="round">
    <path d="M78 96 q-4 20 2 40"></path><path d="M70 100 q-4 18 0 34"></path>
  </g>
  <circle cx="96" cy="70" r="34" fill="#d98b4a"></circle>
  <ellipse cx="70" cy="42" rx="10" ry="14" fill="#d98b4a"></ellipse>
  <ellipse cx="122" cy="42" rx="10" ry="14" fill="#d98b4a"></ellipse>
  <ellipse cx="70" cy="44" rx="5" ry="8" fill="#f2b7a0"></ellipse>
  <ellipse cx="122" cy="44" rx="5" ry="8" fill="#f2b7a0"></ellipse>
  <ellipse cx="96" cy="84" rx="18" ry="12" fill="#f6dcbf"></ellipse>
  <circle cx="82" cy="66" r="11" fill="#ffffff"></circle>
  <circle cx="110" cy="66" r="11" fill="#ffffff"></circle>
  <circle cx="84" cy="68" r="6" fill="#1e1a17"></circle>
  <circle cx="112" cy="68" r="6" fill="#1e1a17"></circle>
  <circle cx="86" cy="65" r="2" fill="#ffffff"></circle>
  <circle cx="114" cy="65" r="2" fill="#ffffff"></circle>
  <circle cx="96" cy="80" r="4" fill="#5a2a12"></circle>
  <circle cx="72" cy="82" r="5" fill="#f4a08a" opacity="0.8"></circle>
  <circle cx="120" cy="82" r="5" fill="#f4a08a" opacity="0.8"></circle>
  <path d="M90 88 q6 6 12 0" stroke="#5a2a12" stroke-width="3" fill="none" stroke-linecap="round"></path>
  <ellipse cx="74" cy="150" rx="10" ry="7" fill="#c96a2b"></ellipse>
  <ellipse cx="118" cy="150" rx="10" ry="7" fill="#c96a2b"></ellipse>{wave}
</svg>"""

def giraffe_scene(w, h, dim=False):
    """Placeholder for the paused video frame: flat savanna with a giraffe."""
    overlay = '<rect width="1600" height="900" fill="#0f2a33" opacity="0.45"></rect>' if dim else ""
    return f"""<svg width="{w}" height="{h}" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMid slice" xmlns="http://www.w3.org/2000/svg" aria-label="Paused video frame placeholder">
  <rect width="1600" height="900" fill="#8fd3ee"></rect>
  <circle cx="1320" cy="170" r="90" fill="#ffd66b"></circle>
  <rect y="620" width="1600" height="280" fill="#d8b258"></rect>
  <rect y="600" width="1600" height="40" fill="#b9c96a"></rect>
  <path d="M220 620 l0 -180 M220 440 q-80 -40 -60 -120 M220 440 q90 -40 60 -130" stroke="#6b4a2b" stroke-width="18" fill="none" stroke-linecap="round"></path>
  <ellipse cx="160" cy="330" rx="110" ry="50" fill="#5f9c4a"></ellipse>
  <ellipse cx="290" cy="300" rx="120" ry="55" fill="#6fae52"></ellipse>
  <g fill="#f2c25c" stroke="#b8862e" stroke-width="6">
    <ellipse cx="900" cy="520" rx="190" ry="120"></ellipse>
    <rect x="760" y="560" width="46" height="160" rx="20"></rect>
    <rect x="840" y="580" width="46" height="150" rx="20"></rect>
    <rect x="960" y="580" width="46" height="150" rx="20"></rect>
    <rect x="1030" y="560" width="46" height="160" rx="20"></rect>
    <path d="M1040 470 L1130 160 L1210 170 L1160 500 Z"></path>
    <ellipse cx="1180" cy="150" rx="70" ry="50"></ellipse>
  </g>
  <g fill="#8a5a25">
    <circle cx="840" cy="500" r="26"></circle><circle cx="930" cy="470" r="30"></circle><circle cx="990" cy="560" r="22"></circle>
    <circle cx="870" cy="590" r="18"></circle><circle cx="1110" cy="300" r="16"></circle><circle cx="1150" cy="400" r="18"></circle>
  </g>
  <circle cx="1205" cy="142" r="8" fill="#1e1a17"></circle>
  <path d="M1170 96 l-8 -34 M1200 92 l6 -36" stroke="#8a5a25" stroke-width="10" stroke-linecap="round"></path>
  {overlay}
</svg>"""

def mic_icon(size=44, color="#0f2a33"):
    return f"""<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{color}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg">
  <rect x="9" y="3" width="6" height="11" rx="3"></rect>
  <path d="M5 11a7 7 0 0 0 14 0"></path>
  <path d="M12 18v3"></path>
</svg>"""

def dpad_glyph(kind, size=48):
    """Remote hints: left arrow, centre dot, right arrow. Stroke icons."""
    c = "#fbf3e6"
    inner = {
        "left": '<path d="M15 6 L9 12 L15 18"></path>',
        "right": '<path d="M9 6 L15 12 L9 18"></path>',
        "ok": '<circle cx="12" cy="12" r="4"></circle>',
    }[kind]
    return f"""<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{c}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="10.5" stroke-width="1.6" opacity="0.6"></circle>{inner}</svg>"""

def pick_icon(kind, size=180):
    """Icon-library placeholders for pick-it: red ball, blue fish, green leaf."""
    if kind == "ball":
        body = '<circle cx="50" cy="50" r="38" fill="#e4572e"></circle><path d="M20 38 q30 -14 60 0" stroke="#fbf3e6" stroke-width="7" fill="none" stroke-linecap="round"></path><path d="M20 62 q30 14 60 0" stroke="#fbf3e6" stroke-width="7" fill="none" stroke-linecap="round"></path>'
    elif kind == "fish":
        body = '<path d="M18 50 q26 -30 52 0 q-26 30 -52 0 Z" fill="#3b8bd6"></path><path d="M68 50 l18 -16 l0 32 Z" fill="#2c6fb0"></path><circle cx="36" cy="46" r="5" fill="#1e1a17"></circle>'
    else:
        body = '<path d="M50 12 C 82 20 90 60 56 88 C 20 74 14 34 50 12 Z" fill="#5f9c4a"></path><path d="M52 20 L 52 84" stroke="#3f7a2f" stroke-width="5" stroke-linecap="round"></path>'
    return f'<svg width="{size}" height="{size}" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">{body}</svg>'

def thumb_icon(kind):
    """Flat icons for picture-only home thumbnails."""
    shapes = {
        "giraffe": '<rect width="100" height="100" fill="#f2c25c"></rect><rect x="58" y="18" width="14" height="60" rx="6" fill="#b8862e"></rect><ellipse cx="64" cy="16" rx="14" ry="10" fill="#b8862e"></ellipse><ellipse cx="42" cy="74" rx="26" ry="16" fill="#b8862e"></ellipse>',
        "truck": '<rect width="100" height="100" fill="#8fd3ee"></rect><rect x="14" y="44" width="52" height="30" rx="4" fill="#e4572e"></rect><rect x="64" y="52" width="24" height="22" rx="4" fill="#c9401c"></rect><circle cx="30" cy="78" r="8" fill="#1e1a17"></circle><circle cx="74" cy="78" r="8" fill="#1e1a17"></circle>',
        "rocket": '<rect width="100" height="100" fill="#3b3f8a"></rect><path d="M50 14 C 66 30 66 60 50 74 C 34 60 34 30 50 14 Z" fill="#fbf3e6"></path><circle cx="50" cy="44" r="7" fill="#3b8bd6"></circle><path d="M42 74 l8 14 l8 -14 Z" fill="#f5a524"></path>',
        "fish": '<rect width="100" height="100" fill="#1e6f8a"></rect><path d="M20 52 q26 -28 52 0 q-26 28 -52 0 Z" fill="#f5a524"></path><path d="M70 52 l16 -14 l0 28 Z" fill="#d98b4a"></path>',
        "counting": '<rect width="100" height="100" fill="#5f9c4a"></rect><circle cx="30" cy="36" r="10" fill="#fbf3e6"></circle><circle cx="56" cy="36" r="10" fill="#fbf3e6"></circle><circle cx="82" cy="36" r="10" fill="#fbf3e6"></circle><circle cx="43" cy="66" r="10" fill="#fbf3e6"></circle><circle cx="69" cy="66" r="10" fill="#fbf3e6"></circle>',
        "cat": '<rect width="100" height="100" fill="#f4a08a"></rect><circle cx="50" cy="58" r="26" fill="#6b4a2b"></circle><path d="M30 40 l4 -20 l14 14 Z M70 40 l-4 -20 l-14 14 Z" fill="#6b4a2b"></path><circle cx="42" cy="56" r="4" fill="#fbf3e6"></circle><circle cx="58" cy="56" r="4" fill="#fbf3e6"></circle>',
        "song": '<rect width="100" height="100" fill="#c96a2b"></rect><path d="M40 24 v44 M40 24 l28 -8 v44" stroke="#fbf3e6" stroke-width="6" fill="none" stroke-linecap="round"></path><circle cx="32" cy="70" r="9" fill="#fbf3e6"></circle><circle cx="60" cy="62" r="9" fill="#fbf3e6"></circle>',
        "paint": '<rect width="100" height="100" fill="#fbf3e6"></rect><circle cx="34" cy="40" r="10" fill="#e4572e"></circle><circle cx="62" cy="34" r="10" fill="#3b8bd6"></circle><circle cx="70" cy="62" r="10" fill="#f5a524"></circle><circle cx="40" cy="68" r="10" fill="#5f9c4a"></circle>',
    }
    return f'<svg width="100%" height="100%" viewBox="0 0 100 100" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">{shapes[kind]}</svg>'

def pause_badge():
    return """<div style="position:absolute; top:28px; left:28px; width:56px; height:56px; border-radius:16px; background:rgba(15,42,51,0.75); display:flex; align-items:center; justify-content:center;">
  <svg width="26" height="26" viewBox="0 0 24 24" fill="#fbf3e6" xmlns="http://www.w3.org/2000/svg"><rect x="6" y="4" width="4" height="16" rx="1.5"></rect><rect x="14" y="4" width="4" height="16" rx="1.5"></rect></svg>
</div>"""

def listen_ring(size=120, label=None):
    """Pulsing mic ring. Label is only rendered when given (7+)."""
    lab = f'<div class="display" style="font-size:26px; font-weight:600; color:#fbf3e6;">{label}</div>' if label else ""
    return f"""<div style="display:flex; align-items:center; gap:18px;">
  <div style="position:relative; width:{size}px; height:{size}px;">
    <div style="position:absolute; inset:0; border-radius:50%; background:#f5a524; opacity:0.28;"></div>
    <div style="position:absolute; inset:14px; border-radius:50%; background:#f5a524; opacity:0.5;"></div>
    <div style="position:absolute; inset:28px; border-radius:50%; background:#f5a524; display:flex; align-items:center; justify-content:center;">{mic_icon(int(size*0.36))}</div>
  </div>
  {lab}
</div>"""

# ---------------------------------------------------------------- TV 1280x720
TV = 'style="position:relative; width:1280px; height:720px; overflow:hidden; background:#0f2a33;"'

def tv_main():
    return head() + f"""
<div {TV}>
  <div style="position:absolute; inset:0;">{giraffe_scene(1280, 720)}</div>
  {pause_badge()}
  <div style="position:absolute; right:48px; bottom:40px; display:flex; align-items:flex-end; gap:20px;">
    {listen_ring(132)}
    <div style="width:230px; height:230px; border-radius:50%; background:#fbf3e6; display:flex; align-items:flex-end; justify-content:center; padding-bottom:6px; box-shadow:0 12px 0 rgba(15,42,51,0.35);">
      {peeku(200)}
    </div>
  </div>
</div>
""" + TAIL

def tv_home():
    thumbs = ["giraffe", "truck", "rocket", "fish", "counting", "cat", "song", "paint"]
    cards = []
    for i, k in enumerate(thumbs):
        focused = (i == 0)
        ring = "outline:8px solid #f5a524; outline-offset:6px; transform:scale(1.06);" if focused else ""
        cards.append(f'<div style="width:262px; height:148px; border-radius:22px; overflow:hidden; {ring}">{thumb_icon(k)}</div>')
    row1 = "".join(cards[:4]); row2 = "".join(cards[4:])
    return head() + f"""
<div {TV}>
  <div style="position:absolute; top:36px; left:64px; display:flex; align-items:center; gap:22px;">
    <div style="width:96px; height:96px; border-radius:50%; background:#f5a524; display:flex; align-items:center; justify-content:center;">
      <svg width="56" height="56" viewBox="0 0 24 24" fill="#0f2a33" xmlns="http://www.w3.org/2000/svg"><path d="M12 2 l2.9 6.3 6.9 .8 -5.1 4.7 1.4 6.8 -6.1 -3.5 -6.1 3.5 1.4 -6.8 -5.1 -4.7 6.9 -.8 Z"></path></svg>
    </div>
    <div style="width:96px; height:96px; border-radius:50%; background:#fbf3e6; display:flex; align-items:flex-end; justify-content:center;">{peeku(88)}</div>
  </div>
  <div style="position:absolute; top:172px; left:64px; display:flex; flex-direction:column; gap:52px;">
    <div style="display:flex; gap:40px;">{row1}</div>
    <div style="display:flex; gap:40px;">{row2}</div>
  </div>
</div>
""" + TAIL

def tv_pick():
    def card(kind, glyph, focused=False):
        ring = "outline:10px solid #f5a524; outline-offset:8px; transform:rotate(-3deg) scale(1.05);" if focused else ""
        return f"""<div style="display:flex; flex-direction:column; align-items:center; gap:22px;">
  <div style="width:250px; height:250px; border-radius:36px; background:#fbf3e6; display:flex; align-items:center; justify-content:center; box-shadow:0 14px 0 rgba(15,42,51,0.35); {ring}">{pick_icon(kind, 176)}</div>
  {dpad_glyph(glyph, 56)}
</div>"""
    return head() + f"""
<div {TV}>
  <div style="position:absolute; inset:0;">{giraffe_scene(1280, 720, dim=True)}</div>
  {pause_badge()}
  <div style="position:absolute; left:0; right:0; top:150px; display:flex; justify-content:center; gap:80px;">
    {card("ball", "left")}{card("fish", "ok", focused=True)}{card("leaf", "right")}
  </div>
  <div style="position:absolute; right:48px; bottom:32px; width:190px; height:190px; border-radius:50%; background:#fbf3e6; display:flex; align-items:flex-end; justify-content:center; padding-bottom:4px; box-shadow:0 12px 0 rgba(15,42,51,0.35);">
    {peeku(166)}
  </div>
</div>
""" + TAIL

def tv_older():
    return head() + f"""
<div {TV}>
  <div style="position:absolute; top:56px; left:56px; width:560px; height:315px; border-radius:20px; overflow:hidden; box-shadow:0 16px 0 rgba(0,0,0,0.25);">{giraffe_scene(560, 315)}</div>
  <div style="position:absolute; top:56px; left:56px; width:56px; height:56px; border-radius:16px; background:rgba(15,42,51,0.75); display:flex; align-items:center; justify-content:center; margin:16px;">
    <svg width="26" height="26" viewBox="0 0 24 24" fill="#fbf3e6" xmlns="http://www.w3.org/2000/svg"><rect x="6" y="4" width="4" height="16" rx="1.5"></rect><rect x="14" y="4" width="4" height="16" rx="1.5"></rect></svg>
  </div>
  <div style="position:absolute; top:72px; left:680px; width:540px; display:flex; flex-direction:column; gap:26px;">
    <div class="display" style="font-size:54px; font-weight:800; line-height:1.1; color:#fbf3e6; text-wrap: pretty;">Why did the lava come out?</div>
    <div class="ur" style="font-size:34px; line-height:2; color:#f5a524;">لاوا باہر کیوں نکلا؟</div>
  </div>
  <div style="position:absolute; left:680px; top:400px; width:540px;">
    {listen_ring(104, "Hold the mic button and tell me")}
  </div>
  <div style="position:absolute; left:56px; bottom:56px; width:1000px; padding:22px 30px; border-radius:22px; background:rgba(251,243,230,0.1); font-size:30px; font-weight:700; color:#fbf3e6;">
    <span style="opacity:0.6;">You said:</span> because the pressure got too big under the ground…
  </div>
  <div style="position:absolute; right:48px; bottom:40px; width:170px; height:170px; border-radius:50%; background:#fbf3e6; display:flex; align-items:flex-end; justify-content:center; padding-bottom:4px; box-shadow:0 12px 0 rgba(15,42,51,0.35);">
    {peeku(150, talking=False)}
  </div>
</div>
""" + TAIL

# ---------------------------------------------------------------- Tablet 1024x768
def tablet_pick():
    def card(kind):
        return f'<div style="width:190px; height:190px; border-radius:30px; background:#ffffff; display:flex; align-items:center; justify-content:center; box-shadow:0 10px 0 rgba(15,42,51,0.12);">{pick_icon(kind, 132)}</div>'
    return head() + f"""
<div style="position:relative; width:1024px; height:768px; overflow:hidden; background:#fbf3e6;">
  <div style="position:absolute; top:0; left:0; width:1024px; height:400px; overflow:hidden;">{giraffe_scene(1024, 400, dim=True)}</div>
  <div style="position:absolute; top:24px; left:24px; width:52px; height:52px; border-radius:14px; background:rgba(15,42,51,0.75); display:flex; align-items:center; justify-content:center;">
    <svg width="24" height="24" viewBox="0 0 24 24" fill="#fbf3e6" xmlns="http://www.w3.org/2000/svg"><rect x="6" y="4" width="4" height="16" rx="1.5"></rect><rect x="14" y="4" width="4" height="16" rx="1.5"></rect></svg>
  </div>
  <div style="position:absolute; top:400px; left:0; right:0; bottom:0; display:flex; align-items:center; padding:0 40px; gap:36px;">
    <div style="width:200px; height:200px; border-radius:50%; background:#ffffff; display:flex; align-items:flex-end; justify-content:center; padding-bottom:4px; box-shadow:0 10px 0 rgba(15,42,51,0.12);">{peeku(176)}</div>
    <div style="flex-grow:1; display:flex; justify-content:center; gap:36px;">{card("ball")}{card("fish")}{card("leaf")}</div>
    <div style="width:120px; height:120px; border-radius:50%; background:#f5a524; display:flex; align-items:center; justify-content:center; box-shadow:0 10px 0 rgba(15,42,51,0.18);">{mic_icon(56)}</div>
  </div>
</div>
""" + TAIL

# ---------------------------------------------------------------- Phone 390x844
PHONE_CSS = """
.chip { display:inline-flex; align-items:center; gap:8px; padding:10px 16px; border-radius:999px; font-weight:800; font-size:17px; }
.card { background:#ffffff; border-radius:22px; padding:20px; box-shadow:0 2px 0 rgba(15,42,51,0.08); }
.label { font-size:13px; font-weight:800; letter-spacing:0.08em; text-transform:uppercase; color:#8a6a4a; }
"""
def acorn(size=18):
    return f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg"><path d="M5 10 h14 a7 7 0 0 1 -7 11 a7 7 0 0 1 -7 -11 Z" fill="#a8471f"></path><path d="M4 10 q8 -6 16 0 v2 h-16 Z" fill="#6b4a2b"></path><path d="M12 4 v4" stroke="#6b4a2b" stroke-width="2.5" stroke-linecap="round"></path></svg>'

def tabbar():
    def tab(icon, name, active=False):
        col = "#0f2a33" if active else "#9a8f82"
        return f'<div style="display:flex; flex-direction:column; align-items:center; gap:4px; color:{col}; font-size:12px; font-weight:800;">{icon}{name}</div>'
    kids = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><circle cx="9" cy="8" r="3.5"></circle><circle cx="17" cy="9" r="2.5"></circle><path d="M3 20 c0 -4 3 -6 6 -6 s6 2 6 6"></path><path d="M15 15 c3 0 5 2 5 5"></path></svg>'
    chan = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><rect x="3" y="5" width="18" height="13" rx="2.5"></rect><path d="M10 9 l5 2.5 -5 2.5 Z"></path><path d="M8 21 h8"></path></svg>'
    sett = '<svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" xmlns="http://www.w3.org/2000/svg"><circle cx="12" cy="12" r="3"></circle><path d="M19 12a7 7 0 0 0 -.1 -1.2l2 -1.5 -2 -3.4 -2.3 .9a7 7 0 0 0 -2 -1.2L14.3 3h-4.6l-.3 2.6a7 7 0 0 0 -2 1.2l-2.3 -.9 -2 3.4 2 1.5A7 7 0 0 0 5 12c0 .4 0 .8 .1 1.2l-2 1.5 2 3.4 2.3 -.9a7 7 0 0 0 2 1.2l.3 2.6h4.6l.3 -2.6a7 7 0 0 0 2 -1.2l2.3 .9 2 -3.4 -2 -1.5c.1 -.4 .1 -.8 .1 -1.2Z"></path></svg>'
    return f'<div style="position:absolute; left:0; right:0; bottom:0; height:78px; background:#ffffff; border-top:1px solid #eadfce; display:flex; justify-content:space-around; align-items:center; padding-bottom:10px;">{tab(kids, "Kids", True)}{tab(chan, "Channels")}{tab(sett, "Settings")}</div>'

def phone_shell(inner):
    return head(PHONE_CSS) + f"""
<div style="position:relative; width:390px; height:844px; overflow:hidden; background:#fbf3e6; color:#1e1a17;">
  <div style="padding:64px 20px 0 20px; display:flex; flex-direction:column; gap:16px;">
    {inner}
  </div>
  {tabbar()}
</div>
""" + TAIL

def phone_digest_pre():
    said = "".join(f'<span class="chip" style="background:#f5a524; color:#1e1a17;">{acorn()}{w}</span>' for w in ["giraffe", "red", "three", "truck"])
    heard = "".join(f'<span class="chip" style="border:2px dashed #c9b7a0; color:#6b5a48;">{w}</span>' for w in ["hippo", "purple"])
    inner = f"""
    <div style="display:flex; align-items:center; justify-content:space-between;">
      <div>
        <div class="label">Today · Friday</div>
        <div class="display" style="font-size:34px; font-weight:800; line-height:1.1;">Zara</div>
      </div>
      <div style="width:56px; height:56px; border-radius:50%; background:#ffffff; display:flex; align-items:flex-end; justify-content:center;">{peeku(50, talking=False)}</div>
    </div>
    <div style="display:flex; gap:10px;">
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">35</div><div class="label">minutes</div></div>
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">5</div><div class="label">videos</div></div>
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">6</div><div class="label">questions</div></div>
    </div>
    <div class="card" style="display:flex; flex-direction:column; gap:12px;">
      <div class="label">Words Zara said</div>
      <div style="display:flex; flex-wrap:wrap; gap:8px;">{said}</div>
    </div>
    <div class="card" style="display:flex; flex-direction:column; gap:12px;">
      <div class="label">Heard, not said yet</div>
      <div style="display:flex; flex-wrap:wrap; gap:8px;">{heard}</div>
    </div>
    <div class="card" style="background:#0f2a33; color:#fbf3e6; display:flex; flex-direction:column; gap:8px;">
      <div class="label" style="color:#f5a524;">Try today</div>
      <div class="display" style="font-size:22px; font-weight:600; line-height:1.3; text-wrap: pretty;">Count the cars on the way to school. Stop at five.</div>
    </div>
    """
    return phone_shell(inner)

def phone_digest_older():
    inner = f"""
    <div style="display:flex; align-items:center; justify-content:space-between;">
      <div>
        <div class="label">Today · Friday</div>
        <div class="display" style="font-size:34px; font-weight:800; line-height:1.1;">Ayaan</div>
      </div>
      <div style="width:56px; height:56px; border-radius:50%; background:#ffffff; display:flex; align-items:flex-end; justify-content:center;">{peeku(50, talking=False)}</div>
    </div>
    <div style="display:flex; gap:10px;">
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">42</div><div class="label">minutes</div></div>
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">4</div><div class="label">videos</div></div>
      <div class="card" style="flex-grow:1; padding:14px 16px;"><div class="display" style="font-size:26px; font-weight:800;">6<span style="font-size:16px; color:#8a6a4a;">/9</span></div><div class="label">answered</div></div>
    </div>
    <div class="card" style="display:flex; flex-direction:column; gap:8px;">
      <div class="label" style="color:#3f7a2f;">Understood</div>
      <div style="font-size:18px; font-weight:700; line-height:1.35;">Volcanoes erupt when pressure builds up underground.</div>
    </div>
    <div class="card" style="display:flex; flex-direction:column; gap:8px;">
      <div class="label" style="color:#c9401c;">Shaky</div>
      <div style="font-size:18px; font-weight:700; line-height:1.35;">Why the moon changes shape.</div>
    </div>
    <div class="card" style="background:#0f2a33; color:#fbf3e6; display:flex; flex-direction:column; gap:8px;">
      <div class="label" style="color:#f5a524;">Ask at dinner</div>
      <div class="display" style="font-size:22px; font-weight:600; line-height:1.3; text-wrap: pretty;">“What would happen if you shook a fizzy drink and opened it?”</div>
    </div>
    """
    return phone_shell(inner)

# ---------------------------------------------------------------- Direction B (low-fi alternate)
def direction_b():
    return head("""
.sk { border:2px solid #6b5a48; border-radius:12px; background:#fffdf8; }
""") + f"""
<div style="position:relative; width:640px; height:360px; overflow:hidden; background:#f4ead9; color:#6b5a48; font-family:'Nunito', system-ui, sans-serif;">
  <div class="sk" style="position:absolute; inset:16px; border-style:dashed;"></div>
  <div class="sk" style="position:absolute; left:40px; top:40px; width:300px; height:170px; display:flex; align-items:center; justify-content:center; font-weight:800;">paused frame</div>
  <div style="position:absolute; left:370px; top:50px; width:230px; font-size:22px; font-weight:800; line-height:1.2;">light paper palette, question card on the right</div>
  <div class="sk" style="position:absolute; left:370px; top:140px; width:230px; height:70px; display:flex; align-items:center; justify-content:center; font-weight:800;">mic + Peeku</div>
  <div class="sk" style="position:absolute; left:40px; top:240px; width:170px; height:80px; display:flex; align-items:center; justify-content:center;">pick</div>
  <div class="sk" style="position:absolute; left:235px; top:240px; width:170px; height:80px; display:flex; align-items:center; justify-content:center;">pick</div>
  <div class="sk" style="position:absolute; left:430px; top:240px; width:170px; height:80px; display:flex; align-items:center; justify-content:center;">pick</div>
</div>
""" + TAIL

files = {
    "TVHomePreReader.dc.html": tv_home(),
    "Main.dc.html": tv_main(),
    "TVPickIt.dc.html": tv_pick(),
    "TVOlder.dc.html": tv_older(),
    "TabletPickIt.dc.html": tablet_pick(),
    "PhoneDigestPreReader.dc.html": phone_digest_pre(),
    "PhoneDigestOlder.dc.html": phone_digest_older(),
    "DirectionB.dc.html": direction_b(),
}
for name, src in files.items():
    with open(os.path.join(OUT, name), "w") as f:
        f.write(src)

canvas = {
    "artboards": [
        {"file": "TVHomePreReader.dc.html", "title": "TV · Home (4–6, pictures only)", "x": 0, "y": 0, "w": 1280, "h": 720},
        {"file": "Main.dc.html", "title": "TV · Name it (4–6)", "x": 1380, "y": 0, "w": 1280, "h": 720},
        {"file": "TVPickIt.dc.html", "title": "TV · Pick it (4–6)", "x": 2760, "y": 0, "w": 1280, "h": 720},
        {"file": "TVOlder.dc.html", "title": "TV · Question (9–11)", "x": 4140, "y": 0, "w": 1280, "h": 720},
        {"file": "TabletPickIt.dc.html", "title": "Tablet · Pick it (4–6)", "x": 0, "y": 900, "w": 1024, "h": 768},
        {"file": "PhoneDigestPreReader.dc.html", "title": "Phone · Digest (4–6)", "x": 1124, "y": 900, "w": 390, "h": 844},
        {"file": "PhoneDigestOlder.dc.html", "title": "Phone · Digest (9–11)", "x": 1614, "y": 900, "w": 390, "h": 844},
        {"file": "DirectionB.dc.html", "title": "Alternate direction · Daylight paper (low-fi)", "x": 2104, "y": 900, "w": 640, "h": 360},
    ],
    "annotations": [
        {"id": "note-home", "x": 0, "y": -170, "w": 420, "text": "4–6 home: thumbnails only, no labels. Peeku reads the title aloud when a thumbnail is focused. Focused card = mango ring."},
        {"id": "note-name", "x": 1380, "y": -170, "w": 460, "text": "Peeku (voice only): \"What animal is that?\"\nNo text on screen for this band. Mic ring pulses for 5 s. Whatever the kid says, Peeku models the word: \"A giraffe! Gi-raffe.\""},
        {"id": "note-pick", "x": 2760, "y": -170, "w": 460, "text": "Peeku (voice): \"Show me the blue one.\"\nLeft / centre / right on the remote map to the three cards. One press answers. Focused card wobbles."},
        {"id": "note-older", "x": 4140, "y": -170, "w": 460, "text": "9–11: question shown as text plus Urdu line, video shrinks to a corner, live transcript of the answer. Peeku is calmer here, no baby talk."},
        {"id": "note-row2", "x": 0, "y": 1740, "w": 520, "text": "Same loop on tablet (tap or big mic button). Parent digest has two shapes: words said for pre-readers, understood / shaky / dinner question for older kids."},
        {"id": "note-dirb", "x": 2104, "y": 1300, "w": 420, "text": "Alternate: a light paper palette instead of deep teal. Tradeoff: friendlier on tablets in daylight, but a bright TV in a dim living room is harsh on a 4-year-old's eyes."},
    ],
    "launch": {"view": "canvas"},
}
with open(os.path.join(OUT, "canvas.json"), "w") as f:
    json.dump(canvas, f, indent=2, ensure_ascii=False)
print("wrote", len(files), "artboards + canvas.json")
