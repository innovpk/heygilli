# HeyGilli demo video script

Target length: 4:50. Hard limit: 5:00. The beats below add to 4:50, which leaves ten seconds of
slack for a title card and one overrun. If the edit runs long, cut in this order: beat 5, then beat
12, then beat 10. Never cut from beats 1, 3, 4 or 7. Upload to YouTube, public, before the Devpost
form is submitted.

Revised 12 September 2026 to match what is live at heygilli.com. Every claim below is something the
live app or the code does; the few numbers only the recording can confirm are marked **check**.

Judging reminder: the video must show a working project and cover the problem, the audience, and why
it matters. The agent does something on its own before 1:35, so a judge who stops early has still
seen it.

**Positioning, and the one mistake to avoid.** Do not open with the quiz. Pausing a video to ask a
question already exists in QuizStop, Edpuzzle, PlayPosit and others, and a judge who knows any of
them will file this as a copy in the first fifteen seconds. Open with the number instead: the
channels one child follows that a parent has never seen. The questions are a feature of a product
that screens for the parent, and the video has to say that in the order it shows things.

Voice-over lines are written to be spoken. Short sentences, normal pace; each beat's lines fit its
slot with a second or two to spare.

Legend for "Record": CAM = phone camera on a tripod. SCR = screen capture (`scrcpy` for Android,
QuickTime or OBS for the Mac and the browser). SLIDE = exported PNG shown in the edit.

---

## Beats

### 1. The number. 0:00 to 0:25

On screen: the real subscription list scrolling, row after row, past the bottom of the screen. Hold
on the scroll a beat longer than feels comfortable: the length is the point. Then the count, large:
**148**. Then a second, smaller: **19**. Then the title card "HeyGilli".

Record: SCR, SLIDE.

Voice-over:

> My daughter is subscribed to a hundred and forty-eight YouTube channels.
> I had seen about ten of them. Her brother follows nineteen.
> No parent can check a hundred and forty-eight channels. So nobody does.
> HeyGilli is the agent that does it for you.

**Check:** 148 and 19 are your real counts from the export. Use whatever the file says on the day.

### 2. Where that list comes from. 0:25 to 0:42

On screen: the parent app, the YouTube Kids import. The export zip is picked, the preview shows both
child profiles with their counts, each is matched to a child, Import.

Record: SCR.

Voice-over:

> No API can read a YouTube Kids profile. Google's own export is the only way in.
> One file, and Gilli has both children's real lists.
> Their watch history is in that file too. It never leaves the phone.

Editing note: show the privacy line on screen as it is said. The code enforces it.

### 3. What those channels actually are. 0:42 to 1:10

**The most important beat.** On screen: the channel review list, "Reviewed 148 of 148", the filter
chips, the few that need a look sorted to the top. Tap one: the summary, the specific concerns, and
the sample titles the review was drawn from. Then remove it.

Record: SCR.

Voice-over:

> Gilli read every one of those channels and what they have been publishing.
> Most are fine. A few are worth a look.
> This one is prank and challenge videos. It says why, and shows the titles it read.
> One tap and it is gone from her list.

**Check:** the counts on the chips, and pick a real flagged channel with its real reason.

### 4. It keeps screening, on its own. 1:10 to 1:35

On screen: the Mac terminal, large dark font. Run the Curator (`POST /curator/run`). The trace
scrolls: the Curator agent calls its one tool, `screen_video`, returns a `CuratorDecision`, and the
approved video goes on to the Planner agent, which calls `icon_lookup` and writes the questions.
Hold about three seconds. Cut to the parent app: the "Waiting for you" card for a borderline upload,
its reason in two sentences, **Show it** and **Not this one**. Parent taps Show it.

Record: SCR (terminal), SCR (parent app).

Voice-over:

> While nobody is watching, the Curator agent checks every approved channel for new uploads.
> It reads each one against this family's own answers, and hands the good ones to the Planner, which writes the questions.
> Clear cases it decides alone. This one is borderline, so it waits for the parent, with its reason.
> That is the whole relationship. The agent works. The parent answers one question.

### 5. Check before you allow. 1:35 to 1:47

On screen: the parent pastes a YouTube link a friend sent. A few seconds later: the verdict, its
tags, and the reason, read against this child's answers. Allow.

Record: SCR.

Voice-over:

