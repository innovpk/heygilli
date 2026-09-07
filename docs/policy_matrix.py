"""Every combination of three real policy questions, screened by the real Curator."""
import itertools, json, os
os.environ.setdefault("HEYGILLI_STORE", "local")
os.environ.setdefault("HEYGILLI_DATA_DIR", "/tmp/hgmatrix")
from heygilli_agents.curator import decide, curator_agent
from heygilli_agents.schemas import Policy, PolicyAnswer, Video
from heygilli_agents.tools.youtube import fetch_channel_feed
from heygilli_agents.coach import question_id

QS = [
    ("unboxing", "Are unboxing and toy-haul videos all right?"),
    ("merch",    "Are videos that push merchandise or a sponsor all right?"),
    ("peril",    "Is cartoon peril — chases, monsters, mild scares — all right?"),
]
WANT = {
    "UChGJGhZ9SOOHvBB0Y4DOO_w": ["SMUSHY", "Squishies", "GIANT"],      # Ryan's World
    "UCY1kMZp36IQSyNx_9h4mpCg": ["Roller Coasters", "Slime", "Stolen"], # Mark Rober
    "UCbCmjCuTUZos6Inko4u57UQ": ["Bed", "Emotions", "Read"],            # Cocomelon
}
NAMES = {"UChGJGhZ9SOOHvBB0Y4DOO_w": "Ryan's World",
         "UCY1kMZp36IQSyNx_9h4mpCg": "Mark Rober",
         "UCbCmjCuTUZos6Inko4u57UQ": "Cocomelon"}

videos = []
for cid, frags in WANT.items():
    feed = fetch_channel_feed(cid, 12)
    for up in feed["uploads"]:
        if any(f.lower() in (up.get("title") or "").lower() for f in frags):
            videos.append((NAMES[cid], Video(id=up.get("video_id",""), channel_id=cid,
                title=up.get("title",""), description=(up.get("description") or "")[:600])))
            break
print("videos:", [v[1].title[:50] for v in videos])

agent = curator_agent()
out = {"questions": [{"key": k, "text": t} for k, t in QS],
       "videos": [{"channel": c, "title": v.title} for c, v in videos], "cells": {}}

for combo in itertools.product(["fine", "rather_not"], repeat=len(QS)):
    key = "".join("1" if c == "fine" else "0" for c in combo)
    pol = Policy(kid_id="demo", answers=[
        PolicyAnswer(id=question_id(t), question=t, choice=c)
        for (_, t), c in zip(QS, combo)])
    row = []
    for chan, v in videos:
        d = decide(v, "7_8", agent, excerpt="", policy=pol)
        row.append({"decision": d.decision, "reason": d.reason})
    out["cells"][key] = row
    print(key, [r["decision"] for r in row])

json.dump(out, open("/tmp/matrix.json", "w"), ensure_ascii=False, indent=1)
print("done")
