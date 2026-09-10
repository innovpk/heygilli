# Agents for Humans: child speech is the hard part

Speech recognisers are trained mostly on adults. A four-year-old whispers, mumbles, drops syllables, says "gaffe" for giraffe, and sometimes just roars at the tablet because that is what the question asked for. If your agent depends on a clean transcript from that child, it will fail most of the time.

HeyGilli is an AI co-watching buddy for kids' YouTube, built on the Strands Agents SDK for the Agents for Humans hackathon. Gilli the palm squirrel pauses a video at a natural break and asks a question by voice. Kids aged 4 to 11 use it in three bands: `4_6`, `7_8`, `9_11`. This post is about the youngest band, because pre-readers set the design floor for everything above them.

## Rule zero: no text

A pre-reader cannot read, so the client renders no text for band `4_6`. This is not a styling choice — the gateway omits the field:

```python
text=None if self.band == "4_6" else q.text,  # pre-readers get no text on screen
```

There is nothing to fall back on. The question is Gilli's voice, spoken by Amazon Polly at a slower rate for this band alone. The answer is the child's voice or one tap. The feedback is Gilli's voice plus a gesture from a small named set: `stretch`, `shrink`, `spin`, `point`, `roar`, `think`, `cheer`, with `idle` as the resting state.

That forced four question types for the band, all about what is on the paused frame or was heard in the last thirty seconds. **Name it**: "What animal is that?" **Copy it**: "Can you roar like him?" **Pick it**: three big pictures, "Show me the blue one." **Yes or no**, two cards, when nothing else fits. No "why" before age 7 — the band contract in `rules.enforce` rejects the type outright, so no prompt wording can smuggle one through.

## Modelling the answer word

Young children learn words by hearing an adult say the word clearly, right after seeing the thing. Whether the child said it first matters less than we assumed. So Gilli always models the answer, whatever happened:

- Correct: "Yes! A giraffe. It has a looong neck."
- Partial, for example "gaffe": treated as correct. "A giraffe! Gi-raffe."
- Off topic, for example "dog": "A dog? I see a giraffe! Gi-raffe."
- Unclear or silence: "It's a giraffe! Gi-raffe. Can you say giraffe?" Then a pause, then the video resumes whether or not the child repeats.

The learning event is Gilli saying the word once, clearly, with a matching gesture. Silence is a teaching moment, not a failure. Nobody is told they are wrong. This also removed a whole class of scoring bugs, because the response to a bad recognition result is nearly the same as the response to a good one.

The digest follows the same idea. For pre-readers it is not a comprehension report; it lists the words the child said and the words heard but not yet said. A word moving from the second list to the first over a week is the metric we care about.

## Phonetic scoring instead of transcript matching

The Planner writes each question with an expected answer and a list of acceptable variants, in English and Urdu. The Buddy then scores the recogniser's output against them. For pre-readers the scoring is phonetic and forgiving: an utterance sharing a first sound or a syllable with the expected word scores `partial`, and `partial` is treated as success.

Note what is *not* here: this is not a tool call. Scoring a pre-reader's word is deterministic Python, and it never reaches a model. A model is used only where a child's *sentence* needs judgement, in the older bands. The live path a four-year-old walks has no model call in it at all beyond the reply text, which is why it cannot time out.

Running it on the backend rather than the device means the rules are identical on any speech engine, and thresholds can be tuned from a test set without shipping an app update.

Copy-it questions are never scored. Any sound, or none, gets "Great roar!" or "Listen to mine, ROAR!" and the video resumes.

## The pick-it fallback

Some sessions the mic gets nothing: a loud room, a shy child, or no talking mood. Two empty results in one session for a pre-reader — `PREREADER_MAX_EMPTY = 2` — and every remaining voice question in that session is rewritten as pick-it.

Again, not a tool the model chooses to call. It is a counter and a rewrite in the session object, one-way for the rest of the session, and the child is never told it happened. Adapting inside a session is where a live agent earns its keep, but the adaptation is far more trustworthy as code than as a judgement call.

