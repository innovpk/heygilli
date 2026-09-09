# HeyGilli demo video script

Target length: 4:51. Hard limit: 5:00. The beats below add to 4:51, which leaves nine seconds of
slack for a title card and one overrun. If a beat runs long in the edit, cut beat 11 entirely before
cutting anything from beats 1, 5 or 9. Upload to YouTube, public, before the Devpost form is submitted.

Adapted from SPEC section 13 for a phone-and-tablet build. The TV appears once, as a mockup, and only if the stretch did not land. If the TV layout is built, it replaces beat 9.

Judging reminder: the video must show a working project and cover the problem, the audience, and why it matters. The order below puts the agent doing something on its own before 1:15, so a judge who stops early has still seen it.

**Positioning, and the one mistake to avoid.** Do not open with the quiz. Pausing a video to ask a
question already exists in QuizStop, Edpuzzle, PlayPosit and others, and a judge who knows any of
them will file this as a copy in the first fifteen seconds and never re-open the question. Open with
the number instead: 148 channels one child follows that a parent has never seen. The quiz is a
feature of a governance product, and the video has to say that in the order it shows things.

Voice-over lines are written to be spoken. Short sentences. Read them at a normal pace; each beat's line count fits its slot with a second or two to spare.

Legend for "Record": CAM = phone camera or mirrorless on a tripod. SCR = screen capture (`scrcpy` for Android, QuickTime or OBS for the Mac terminal). SLIDE = exported PNG shown in the edit.

---

## Beats

### 1. The number. 0:00 to 0:30

On screen: open on the real subscription list scrolling, 148 rows, names blurred or not, going on and
on past the bottom of the screen. Hold on the scroll for a beat longer than feels comfortable: the
length is the point. Then the count, large: **148**. Then a second, smaller: **19**. Then title card
"HeyGilli".

Record: SCR (the reviews screen scrolling, or the raw list), SLIDE.

Voice-over:

> My six-year-old is subscribed to a hundred and forty-eight YouTube channels.
> I had seen about ten of them.
> Her brother follows nineteen. My own account follows one.
> No parent can check a hundred and forty-eight channels. So nobody does.
> HeyGilli is the agent that does it for you.

Editing note: this beat carries the whole pitch. If it lands, the judge watches the rest asking "how",
not "how is this different from QuizStop".

### 2. Where that list comes from. 0:30 to 0:50

On screen: sign in with Google. Then the Takeout import screen, the zip picked, and the preview
showing both child profiles by name with their counts, 148 and 19. Map each to a kid. Import.

Record: SCR (phone).

Voice-over:

> No API can read a YouTube Kids profile. Google's own export is the only way in.
> One file, and Gilli has both children's real lists.
> Their watch history is in that file too. It never leaves the phone: only the subscription lists
> are pulled out and sent.

Editing note: use the parent's real names for the profiles, and the real counts. If the export is
shown at all, show the privacy line on screen at the same time; it is a claim the code actually
enforces and it is worth the two seconds.

### 3. What those channels actually are. 0:50 to 1:20

**The most important beat in the video.** On screen: the channel review list for the six-year-old,
"Reviewed 148 of 148", filter chips reading All 148 / Needs a look 3 / Good 121. Sort brings the
three concerns to the top. Tap one: the summary, the specific flags, and the sample titles the review
was drawn from. Then the Remove button.

Record: SCR.

Voice-over:

> Gilli read every one of those channels and what they have been publishing.
> A hundred and twenty-one are fine. Three are worth a look.
> This one is prank and challenge videos. It says why, and shows the titles it read.
> One tap and it is gone from her list.
> That took about five minutes and cost less than a dollar.

Editing note: show a real flagged channel with its real reason. A judge can tell a generated
screenshot from a real one, and this is the moment the product stops looking like a quiz app.

### 4. It keeps screening, on its own. 1:20 to 1:40

On screen: Mac terminal. Run the Curator (`POST /curator/run` or the scheduled job). The Strands trace scrolls: `youtube_uploads`, `get_transcript`, `screen_video`, then the typed hand-off into Planner, `icon_lookup` calls, `save_plan`. Hold for about three seconds. Then the parent's phone lights up: "New from Blippi: 'Trip to the candy factory'. Sugar-heavy. Fine for Lisa?" with Yes and Hide. Parent taps Yes.

Record: SCR (terminal, large font, dark theme), CAM or SCR (phone notification; CAM reads better).

Voice-over:

> While nobody is watching, the Curator agent checks the approved channels for new uploads.
> It reads each one, screens it for the child's age, and hands it to the Planner, which writes the questions.
> Clear cases it decides alone. This one is borderline, so it asks the parent once. Yes or no.
> That is the whole relationship. The agent works. The parent gets one question.

### 5. Pre-reader, name-it. 1:40 to 2:05

