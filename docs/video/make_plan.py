"""Build plan.json for assemble.py from the takes' time marks.

Each beat names the footage it wants. A beat whose marks are missing falls
back to its listed still, so the plan always builds and the gap is obvious in
the cut — and `missing` says which beats were short.

Three ways to name a visual:
    ("slide", "slides/s01a.png", 0, share)      a rendered slide
    ("clip",  "takes/part2.webm", 303.18, share) a clip at a fixed second
    ("part7", "question", -1.0, share)           a clip at a mark, plus offset
"""
import json
from pathlib import Path

HERE = Path(__file__).parent
TAKES = HERE / "takes"

TAKE_NAMES = ("part1", "part1b", "part2", "part2-first", "part3",
              "part4", "part5", "part7", "part8", "part10", "part11", "part12",
              "part12b", "part15", "part16", "part17")


def load(take: str) -> dict:
    f = TAKES / f"{take}-marks.json"
    return json.loads(f.read_text()) if f.exists() else {}


MARKS = {t: load(t) for t in TAKE_NAMES}

# The order they play in. Roughly: what the parent sets up, what the agents
# then do, what the child sees, and what comes back to the parent afterwards.
BEATS = [
    ("01-problem", [("slide", "slides/s01a.png", 0, 0.55), ("slide", "slides/s01b.png", 0, 0.45)], None),
    ("02-setup", [("part1", "kid_filled", -3.0, 0.3), ("part1", "questions", 1.0, 0.45),
                  ("part1", "interests", 0.5, 0.25)], "slides/s01b.png"),
    # Take 1b was filmed before the spider video was hidden, and its Shown
    # list has that video at the top of frame. Take 10's list is the current
    # one — cat, kitten, volcanoes, chipmunk — so the shown half comes from
    # there and the reasons half from the hidden tab.
    # The current shown list is only on screen for 3.2s in take 10 (145.9 to
    # 149.1, when the add-a-question sheet opens over it), so it gets a share
    # that fits inside that and the reasons carry the rest of the beat.
    # Take 1's review list for the shown half: take 10's shown list has the
    # add-a-question sheet opening over it within a second.
    ("03-curator", [("part1", "review_ready", 0.5, 0.3), ("part1b", "hidden_tab", -1.0, 0.35),
                    ("part1b", "hidden_why", -1.0, 0.35)],
     "takes/part1-shots/hidden.png"),
    ("04-waiting", [("part1b", "hidden_tab", -2.0, 0.5), ("part1b", "hidden_why", -2.0, 0.5)],
     "takes/part1-shots/hidden.png"),
    ("25-hidden", [("part1b", "hidden_tab", 1.5, 0.5), ("part1b", "hidden_why", 1.0, 0.5)],
     "takes/part1-shots/hidden.png"),
    ("17-channels", [("part5", "channels_tab", 0.5, 0.5), ("part5", "channels_scrolled", -1.0, 0.5)],
     "slides/s01b.png"),
    # Take 4 checked the whole SciShow channel, so its results are headed by
    # "The Yuckiest Animals". Take 10 checked one volcano video, which is the
    # same flow without that title on screen.
    # The verdict is up from 31.0s until the ask sheet opens at 34.2s: three
    # seconds, so the reading-it screen carries most of the beat.
    # Take 12b: the link typed and Check pressed, then the verdict. Take 10's
    # check screen was still loading at its mark.
    ("05-check", [("part12b", "check_pressed", -2.5, 0.55), ("part12b", "review_open", 0.5, 0.45)],
     "slides/s01b.png"),
    # Take 10 is where these two finally exist as motion: the ask sheet, the
    # question picked from it, and the Explainer's answer on screen.
    # The answer slice has to end before take 10 reloads the page at ~124s:
    # ask_answered is 119.1, so a 6s slice from +0.5 would run into the reset.
    ("19-ask", [("part10", "ask_sheet", 1.0, 0.3), ("part10", "ask_picked", 1.0, 0.25),
                ("part10", "ask_answered", -0.6, 0.45)],
     "takes/part4-shots/check-result.png"),
    # The Add channels sheet — the one that offers "Import from YouTube Kids" —
    # is only on screen for about three seconds in take 10 (18.6s to 21.7s),
    # and a five-second slice runs straight past it onto the empty check
    # screen. Shorter than the beat needs, so the beat holds the frame instead.
    ("22-import", [("slide", "takes/part10-shots/add-sheet.png", 0, 1.0)],
     "takes/part4-shots/add-sheet.png"),
    ("06-shelf", [("part7", "shelf", 0.5, 0.45), ("part7", "searched", -3.0, 0.55)],
     "slides/s01b.png"),
    ("24-voice-search", [("part7", "searched", -1.0, 0.55), ("part7", "search_cleared", -4.0, 0.45)],
     "slides/s01b.png"),
    # Take 15 at a tablet viewport: the question is about the video (yawning),
    # its text on screen, then the hint under it after the child says nothing.
    # Take 17 at a tablet viewport: the video playing, then the question about
    # it with its text on screen (fires about 110 s in, on its own).
    ("07-session", [("part17", "question", -9.0, 0.35), ("part17", "question", 0.4, 0.65)],
     "takes/part17-shots/question.png"),
    # The hint appears under the question about ten seconds into the silence;
    # then the window runs out and Gilli says "no worries".
    ("28-hint", [("part17", "hint", -0.5, 0.65), ("part17", "silence_reply", -0.3, 0.35)],
     "takes/part17-shots/hint.png"),
    # Monkey (a picture), Kangaroo and Horse (words). The tap lands on Horse
    # and Gilli says what the video showed: a wrong card gets the answer, not
    # "wrong".
    ("29-cards", [("part17", "pick", 0.3, 0.5), ("part17", "picked", 1.2, 0.5)],
     "takes/part17-shots/pick.png"),
    # Take 16: Lisa, five, on the same household. Pictures, a tap, the reply.
    # Lisa's grid of big pictures, then her first question two minutes into
    # the video (spoken; Gilli and the mic ring, no text), then Gilli saying
    # the word back when the window ran out.
    ("08-younger", [("part16", "shelf", 0.5, 0.3), ("part16", "session_start", 112.6, 0.45),
                    ("part16", "session_start", 118.6, 0.25)],
     "takes/part16-shots/shelf.png"),
    # No footage of the add-a-question sheet survived four takes, and this beat
    # was playing over the title card. The lower half of the Rules screen is
    # the honest picture for it: the list of question kinds, each switchable,
    # which is exactly what sits at break_messages +0.
    ("20-own-question", [("part10", "shown_list", 1.0, 0.45),
                         ("part11", "typed", -1.5, 0.55)],
     "takes/part10-shots/own-question-sheet.png"),
    ("10-games", [("part15", "games", 0.8, 0.22), ("part15", "letters", 0.6, 0.2),
                  ("part15", "numbers", 0.6, 0.2), ("part15", "guess", 0.6, 0.19),
                  ("part15", "spot", 0.6, 0.19)],
     "takes/part15-shots/games.png"),
    # A smaller share keeps this off the repaint that follows the Rules screen.
    # Take 12's Rules screen, both halves: the limits, then the question kinds.
    ("09-limits", [("part12", "rules_tab", 2.8, 0.5), ("part12", "questions_open", 0.5, 0.5)],
     "slides/s01b.png"),
    # Start early for the same reason as 23-repeat: the Rules screen is good
    # from about -4 to +2 around the mark, and a 5.4s slice from +2 runs out
    # the far side into the repaint and then the kid shelf. The PIN pad at
    # pin_gate +1.5 holds to the end of the take, so it needs no margin.
    ("21-break", [("part8", "break_messages", -4.0, 0.55), ("part8", "pin_gate", 1.5, 0.45)],
     "slides/s01b.png"),
    ("18-progress", [("part5", "progress_tab", 0.5, 0.5), ("part5", "progress_scrolled", -1.0, 0.5)],
     "slides/s01b.png"),
    ("11-note", [("slide", "slides/note.png", 0, 1.0)], None),
    ("12-model", [("slide", "slides/s12.png", 0, 1.0)], None),
    ("13-architecture", [("slide", "slides/s13.png", 0, 1.0)], None),
    # The video named Strands once, in a list of agent names. Criterion one is
    # "skillful use of Strands Agents", so the SDK gets its own beat, and the
    # slide is repo source rather than a claim about it.
    ("27-sdk", [("slide", "slides/s16.png", 0, 1.0)], None),
    ("14-honesty", [("slide", "slides/s14.png", 0, 1.0)], None),
    ("15-close", [("slide", "slides/s15.png", 0, 1.0)], None),
]