Pick-it needs no speech. Three pictures appear and the child taps one; on the TV layout, the next milestone, it is the remote's left, centre, or right. Any press answers, with no confirm step. Scoring is deterministic and free.

The pictures come from a fixed library of kid-safe icons keyed by concept, with English and Urdu labels, bundled in the app — 58 concepts today. The Planner may only return icon ids from that list, enforced after the model returns, so there is no latency and no generated-image safety review. The two wrong options are always clearly different from the right one: a giraffe, a fish, a car — never a giraffe and a zebra.

## The same problem, one band up

Everything above assumes the child who will not talk is four. It took a while to notice we had built exactly that trap for the eight-year-olds.

Band `4_6` had three ways to answer from the start — say it, do it, tap it. The reader bands had one. Not by policy: `TYPES_FOR_BAND` simply gave them nothing but spoken types, so a shy child, a tired child, a child eating dinner or sitting in a room with other people met a session with no way in at all. The cards and the icons were sitting there, used only by the youngest.

`pick_it` and `yes_no` are now open to every band. A yes/no is a pick with two cards, so it reuses the same tested path and the same scoring, and its two options are written by `build_yes_no` rather than by the model — which therefore cannot offer three of them, mark both correct, or label them in English for an Urdu household.

The part that mattered more than any of that was where the mixing happens. Transcripts are not reachable from our deployed gateway, so the written question bank *is* the plan for nearly every real session — and it was five spoken prompts per reader band, drawn by a hash that never looked at how they were answered. Measured before the fix: every reader band, three spoken questions in a row. A mix that lived only in the Planner would have been a mix almost nobody met.

There is one more thing a model cannot supply, and it is the parent. They can now write their own question for a video, asked exactly as typed — because no model knows that this child has been asking about volcanoes all week, or that the woman about to appear is the grandmother they call Nani.

## Timing, and the number we got most wrong

Band `4_6`: first question no earlier than two minutes in, at least six minutes between questions at the default gentle frequency, one question for a video under five minutes and two above, and a hard ceiling of two questions however long the video runs.

The listening window is the number we got wrong, and it is the clearest lesson in this post.

It was five seconds for pre-readers and eight for everyone else, measured from the moment Gilli stopped speaking. That is roughly how long an adult takes to answer a question they already know the answer to. A child has to hear it, work out that it is their turn, think, and then say something. Eight seconds in, while they were still on the thinking, the video started playing again.

Being cut off mid-thought teaches a child not to bother, which is the opposite of the entire point of the product.

It is now **15 seconds for pre-readers and 20 for the older bands**. Pre-readers get less not because they are quicker but because they need only one word and will not sit through silence; the older bands are answering "why" and "what do you think", which take longer to say than to know.

Gilli also starts listening automatically after the question, so a child who simply talks at the tablet is heard without pressing anything.

## What we learned

- **Design for the child who says nothing.** If the silent path is good, the talking path is easy. Every fallback in this system runs without a model.
- **Then check you did it for every age.** We designed the silent path carefully for four-year-olds and left the eight-year-olds with nothing but a microphone, for a year, without noticing.
- **Score the concept, not the transcript.** Phonetic partial matches and a generous definition of success remove most of the pain.
- **Put the adaptation in code, not in a prompt.** Switching to pick-it is a counter and a rewrite. It is testable, it is instant, and it cannot decide to do something else today.
- **Fixed assets beat generated ones for pre-readers**: instant, safe, reviewable.
- **Time your silences against a real child.** Our listening window was three times too short, and no amount of adult testing would have shown it. An adult fills a silence. A four-year-old is still deciding whether it is their turn.

Test with a real child. An adult imitating one tells you nothing.

The companion post, "Agents for Humans: teaching a squirrel to co-watch", covers the eight Strands agents, the Graph we deliberately did not build, and what happened when our chosen model turned out to be one we could not call.

Code: https://github.com/mujahidmasood/heygilli. MIT.
