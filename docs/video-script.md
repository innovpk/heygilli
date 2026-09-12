# HeyGilli demo video script

Length of the current cut: 4:52, at https://youtu.be/ab9HNgQXS6A. Hard limit: 5:00. Every beat below is what is in the rendered
video, in order, with the second it starts at. The voice-over is Amazon Polly (Matthew,
generative), one mp3 per beat; the picture is a screen recording of the live app at
heygilli.com or a rendered slide; the cut is assembled beat by beat with ffmpeg from
`docs/video/plan.json`. See "How the video is built" at the end.

Revised 12 September 2026 for the second cut. Every claim is something the live app or the
code does on that date.

Judging reminder: the video must show a working project and cover the problem, the audience, and
why it matters. The agent does something on its own before 0:40, so a judge who stops early has
still seen it.

**Positioning, and the one mistake to avoid.** Do not open with the quiz. Pausing a video to ask a
question already exists in QuizStop, Edpuzzle, PlayPosit and others, and a judge who knows any of
them will file this as a copy in the first fifteen seconds. Open with the number instead: the
channels one child follows that a parent has never seen. The questions are a feature of a product
that screens for the parent, and the video has to say that in the order it shows things.

---

## What changed from the first cut

The first cut (4:55, unlisted at https://youtu.be/7pqNpfnOi2c) had these faults, found by
stepping through it frame by frame:

- **Screens small on the canvas.** Kid-mode takes were recorded at 1920x1080 on a desktop layout,
  so the session sat in the top-left third of the frame with empty canvas around it. The new
  kid-mode takes are recorded at a tablet viewport (1280x720 at 1.5x), which fills the frame.
- **Dialogs read as pasted-on images.** The "Ask about this video", "Add channels" and "Ask
  something of your own" sheets are real in-app sheets, but at desktop width they sat as tall
  panels over a wide page. Kept where the beat needs them; the kid-mode overlaps are gone.
- **The same screen under unrelated narration.** The "What Rayan will see" list played under
  five different beats, including the limits beat. Each beat now has its own footage.
- **A generic question.** The session beat showed "How was this different from the last one you
  watched?", a bank question, under narration about a question written for this video. The new
  take shows a question written from the video's transcript, with its hint.
- **No pictures in the pre-reader beat.** The younger-child beat showed a portrait video with
  black bars and no cards. Re-recorded.
- **Two games, now six.** The games beat showed only Find Gilli. It now shows the picker and the
  four new card games.
- **Features missing.** Hints after silence, written answer cards for readers, two or three
  questions sized to the video's length, and the six games were not in the first cut.
- **Trailing black.** The last second was black; the close slide now holds to the end.

To make room, three beats were cut: the empty inbox (0:59 in the old cut), "judged on the
transcript or the title" (1:30), and "say it again" (2:40, folded into the hint beat).

---

## Beats

### 1. The number. 0:00

Slides: "148 channels. I had seen ten." then the title card.

> My daughter is subscribed to a hundred and forty-eight YouTube channels. I had seen about ten of
> them. Her brother follows nineteen.
> No parent can check a hundred and forty-eight channels, so nobody does. Parental controls decide
> what a child may see, and then do nothing.
> HeyGilli is the agent that does that job for you.

### 2. Setup. 0:18

Live: adding a kid, the household questions, the interests page.

> A parent answers a few questions about what is fine in their house, and picks what the child
> likes. That is all the setup there is.

### 3. The Curator. 0:25

Live: the review screen, Shown and Hidden, the reason under a hidden video.

> Then the Curator agent reads each new upload from the family's channels, against those answers.
> Clear cases it decides alone, and it shows its reasons as tags a parent can skim.
> Anything it kept back says why.

### 4. Borderline waits for the parent. 0:38

Live: the hidden list with its reasons.

> Borderline videos wait for the parent, with the reason in two sentences.
> That is the whole relationship. The agent does the work. The parent answers only the questions
> that are really theirs.

### 5. Hidden, with a sentence each. 0:49

> Everything Gilli kept back sits in one place, each with the sentence it wrote for keeping it.
> The parent can overrule any of them. The agent is never the last word.

### 6. Only these channels. 0:58

Live: the Channels tab.

> Only these channels reach Rayan.
> Gilli read each one before anything from it was offered, and it never removes a channel on its
> own: that stays the parent's decision.

### 7. Check before you allow. 1:08

Live: a pasted link, the verdict.

> Found a video yourself? Paste the link, and Gilli reads it against your answers before your child
> ever sees it.

### 8. Ask about a video. 1:15

Live: the ask sheet, a question picked, the Explainer's answer.

> A parent who wants to know more about a video can just ask, in their own words.
> The Explainer agent answers from what it actually read, and says so when the answer is only the
> title.

### 9. Import. 1:25

Still: the Add channels sheet with "Import from YouTube Kids".

> A family already on YouTube does not start from an empty shelf.
> Bring your own subscriptions in, and every channel is read against your answers before a single
> video is offered.

### 10. The shelf. 1:35

Live: Rayan's shelf, a typed search.

> The child's shelf looks like YouTube Kids, with only what the parent allowed.
> They can search, by typing or by voice, but only among those videos. Search never reaches
> YouTube.

### 11. Voice search. 1:46

> A child who cannot spell yet holds the microphone and says it instead.
> The words never leave the device, and the search still only reaches videos the parent allowed.

### 12. The question. 1:56

Live, tablet: the yawn video playing, then it pauses and Gilli asks "Can you recall what
scientists think might be one of the reasons we yawn?", the text on screen, the mic ring below.

> At a natural break the video pauses, and Gilli asks about what just happened, out loud.
> The Planner agent wrote it from this video's own words, for this child's age: two or three
> questions a video, sized to its length.
> The child answers by talking or by tapping, the Buddy agent replies, and the video carries on.

### 13. The hint. 2:14

Live: the same question with "Think about the part where it talked about why we yawn." under it,
then "No worries, let's keep watching." when the window runs out.

> A child who goes quiet is not left in silence.
> After a few seconds Gilli gives a hint: a nudge back to the moment in the video, never the
> answer, and the clock starts again.
> They can also ask to hear the question again.

### 14. Written cards. 2:27

Live: "Which animal uses its tail to maintain balance?" with three cards, monkey as a picture and
Kangaroo and Horse as words. The tap lands on Horse; Gilli says "Horse? The video showed
Kangaroo."

> For a child who reads, the answers can be written cards taken from the video: one right, and two
> a child who half-watched might believe.
> A younger child only ever gets pictures.

### 15. The younger child. 2:38

Live, tablet: Lisa's shelf, a grid of big pictures; then her question, spoken, with Gilli and the mic
ring and no text on screen; then Gilli saying the word back. Every pre-reader plan probed opened
with a spoken question, so no picture cards were filmed for this beat.

> A younger child gets big pictures, and questions that need no reading: one word, a tap, or a yes
> or no.
> A right answer gets a cheer. A wrong one gets curiosity. Nobody is ever told they are wrong.

### 16. A parent's own question. 2:52

Live: "Ask something of your own" on a video, and the question typed.

> A parent can add a question of their own to any video.
> Gilli asks it in their words, where it fits in the video. No model rewrites a parent's question.

### 17. Six games. 3:01

Live, tablet: the picker with six tiles, then Letters ("Find the small letter g"), Numbers
("5 + 3 = ?"), Who am I ("I have fins and scales and I breathe under water"), Spot the animal
("Find the duck!").

> Between videos there are six short games: find Gilli, catch him, letters, numbers, who am I, and
> spot the animal.
> The questions are written on the device for the child's age. The Playmate agent sets how hard
> the next round is, and nobody loses a round.

### 18. The limits. 3:16

Live: the Rules tab, the limits, then the question kinds.

> The parent sets the day's minutes, where the breaks fall, and when the day ends.
> None of that is the model's to decide. The limits are the parent's, and the code is what enforces
> them.

### 19. The break, and the PIN. 3:27

Live: the break messages the parent wrote, then the PIN pad.

> When the day's minutes run out, Gilli stops the video and says the parent's own line.
> Getting back out of kid mode needs the parent's PIN, so the child cannot simply leave.

### 20. Progress. 3:36

> Progress is the longer view: the minutes, whether the questions are being answered, and what is
> worth another look.

### 21. Tonight's note. 3:43

Slide: the note as the parent sees it.

> Each night the Digest agent reads the day and writes a short note for the parent:
> what was said, what was only heard, and one question to ask at dinner.

### 22. The model is a setting. 3:52

Slide: `grep HEYGILLI_MODEL .env`.

> Every agent's model is one line of configuration.
> Today that is Amazon Nova Pro on Amazon Bedrock, the one our eval picked. Change the line, and the
> same agents run on another model.

### 23. How it is built. 4:03

Slide: `docs/architecture.png`.

> Eight Strands agents sit behind one gateway: Curator, Planner, Buddy, Digest, Reviewer, Coach,
> Explainer and Playmate.
> The agents decide. The code fetches and enforces, because the guarantees a parent trusts belong
> in code, not in a prompt.

### 24. Tools in, typed objects out. 4:20

Slide: repo source.

> Each agent gets its own tools and its own output type.
> A tool is a plain Python function, the answer comes back as a validated Pydantic object rather
> than text, and every call is one traced span.

### 25. Built to play fair. 4:32

Slide.

> Ads still play, and creators still get paid.
> Nothing a child says is stored. Only a score and a short paraphrase.
> Not built yet: the TV layout, and moving the agents to AgentCore.

### 26. Close. 4:44

Slide: heygilli.com, the repo, the write-up.

> HeyGilli. Try it at heygilli dot com. The code and a three-part write-up are in the description.

---

## How the video is built

Everything is in `docs/video/`, scripts only; the recordings, narration audio and rendered
slides are large and stay out of the repo.

1. **Narration.** `narration*.json` holds the lines per beat. `speak.py` sends each beat to
   Amazon Polly (Matthew, generative) and writes `audio/<beat>.mp3`. Only re-run it for a beat
   whose lines changed; the voice is the same across runs.
2. **Takes.** `record_part*.py` drive the live site headless with Playwright (Chrome channel) and
   record a `.webm`, marking the second each screen appeared in `takes/<take>-marks.json`. The
   kid-mode takes (15 to 17) use a 1280x720 viewport at 1.5x; the parent takes are 1920x1080.
   Take 15 sets up a fresh household with two kids and allows the videos through the API so the
   plans are warm before anything is filmed.
3. **Slides.** `slides.html` has one `<section>` per slide; `render_slides.py` screenshots each
   to `slides/<id>.png` at 1920x1080.
4. **Plan.** `make_plan.py` lists the beats in order, each naming its footage as a take plus a
   mark plus an offset, or a slide, with a share of the beat's length. It writes `plan.json`.
5. **Cut.** `assemble.py` builds one segment per beat (narration length plus one second of air),
   scales everything to 1920x1080 on the cream ground, and concatenates. `make_srt.py` derives
   the subtitles from the same plan, so they never drift.

Upload: 1080p, 30 fps, to YouTube as Public. Title: "HeyGilli: an AI co-watching buddy for kids'
YouTube (Agents for Humans hackathon)". Description: heygilli.com, the repo, the three builder.aws
links, and one line on what is not built yet. Upload the `.srt` as captions.
