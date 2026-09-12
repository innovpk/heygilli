"""Synthesize narration lines to audio/<id>.mp3 with Amazon Polly.

Reads one or more narration JSON files ([{"id": ..., "lines": [...]}, ...])
and writes a single mp3 per beat: the lines joined into one paragraph, so the
pauses are Polly's own sentence breaks rather than splices.

  python3 speak.py narration.json narration-extra.json 01-problem 19-ask
  python3 speak.py narration-extra2.json          # every beat in the file
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "audio"
OUT.mkdir(exist_ok=True)

VOICE = "Matthew"
ENGINE = "generative"


def say(beat_id: str, text: str) -> Path:
    dest = OUT / f"{beat_id}.mp3"
    cmd = [
        "aws", "polly", "synthesize-speech",
        "--voice-id", VOICE,
        "--engine", ENGINE,
        "--output-format", "mp3",
        "--text", text,
        str(dest),
    ]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"polly failed for {beat_id}:\n{r.stderr[-1200:]}")
    return dest


def main() -> None:
    args = sys.argv[1:]
    files = [a for a in args if a.endswith(".json")]
    only = {a for a in args if not a.endswith(".json")}
    if not files:
        sys.exit(__doc__)

    beats = []
    for f in files:
        beats.extend(json.loads((HERE / f).read_text()))

    for b in beats:
        if only and b["id"] not in only:
            continue
        text = " ".join(b["lines"])
        path = say(b["id"], text)
        dur = subprocess.check_output(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(path)]
        ).decode().strip()
        print(f"{b['id']:20} {float(dur):5.1f}s", flush=True)


if __name__ == "__main__":
    main()
