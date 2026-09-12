"""Write heygilli-demo.srt from plan.json and the narration files.

The cut is built beat by beat, so the subtitles can be derived rather than
transcribed: a beat's narration starts at the beat's start plus the 300ms
`adelay` assemble.py puts in front of it, and runs for the mp3's real length.

Inside a beat each line gets a slice of that length proportional to how long
it is to say, approximated by character count. That is close enough for lines
Polly reads at one pace, and it never drifts, because every beat re-anchors to
the cumulative time rather than to the previous cue.

Timestamps are written with real milliseconds. An earlier hand-rolled version
used int() and snapped every cue to a whole second, which is easy to miss
until you notice the boundaries are all suspiciously round.

    python3 make_srt.py
"""
import json
import subprocess
from pathlib import Path

HERE = Path(__file__).parent
OUT = HERE / "heygilli-demo.srt"
NARRATION = ("narration.json", "narration-extra.json", "narration-extra2.json",
             "narration-extra3.json", "narration-extra4.json", "narration-extra5.json")
DELAY = 0.3      # assemble.py: adelay=300|300
DEFAULT_PAD = 1.2  # assemble.py: b.get("pad", 1.2)


def duration(path: Path) -> float:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]
    )
    return float(out.decode().strip())


def ts(t: float) -> str:
    h = int(t // 3600)
    m = int((t % 3600) // 60)
    s = t % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}".replace(".", ",")


def lines_by_beat() -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for name in NARRATION:
        f = HERE / name
        if not f.exists():
            continue
        for b in json.loads(f.read_text()):
            out[b["id"]] = b["lines"]
    return out


def main() -> None:
    plan = json.loads((HERE / "plan.json").read_text())
    narration = lines_by_beat()

    cues: list[tuple[float, float, str]] = []
    clock = 0.0
    missing = []
    for beat in plan:
        audio = HERE / beat["audio"]
        spoken = duration(audio)
        beat_total = spoken + float(beat.get("pad", DEFAULT_PAD))
        lines = narration.get(beat["id"], [])
        if not lines:
            missing.append(beat["id"])
        else:
            weights = [max(len(x), 1) for x in lines]
            total_w = sum(weights)
            t = clock + DELAY
            for line, w in zip(lines, weights):
                span = spoken * w / total_w
                cues.append((t, t + span, line))
                t += span
        clock += beat_total

    body = []
    for i, (start, end, text) in enumerate(cues, 1):
        body.append(f"{i}\n{ts(start)} --> {ts(end)}\n{text}\n")
    OUT.write_text("\n".join(body))

    print(f"{OUT.name}: {len(cues)} cues, last ends {ts(cues[-1][1])}, cut is {ts(clock)}")
    if missing:
        print("no narration lines for: " + ", ".join(missing))


if __name__ == "__main__":
    main()
