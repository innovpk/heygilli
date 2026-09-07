"""Same video, two households. Real Curator, real policies, real decisions."""
import json, os
os.environ.setdefault("HEYGILLI_STORE", "local")
os.environ.setdefault("HEYGILLI_DATA_DIR", "/tmp/hgdemo2")
from heygilli_agents.curator import decide, curator_agent
from heygilli_agents.schemas import Policy, PolicyAnswer, Video
from heygilli_agents.tools.youtube import fetch_channel_feed
from heygilli_agents.coach import question_id

Q_UNBOX = "Are unboxing and toy-haul videos all right?"
Q_MERCH = "Are videos that push merchandise or a sponsor all right?"
Q_PERIL = "Is cartoon peril — chases, monsters, mild scares — all right?"

def pol(kid, **choices):
    return Policy(kid_id=kid, answers=[
        PolicyAnswer(id=question_id(q), question=q, choice=c)
        for q, c in choices.items()
    ])

relaxed = pol("demo", **{Q_UNBOX: "fine", Q_MERCH: "fine", Q_PERIL: "fine"})
strict  = pol("demo", **{Q_UNBOX: "rather_not", Q_MERCH: "rather_not", Q_PERIL: "rather_not"})

CHANNELS = {
    "Ryan's World": "UChGJGhZ9SOOHvBB0Y4DOO_w",
    "Cocomelon":    "UCbCmjCuTUZos6Inko4u57UQ",
    "Mark Rober":   "UCY1kMZp36IQSyNx_9h4mpCg",
}
agent = curator_agent()
out = []
for name, cid in CHANNELS.items():
    feed = fetch_channel_feed(cid, 6)
    for up in feed["uploads"][:2]:
        v = Video(id=up.get("video_id",""), channel_id=cid, title=up.get("title",""),
                  description=(up.get("description") or "")[:600], duration_s=0)
        row = {"channel": name, "title": v.title, "desc": v.description[:180]}
        for label, p in (("relaxed", relaxed), ("strict", strict)):
            d = decide(v, "7_8", agent, excerpt="", policy=p)
            row[label] = {"decision": d.decision, "reason": d.reason, "policy_id": d.policy_id}
        out.append(row)
        print(f"\n=== {name}: {v.title[:70]}")
        print(f"  relaxed: {row['relaxed']['decision']:11} {row['relaxed']['reason'][:95]}")
        print(f"  strict : {row['strict']['decision']:11} {row['strict']['reason'][:95]}")
json.dump(out, open("/tmp/policy_demo.json","w"), indent=1)