On screen: tablet, Lisa's picture-only home. Child taps a thumbnail. Video plays. At the planned moment it pauses on a giraffe. Gilli appears small in the corner. Gilli: "What animal is that?" Big mic button pulses. Child says something close to "giraffe". Gilli: "A giraffe! Gi-raffe." with a stretch gesture. Video resumes.

Record: CAM (child's hands and the tablet, face optional and only with the parent's consent), SCR (tablet via `scrcpy`, in parallel, as backup).

Voice-over:

> Lisa is four and cannot read yet, so nothing on this screen is text.
> Gilli pauses at a natural break and asks about what is on the frame.
> Whatever she says, Gilli says the word back once, clearly. That is the learning event.
> A whispered "gaffe" counts. Silence counts too. Nobody is ever wrong.

### 6. Tap instead of talk — at any age. 2:05 to 2:25

On screen: same session. Video pauses. Three big pictures appear. Gilli: "Show me the blue one." Child taps the fish. Gilli: "Yes! Blue. The fish is blue." Resume. Then cut to the nine-year-old's screen for two seconds: the same pause, but two cards — a green tick and a red cross — and a question read aloud.

Record: CAM, SCR backup.

Voice-over:

> Not every question needs speech. Three pictures from a fixed, kid-safe icon library. One tap.
> If the mic hears nothing twice, the Buddy agent switches the rest of the session to pictures on its own.
> And the older bands get the same choice. A shy child, a tired child, a child in a room full of people — a session made only of talking has no way in for any of them.

Editing note: the second half of this beat is worth the five seconds. Every product in this space
assumes a child who will perform on demand.

### 7. Older kid, English. 2:25 to 2:42

On screen: tablet, Rayan's profile (9). Volcano video. Pause. Question shown as text and spoken: "Why did the lava come out?" Child answers in a sentence into the mic. Gilli replies, building on the answer, then resumes.

Record: CAM, SCR backup. If no 9 to 11 year old is available, SCR only with an adult voice and say so in the caption.

Voice-over:

> Rayan is nine. Same agents, different band.
> Now the questions are why and what next. Text appears alongside the voice.
> Gilli talks like an older cousin who finds the topic interesting. No baby talk. An eleven-year-old who feels talked down to will not answer twice.

### 8. Older kid, Urdu. 2:42 to 2:55

On screen: same profile, Urdu selected. Question in Urdu. Answer in Urdu. Reply in Urdu. Subtitles in English burned into the edit.

Record: CAM or SCR.

Voice-over:

> Bilingual households get nothing from English-first products.
> Gilli asks in Urdu, listens in Urdu, and switches when the child does.

### 9. The limits are yours, and so are the words. 2:55 to 3:22

On screen: the parent's Time limits card, four settings. Then kid mode: watching stops, Gilli
appears with a countdown, and says the parent's own line. Then the parent screen showing where that
line was written, with the suggestion list beside it. Then, on a video card, tap **Add a question**
and type one sentence — "Which animal was the fastest?" — and cut to that exact sentence being asked
in the session.

Record: SCR.

Voice-over:

> You set the limits. After twenty-five minutes Gilli stops the video.
> What he says then is your sentence, not his.
> Gilli can suggest lines, but only to you, and only in your app.
> And you can add a question of your own to any video. It is asked in your words, exactly as you typed them.
> No model knows this one has been asking about volcanoes all week. You do.
> Nothing Gilli says to a child was written by a model.

Editing note: land the last line clearly. It is the answer to the obvious question about letting an
AI talk to a six-year-old, and it is a real architectural claim: there is no model call anywhere in
the child-facing break path.

### 10. Provider swap. 3:22 to 3:35

On screen: Mac terminal. Show `.env` with `HEYGILLI_MODEL_BUDDY=bedrock:us.anthropic.claude-haiku-4-5-20251001-v1:0`. Change the one line to `HEYGILLI_MODEL_BUDDY=anthropic:claude-opus-5` (or the second provider chosen). Restart the gateway. Cut to the tablet: the same question turn runs again and Gilli replies. Optional: show the trace header naming the provider.

Record: SCR (terminal), SCR (tablet).

Voice-over:

> Every agent's model is one line of configuration.
> Default is Claude on Amazon Bedrock. Change the line, restart, same agents, same session.
> Strands makes the model a setting. We run the same eval on every provider before we trust it.

### 11. Phone kid mode, or TV if built. 3:35 to 3:41

On screen, phone version: phone in kid mode, one question turn on the small screen, then the parent-gated exit (PIN). TV version, if the stretch landed: TV home with D-pad focus, a pick-it answered with the remote's left, centre, right.

Record: SCR or CAM.

Voice-over, phone:

> Same loop on a phone. Leaving kid mode needs the parent's PIN.

Voice-over, TV:

> On the TV, the remote is the whole interface. Left, centre, right answers a pick-it. The mic button answers everything else.