> Found something yourself? Paste the link. Gilli reads it against your answers before your child ever sees it.

### 6. The shelf. 1:47 to 2:02

On screen: tablet, kid mode, Rayan's shelf: a section per channel, big tiles, titles and lengths.
Tap the mic in the search box and say "volcano". The shelf narrows to the volcano videos.

Record: SCR (tablet), CAM for the child's voice if you have consent.

Voice-over:

> The child's shelf looks like YouTube Kids, with only what the parent allowed.
> They can search by typing or by voice, but only among those videos. Search never reaches YouTube.

### 7. The younger child, and a right answer. 2:02 to 2:25

On screen: tablet, Lisa's shelf: one grid of big pictures. She taps a video. At a natural break it
pauses. Gilli asks by voice: "What animal is that?" The mic pulses. She answers. Gilli says the word
back, stretched: "A giraffe! Gi-raffe." Stars burst around Gilli with a short cheer. The video
resumes.

Record: CAM (hands and tablet; face only with consent), SCR in parallel as backup.

Voice-over:

> Lisa is five. Gilli pauses at a natural break and asks, out loud, about what is on the screen.
> The question needs no reading. Whatever she says, Gilli says the word back once, clearly.
> A right answer gets a cheer. A wrong one gets curiosity. Silence is fine too.

### 8. Tap instead of talk. 2:25 to 2:40

On screen: same session. Three big pictures. Gilli: "Show me the blue one." Lisa taps the fish.
Gilli: "Yes! Blue." Then two seconds of Rayan's session with a yes-or-no tap.

Record: CAM, SCR backup.

Voice-over:

> Not every question needs speech. Three pictures from a kid-safe icon set. One tap.
> If a younger child's mic hears nothing twice, the Buddy agent turns the rest of the session into pictures on its own.
> Older kids can tap too. A shy child or a tired one still has a way in.

### 9. The older child. 2:40 to 2:55

On screen: Rayan's volcano video. Pause. The question is spoken and shown as text: "What comes out
of a volcano when it erupts?" He answers in a sentence. Gilli builds on the answer. The video
resumes.

Record: CAM, SCR backup. If no child of that age is available, SCR with an adult voice, and say so in
the caption.

Voice-over:

> Rayan is nine. Same agents, different age band.
> Now the questions are why and what next, with the words on screen as well.
> Gilli talks to him like an older cousin who finds the topic interesting. No baby talk.

### 10. Urdu. 2:55 to 3:07

On screen: same child, Urdu selected. Question in Urdu, answer in Urdu, reply in Urdu. English
subtitles burned into the edit.

Record: CAM or SCR.

Voice-over:

> Bilingual families get little from English-first apps.
> Gilli asks in Urdu and listens in Urdu.

### 11. The limits are yours, and so are the words. 3:07 to 3:30

On screen: the parent's time limits. Then kid mode: the break arrives, Gilli says the parent's own
line, with the activity the parent chose. Then the parent screen where that line was written. Then,
on a video, **Add a question**, one typed sentence, and that exact sentence asked in the session.

Record: SCR.

Voice-over:

> You set the limits. After twenty-five minutes Gilli stops the video.
> What he says then is your sentence, not his. Nothing Gilli says at a break was written by a model.
> And you can add a question of your own to any video. It is asked exactly as you typed it.

Editing note: land the break line clearly. There is no model call anywhere in the break path, and
that is the answer to the obvious question about letting an AI talk to a child.

### 12. Games with Gilli. 3:30 to 3:40

On screen: from the shelf, the games button. Find Gilli: he hides behind one of the trees, the child
taps, he pops out. A round star lights up.

Record: SCR.

Voice-over:

> Between videos, two short games. The Playmate agent picks how hard the next round is. Where Gilli hides is picked in code, never by a model.

### 13. Tonight's note. 3:40 to 3:58

On screen: the parent's phone, the child's page, Tonight's note. For Lisa: said today, heard but not
said yet, and a question for dinner. Swipe to Rayan's: understood, shaky, and a question for dinner.

Record: SCR, CAM of the phone in hand for the first second.

Voice-over:

> Each night the Digest agent reads the day's sessions and writes a short note per child.
> For Lisa: the words she said, the words she heard but did not say yet, and a question for dinner.
> For Rayan: what he understood, what was shaky, and one question for dinner.

