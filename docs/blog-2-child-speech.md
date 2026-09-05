# Agents for Humans: child speech is the hard part

*Draft for builder.aws.com. The rules require "Agents for Humans" in the title, so keep the prefix. Publish before 14 September 2026, 5:00 PM PT. Replace every `[TBD from testing]` with a real number from the child tests, or delete the sentence. No number in this post may be invented.*

---

Speech recognisers are trained mostly on adults. A four-year-old whispers, mumbles, drops syllables, says "gaffe" for giraffe, and sometimes just roars at the tablet because that is what the question asked for. If your agent depends on a clean transcript from that child, it will fail most of the time.

HeyGilli is an AI co-watching buddy for kids' YouTube, built on the Strands Agents SDK for the Agents for Humans hackathon. Gilli the palm squirrel pauses a video at a natural break and asks a question by voice. Kids aged 4 to 11 use it in three bands: 4_6, 7_8, and 9_11. This post is about the youngest band, because pre-readers set the design floor for everything else.

## Rule zero: no text

A pre-reader cannot read, so the client renders no text for band 4_6. The gateway's `ask` and `reply` messages omit the `text` field for that band; the client has nothing to fall back on. The question is Gilli's voice. The answer is the child's voice or one tap. The feedback is Gilli's voice plus a gesture from a small named set: stretch, shrink, spin, point, roar, think, cheer.

That forced three question types, all about what is on the paused frame or heard in the last thirty seconds. **Name it**: "What animal is that?" **Copy it**: "Can you roar like him?" **Pick it**: three big pictures, "Show me the blue one." No "why" before age 7. No trivia the video did not cover.

## Modelling the answer word

Young children learn words by hearing an adult say the word clearly, right after seeing the thing. Whether the child said it first matters less than we assumed. So Gilli always models the answer, whatever happened:

- Correct: "Yes! A giraffe. It has a looong neck."
- Partial, for example "gaffe": treated as correct. "A giraffe! Gi-raffe."
- Off topic, for example "dog": "A dog? I see a giraffe! Gi-raffe."
- Unclear or silence: "It's a giraffe! Gi-raffe. Can you say giraffe?" Then a three-second pause, then the video resumes whether or not the child repeats.

The learning event is Gilli saying the word once, clearly, with a matching gesture. Silence is a teaching moment, not a failure. Nobody is told they are wrong. This also removed a class of scoring bugs, because the response to a bad recognition result is nearly the same as to a good one.

The digest follows. For pre-readers it is not a comprehension report; it lists the words the child said and the words heard but not yet said. A word moving from the second list to the first over a week is the metric we care about.

## Phonetic scoring instead of transcript matching

The Planner agent writes each question with an expected answer and a list of acceptable variants, in English and Urdu. The Buddy agent's `score_answer` tool then scores the recogniser's output against them. For pre-readers the scoring is phonetic and forgiving: any utterance that shares a first sound or a syllable with the expected word is `partial`, and `partial` is treated as success.

This runs on the backend, not the device: the rules are the same on any speech engine, and thresholds can be tuned from a test set without an app update. Where the engine supports recognition hints, we pass the expected word and variants, which helps [TBD from testing: state the measured effect or remove].

Shy, whispered, and mumbled answers must produce the same experience as confident ones. In our test with a real four-year-old, [TBD from testing: how many name-it turns produced any utterance, and how many scored partial or better]. Test with a real child; an adult imitating one tells you nothing.

Copy-it questions are never scored. Any sound, or none, gets "Great roar!" or "Listen to mine, ROAR!" and the video resumes.

## The pick-it fallback

Some sessions the mic gets nothing: a loud room, a shy child, or no talking mood. If the mic returns nothing twice in one session for a pre-reader, the Buddy agent calls its `switch_mode` tool and the remaining questions become pick-it for that session.

Pick-it needs no speech. Three pictures appear and the child taps one; on the TV layout, the next milestone, it is the remote's left, centre, or right. Any press answers, with no confirm step. Scoring is deterministic and free, with no model call.

The pictures come from a fixed library of kid-safe icons keyed by concept, with English and Urdu labels, bundled in the app. The Planner picks icon ids only from that list, so there is no latency and no generated-image safety review. The two wrong options are always clearly different from the right one: a giraffe, a fish, a car, never a giraffe and a zebra. The library has 56 concepts today, enough for the demo videos; adding one is a row and an SVG.

## Timing for the impatient

A four-year-old will not wait. Band 4_6 rules: first question no earlier than two minutes in, at least four minutes between questions, one question for a video under five minutes and two above, a five-second listening window instead of eight. Frequency is locked to gentle. Gilli also starts listening automatically after the question, so a child who just talks at the tablet is still heard.

## What we learned

- Design for the child who says nothing. If the silent path is good, the talking path is easy.
- Score the concept, not the transcript. Phonetic partial matches and a generous definition of success remove most of the pain.
- Give the agent a non-speech path and let it switch on its own. Adapting inside the session is where a live agent earns its keep.
- Fixed assets beat generated ones for pre-readers: instant, safe, reviewable.
- [TBD from testing: one concrete surprise from the child sessions, with the number.]

The companion post, "Agents for Humans: teaching a squirrel to co-watch", covers the four Strands agents, the Graph, and the one-line provider swap.

Code: https://github.com/mujahidmasood/heygilli. MIT.