### 12. Nightly digest and Progress. 3:41 to 4:03

On screen: parent's phone. Notification arrives. Open it. Two cards: Lisa's (words said, words heard, try today) and Rayan's (understood, shaky, ask at dinner). Scroll slowly.

Record: SCR (phone), CAM of the phone in hand for the first second.

Voice-over:

> At night the Digest agent reads the day's sessions and writes two lines per child.
> For Lisa: the words they said, the words they heard but did not say yet, and one thing to try tomorrow.
> For Rayan: what they understood, what was shaky, and one question for dinner.
> The Digest also decides whether anything else deserves a notification. Tonight, nothing did.

### 13. Architecture. 4:03 to 4:22

On screen: `docs/architecture.png`. Optionally zoom on the agents panel, then the provider layer, then the deployment box.

Record: SLIDE.

Voice-over:

> Seven Strands agents behind a FastAPI gateway. Curator screens, Planner writes the questions, Buddy runs the session, Explainer answers the parent, Digest reports, Reviewer reads a channel, Coach drafts for the parent only.
> Only three of them get tools. Everything else is plain Python the gateway calls, because the guarantees a parent is trusting belong in code, not in a prompt.
> Bedrock by default, any provider by one environment variable. DynamoDB in production.
> One Flutter codebase for phone, tablet and web.

If TV is not built, add:

> The TV layout is the next milestone. It is a new layout on the same codebase, not a new app.

### 14. Impact and honesty. 4:22 to 4:41

On screen: SLIDE with four lines: "Ads still play. Creators still get paid." / "Official YouTube embed, nothing overlaid or downloaded." / "Nothing a child says is stored." / "Every household with a screen and a child. Bilingual from day one." Then a second SLIDE: "Not built yet: TV layout, subscription import, sibling mode, AgentCore Memory." Adjust to what shipped.

Record: SLIDE.

Voice-over:

> Ads still play. Creators still get paid. Nothing violates YouTube's terms.
> Nothing a child says is stored. Only a score and a ten-word paraphrase.
> This works for every household with a screen and a child, in two languages from day one.
> Not built yet: the TV layout, subscription import, and sibling mode.

### 15. Close. 4:41 to 4:51

On screen: SLIDE with repo URL, live demo or APK link, two builder.aws post titles, "Built on Strands Agents SDK and Amazon Bedrock for Agents for Humans".

Record: SLIDE.

Voice-over:

> HeyGilli. Repo, test build, and two write-ups on builder.aws in the description.

---

## Recording checklist

Before the child sessions

- [ ] Pre-ingest the three demo videos so plans are cached and no turn waits on a model call for the plan.
- [ ] Charge tablet, phone, and camera. Airplane mode off, Do Not Disturb on for both devices except the parent phone during beats 3 and 10.
- [ ] Tablet in screen pinning. Volume at 70 percent so Gilli is audible on the camera mic.
- [ ] `scrcpy --record tablet-take1.mp4` running on the Mac for every child take. Backup footage for every turn.
- [ ] Quiet room. TV and fans off. Child speech is hard enough for the recogniser.
- [ ] Parent's written consent for the child's voice; decide whether faces are in frame. Hands and tablet only is fine.
- [ ] Two or three takes on different days. Do not push a tired child for a fourth.

Before the terminal beats

- [ ] Terminal font 18 pt or larger, dark theme, window 1280 x 720.
- [ ] Trace output trimmed to tool names and a one-line result each. No raw JSON dumps longer than the screen.
- [ ] Scripted commands in a file so nothing is typed live: run Curator, show `.env`, edit one line, restart gateway.
- [ ] Redact keys. `ANTHROPIC_API_KEY` and any AWS variables must not appear on screen. Show `.env` through `grep HEYGILLI_MODEL .env`.

Before the edit

- [ ] Check every clip against the protocol order: pause, ask, answer, reply, resume. Cut any take where the order broke.
- [ ] English subtitles on the Urdu beat. Captions on all voice-over for accessibility.
- [ ] Total under 5:00 including the title card. Aim for 4:45.
- [ ] Export 1080p, 30 fps. Upload to YouTube as public, not unlisted. Title: "HeyGilli: an AI co-watching buddy for kids' YouTube (Agents for Humans hackathon)".
- [ ] Description: repo link, test build link, builder.aws links, one line on what is not built yet.
- [ ] Watch it once on a phone with the sound low. If Gilli cannot be heard in beat 4, re-record the voice from the `scrcpy` audio track.

Fallbacks

- [ ] No 9 to 11 year old available: record beat 6 with screen capture and an adult voice, and caption it honestly.
- [ ] Provider swap fails on camera: keep the beat as a screen recording of a working swap from an earlier day, and say "recorded earlier".
- [ ] Borderline-video push fails: show the `ask_parent` entry in the `/parent/inbox` response in the terminal and the phone inbox screen instead of a push notification.