### 14. The model is a setting. 3:58 to 4:10

On screen: terminal, `grep HEYGILLI_MODEL .env`. One line reads
`HEYGILLI_MODEL_BUDDY=bedrock:us.amazon.nova-pro-v1:0`. Change it to
`bedrock:us.amazon.nova-lite-v1:0`, restart the gateway, and the same question turn runs again on
the tablet.

Record: SCR (terminal), SCR (tablet).

Voice-over:

> Every agent's model is one line of configuration.
> Today that is Amazon Nova Pro on Bedrock, the one our eval picked. Change the line, restart, same agents, same session.

### 15. How it is built. 4:10 to 4:27

On screen: `docs/architecture.png`, then zoom on the agents panel.

Record: SLIDE.

Voice-over:

> Eight Strands agents behind one gateway. Curator screens, Planner writes the questions, Buddy runs the session, Digest writes the note, Reviewer reads a channel, Coach drafts for the parent, Explainer answers the parent, and Playmate runs the games.
> The agents decide. The code fetches and enforces, because the guarantees a parent is trusting belong in code, not in a prompt.
> Bedrock, Polly for Gilli's voice, and DynamoDB. One Flutter app for phone, tablet and web.

### 16. Impact and honesty. 4:27 to 4:42

On screen: a SLIDE with four lines: "Ads still play. Creators still get paid." / "The official
YouTube player. Nothing drawn over it, nothing downloaded." / "Nothing a child says is stored." /
"Leaving kid mode needs the parent's PIN." Then a second SLIDE: "Not built yet: the TV layout,
AgentCore deployment."

Record: SLIDE.

Voice-over:

> Ads still play, and creators still get paid.
> Nothing a child says is stored. Only a score and a ten-word paraphrase.
> Not built yet: the TV layout, and moving the agents to AgentCore.

### 17. Close. 4:42 to 4:50

On screen: a SLIDE with heygilli.com, the repo URL, the three builder.aws post titles, and "Built on
Strands Agents SDK and Amazon Bedrock for Agents for Humans".

Record: SLIDE.

Voice-over:

> HeyGilli. Try it at heygilli.com. The code and a three-part write-up are in the description.

---

## Recording checklist

Before the child sessions

- [ ] Pre-screen the demo videos so their plans are cached and no turn waits on a model call.
- [ ] Charge tablet, phone and camera. Do Not Disturb on both devices.
- [ ] Tablet in screen pinning. Volume at 70 percent so Gilli is audible on the camera mic.
- [ ] Screen recording running for every child take, as backup for every turn.
- [ ] Quiet room. TV and fans off. Child speech is hard enough for the recogniser.
- [ ] The parent's consent for the child's voice; decide whether faces are in frame. Hands and tablet only is fine.
- [ ] Two or three takes, on different days if possible. Do not push a tired child for another.

Before the terminal beats

- [ ] Terminal font 18 pt or larger, dark theme, window 1280 x 720.
- [ ] Trace output trimmed to agent and tool names and a one-line result each. No JSON longer than the screen.
- [ ] Scripted commands in a file so nothing is typed live: run the Curator, show the model line, edit it, restart.
- [ ] No keys on screen. Show the model line with `grep HEYGILLI_MODEL .env`, never the whole file.

Before the edit

- [ ] Check every child clip against the order: pause, ask, answer, reply, resume. Cut any take where it broke.
- [ ] English subtitles on the Urdu beat. Captions on all the voice-over.
- [ ] Total under 5:00 including the title card. Aim for 4:45.
- [ ] Export 1080p, 30 fps. Upload to YouTube as public, not unlisted. Title: "HeyGilli: an AI co-watching buddy for kids' YouTube (Agents for Humans hackathon)".
- [ ] Description: heygilli.com, the repo, the three builder.aws links, and one line on what is not built yet.
- [ ] Watch it once on a phone with the sound low. If Gilli cannot be heard in beat 7, re-record from the screen recording's audio.

Fallbacks

- [ ] No nine-year-old available: record beats 9 and 10 with screen capture and an adult voice, and caption it honestly.
- [ ] The model swap fails on camera: use a recording of a working swap from earlier, and say "recorded earlier".
- [ ] No borderline upload turns up in the run: show one already waiting in the parent's "Waiting for you" card.
