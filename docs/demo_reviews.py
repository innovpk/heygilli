"""Run the real Reviewer on real channels and dump genuine output for the site."""
import json, os, sys
os.environ.setdefault("HEYGILLI_STORE", "local")
os.environ.setdefault("HEYGILLI_DATA_DIR", "/tmp/hgdemo")
from heygilli_agents.reviewer import review_channel

CHANNELS = {
    "Peppa Pig":     "UCAOtE1V7Ots4DjM8JLlrYgg",
    "SciShow Kids":  "UCRFIPG2u1DxKLNuE3y2SjHA",
    "Ryan's World":  "UChGJGhZ9SOOHvBB0Y4DOO_w",
    "Mark Rober":    "UCY1kMZp36IQSyNx_9h4mpCg",
    "Cocomelon":     "UCbCmjCuTUZos6Inko4u57UQ",
}
out = {}
for name, cid in CHANNELS.items():
    try:
        r = review_channel(cid, refresh=True)
        out[name] = r.model_dump()
        print(f"--- {name}: {r.verdict} | flags={[f.kind for f in r.flags]}")
        print(f"    {r.summary}")
        for f in r.flags:
            print(f"    [{f.kind}] {f.note}")
        print(f"    good_for={r.good_for} model={r.model}")
    except Exception as e:
        print(f"--- {name}: FAILED {type(e).__name__}: {e}")
json.dump(out, open("/tmp/demo_reviews.json", "w"), indent=1)