def visual(take: str, ref: str, offset: float, share: float):
    if take == "slide":
        return {"slide": ref, "share": share}
    if take == "clip":
        return {"clip": ref, "start": max(0.0, offset), "share": share}
    t = MARKS.get(take, {}).get(ref)
    if t is None:
        return None
    # A take recorded at a tablet viewport sits in the top-left of its frame;
    # its cropped, upscaled .mp4 stands in for the .webm when there is one.
    ext = "mp4" if (TAKES / f"{take}.mp4").exists() else "webm"
    return {"clip": f"takes/{take}.{ext}", "start": max(0.0, t + offset), "share": share}


def main() -> None:
    plan, missing = [], []
    for beat_id, wants, fallback in BEATS:
        vs = [visual(*w) for w in wants]
        got = [v for v in vs if v]
        if not got:
            missing.append(beat_id)
            got = [{"slide": fallback, "share": 1.0}]
        elif len(got) < len(vs):
            missing.append(f"{beat_id} (partial)")
        beat = {"id": beat_id, "audio": f"audio/{beat_id}.mp3", "visuals": got}
        beat["pad"] = 1.0  # a breath between beats; the whole cut has to stay under five minutes
        if beat_id == "15-close":
            beat["pad"] = 2.5
        plan.append(beat)
    (HERE / "plan.json").write_text(json.dumps(plan, indent=1))
    print(f"plan.json written: {len(plan)} beats")
    print("missing footage: " + ", ".join(missing) if missing else "all footage found")


if __name__ == "__main__":
    main()
