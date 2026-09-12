"""Assemble the demo video from plan.json: one segment per beat, then concatenate.

Each beat is a visual (a slide PNG, or a slice of a recorded clip) under its
narration. The segment lasts as long as the narration plus a little air; a
clip shorter than that holds its last frame, a longer one is cut.

plan.json:
  [{"id": "01-problem",
    "audio": "audio/01-problem.mp3",
    "pad": 1.0,
    "visuals": [{"slide": "slides/s01a.png", "share": 0.6},
                {"slide": "slides/s01b.png", "share": 0.4}]},
   {"id": "03-curator",
    "audio": "audio/03-curator.mp3",
    "visuals": [{"clip": "takes/review.webm", "start": 12.0}]}]
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
SEG = HERE / "segments"
SEG.mkdir(exist_ok=True)
FPS = 30
VF = "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0xF3F8F6,fps=30,format=yuv420p"


def duration(path: Path) -> float:
    out = subprocess.check_output(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)]
    )
    return float(out.decode().strip())


def run(cmd: list[str]) -> None:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"ffmpeg failed: {' '.join(cmd)}\n{r.stderr[-1500:]}")


def visual_part(v: dict, seconds: float, out: Path) -> None:
    """One silent 1080p piece of `seconds`."""
    if "slide" in v:
        run(["ffmpeg", "-y", "-loop", "1", "-t", f"{seconds:.3f}", "-i", str(HERE / v["slide"]),
             "-vf", VF, "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", str(out)])
        return
    src = HERE / v["clip"]
    start = float(v.get("start", 0))
    # Hold the last frame if the clip runs out before the narration does.
    vf = f"{VF},tpad=stop_mode=clone:stop_duration={seconds:.3f}"
    run(["ffmpeg", "-y", "-ss", f"{start:.3f}", "-i", str(src), "-t", f"{seconds:.3f}",
         "-vf", vf, "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", str(out)])


def build_beat(b: dict) -> Path:
    audio = HERE / b["audio"]
    total = duration(audio) + float(b.get("pad", 1.2))
    visuals = b["visuals"]
    shares = [float(v.get("share", 1 / len(visuals))) for v in visuals]
    scale = sum(shares)
    parts = []
    for i, (v, share) in enumerate(zip(visuals, shares)):
        part = SEG / f"{b['id']}-v{i}.mp4"
        visual_part(v, total * share / scale, part)
        parts.append(part)
    silent = SEG / f"{b['id']}-silent.mp4"
    if len(parts) == 1:
        silent = parts[0]
    else:
        lst = SEG / f"{b['id']}-parts.txt"
        lst.write_text("".join(f"file '{p}'\n" for p in parts))
        run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst), "-c", "copy", str(silent)])
    out = SEG / f"{b['id']}.mp4"
    # Narration starts a beat in, and the audio is padded to the picture.
    run(["ffmpeg", "-y", "-i", str(silent), "-i", str(audio),
         "-filter_complex", "[1:a]adelay=300|300,apad[a]", "-map", "0:v", "-map", "[a]",
         "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-shortest", str(out)])
    print(f"{b['id']:18} {duration(out):5.1f}s", flush=True)
    return out


def main() -> None:
    plan = json.loads((HERE / "plan.json").read_text())
    segs = [build_beat(b) for b in plan]
    lst = SEG / "all.txt"
    lst.write_text("".join(f"file '{s}'\n" for s in segs))
    final = HERE / "heygilli-demo.mp4"
    run(["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(lst),
         "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-c:a", "aac", "-b:a", "192k",
         "-movflags", "+faststart", str(final)])
    print(f"FINAL {final.name}: {duration(final):.1f}s")


if __name__ == "__main__":
    main()
