# Devpost submission text: HeyGilli

Copy each block into the matching Devpost field. Hackathon: Agents for Humans (AWS x Devpost). Track: Everyday Agents. Deadline: Monday 14 September 2026, 5:00 PM PT.

Fill every `[ ]` before submitting. Do not submit with a placeholder left in.

---

## Project name

HeyGilli

## Tagline (60 characters max)

Preferred (59 characters):

> A kids' YouTube buddy that asks by voice and briefs parents

Alternate (58 characters):

> A squirrel who co-watches kids' YouTube and briefs parents

## Track

Everyday Agents

---

## About the project

### Inspiration

Kids aged 4 to 11 watch YouTube for hours, and most of that time is passive. Nobody asks them anything. Parents filter what plays, then feel guilty about the minutes anyway. In our own home the question at dinner is always the same: "What did you watch?" and the answer is always "stuff".

Parental controls solve the wrong problem. They decide what a child can see. They do nothing during the video and nothing after it. We wanted the opposite: leave the catalogue to the parent, and put an agent in the room while the video plays.

The design floor was a 4-year-old. She cannot read, cannot hold a mic button for a sentence, and will not wait more than a few seconds. If the pre-reader path needed text on screen, the design had failed. Everything for older kids adds on top of that.

### What it does

HeyGilli is a kid-safe YouTube front end with a co-watching buddy, Gilli the palm squirrel. Kids call the app by talking to it: "Hey Gilli".

For the child, on a tablet or phone:

- Only parent-approved channels are visible. No search, no recommendations. Videos play in the official YouTube embed, so ads still play and creators still get paid.
- Every few minutes, at a natural break, the video pauses and Gilli asks a question by voice about what just happened.
- A 4-year-old answers with one word into a big mic button, or by tapping one of three pictures. Gilli always models the answer word, whatever the child said. Silence is a teaching moment, not a failure.
- A 9-year-old answers in a sentence. Gilli builds on the answer and the video resumes. In English or Urdu, and Gilli switches when the child does.
- Three age bands, 4_6, 7_8 and 9_11, set the question types, the listening window, and Gilli's tone.

For the parent, on their phone:

- Add channels by URL. Set a kid profile with a nickname and age. No child PII.
- The agent screens every new upload on those channels in the background. It approves clear cases alone and asks the parent a single yes or no only when a video is borderline.
- At the end of the day, a two-line digest: minutes, videos, what the child understood or which words they said, and one thing to ask at dinner.

Nothing a child says is stored. Only a score and a ten-word paraphrase are kept.

### How we built it

All agent logic is in Python on the Strands Agents SDK. There are four agents, each a Strands `Agent` with a system prompt, a model, and a small set of plain Python tools decorated with `@tool`.

- **Curator** runs on a schedule and on channel add. Tools: `youtube_uploads` (channel RSS plus oEmbed, no API quota), `get_transcript`, `screen_video`, `notify_parent`. It decides approve, hide, or ask the parent.
- **Planner** is called by Curator for each approved video, once per age band. Tools: `get_transcript`, `icon_lookup`, `save_plan`. It returns a `QuestionPlan` as structured output (Pydantic): timestamps at scene or sentence breaks, question type, input mode (voice, pick, or copy), expected answer and variants, the model-the-answer line, and for pick-it questions three icon ids from a fixed kid-safe library.
- **Buddy** runs live, one instance per session, driven over a WebSocket from the FastAPI gateway. Tools: `score_answer` (deterministic for pick-it, model for voice), `tts`, `session_log`, `switch_mode`. It adapts mid-session: after two silent answers from a pre-reader it switches the remaining questions to pick-it.
- **Digest** runs nightly per kid. Tools: `read_sessions`, `read_memory`, `notify_parent`. It writes the digest and decides whether anything deserves a notification at all.

Curator to Planner is a Strands **Graph** with deterministic edges; Planner fans out per band. Buddy and Digest run standalone. We did not use a Swarm because nothing here needs model-driven handoffs, and deterministic edges are easier to test and to explain.

The model is a setting. Each agent reads `HEYGILLI_MODEL_<ROLE>=<provider>:<model id>` from configuration. Default is Amazon Bedrock in us-east-1 (Claude Sonnet for Curator and Digest, Claude Opus for Planner, Claude Haiku for Buddy where a child is waiting). Anthropic direct, OpenAI, and Ollama are alternates, one line each, same code, same eval.

Around the agents: a FastAPI gateway (REST for auth, kids, channels, home rows, inbox, digest; one WebSocket per session), Amazon Polly for Gilli's voice with a cache, on-device Android speech recognition through Flutter's `speech_to_text`, local JSON storage for development and DynamoDB for deployment. The client is one Flutter codebase for phone and tablet, with a Google TV layout as the next milestone. Deployment on Amazon Bedrock AgentCore Runtime, with agents in-process on App Runner as the fallback. [ ] Update this sentence with what actually shipped: AgentCore Runtime, App Runner, or local only.

### Challenges we ran into

**Child speech recognition.** Recognisers are trained on adults. Four-year-olds whisper, mumble, and say "gaffe" for giraffe. We stopped scoring the transcript literally. The backend scores phonetically against the expected word and its variants; any utterance that shares a first sound or a syllable counts as partial, and partial is treated as success for pre-readers. Copy-it questions ("roar like him") are never scored at all. After two empty results the Buddy switches to pick-it, which needs no speech.

**Reading a YouTube video we do not own.** The Data API's caption download only works for the caller's own videos. We put the problem inside one tool, `get_transcript`, with two paths: the public caption track, and a video-understanding model that accepts a YouTube URL (Gemini). The agents never know which path ran. A Bedrock-only build uses captions.

**A user who cannot read.** Every message to the client for band 4_6 omits text entirely. The question is voice, the answer is voice or a tap, and the feedback is Gilli saying the word once with a matching gesture. The pick-it pictures come from a fixed library of kid-safe icons keyed by concept, not generated per video, so they render instantly and never need a safety review.

### Accomplishments that we're proud of

- A complete loop, parent setup to kid session to digest, on a real tablet, in two age bands and two languages. [ ] Confirm what was recorded.
- The Curator deciding alone and pinging the parent exactly once, on camera.
- The same session turn running on Bedrock and then on a second provider after a one-line config change.
- A pre-reader path with no text on screen that a real 4-year-old could use. [ ] Confirm from testing.
- Playing by YouTube's rules throughout: official embed, ads untouched, no overlays, no downloads.

### What we learned

- Strands makes the model a constructor argument, so "provider-flexible" cost us a config loader and an eval, not an abstraction layer.
- A Graph with deterministic edges is the right shape when you can name the steps in advance. Save Swarms for problems where the route is unknown.
- For pre-readers the learning event is the buddy saying the word, not the child getting it right. Once we accepted that, scoring got simpler and kinder.
- Latency is a product feature when a child is waiting. The gateway keeps the Buddy agent warm for the whole session, the fastest model does live replies, and TTS is cached.
- [ ] Add one concrete finding from the child tests, with the number.

### What's next

- Google TV layout with D-pad focus and remote mic, from the same Flutter codebase. The product vision is TV-first; the nine-day build was tablet-first.
- AgentCore Memory for per-kid preferences, so Gilli can say "you liked the giraffe yesterday".
- Import the parent's own YouTube subscriptions; curated starter packs by age and language.
- Sibling mode on a shared screen, questions pitched to whoever answers.
- iOS and iPad via the same codebase; Play "Designed for Families" review.

---

## Built with

Copy as tags:

`strands-agents` `python` `fastapi` `websockets` `pydantic` `amazon-bedrock` `anthropic-claude` `amazon-polly` `amazon-dynamodb` `aws-agentcore` `amazon-eventbridge` `aws-app-runner` `flutter` `dart` `android` `youtube-iframe-api` `speech-to-text` `gemini-api` `uv` `ruff`

Remove any tag for a service that did not ship (for example `aws-agentcore` or `amazon-dynamodb` if the demo runs on local JSON).

---

## Links

| Field | Value | Status |
|---|---|---|
| Public repo | https://github.com/mujahidmasood/heygilli | [ ] flipped to public |
| Demo video (YouTube, public, 5:00 max) | [ ] URL | [ ] uploaded |
| Live demo or test build | [ ] APK link or gateway URL | [ ] tested from a clean device |
| builder.aws post 1 | [ ] URL | [ ] title contains "Agents for Humans" |
| builder.aws post 2 | [ ] URL | [ ] title contains "Agents for Humans" |
| AWS Builder ID | [ ] | [ ] created |

## Testing instructions (Devpost field)

Suggested text. Adjust to what shipped.

> Clone the repo and follow README "Run the agents locally" and "Run the app". A test APK for Android 12+ is attached at [ ] link. The gateway for the test build is at [ ] URL and needs no login; `POST /auth/dev` returns a token. Seed data (one kid, five channels, three pre-ingested videos) loads with `make seed` [ ] confirm the command. The full click path is in `docs/demo-runbook.md`.

## Third-party integrations disclosure (Devpost field)

> HeyGilli plays videos through the official YouTube IFrame Player API in an embedded player. Ads are untouched, nothing is downloaded or overlaid, and only public videos from channels the parent added are shown. New uploads are discovered through public channel RSS feeds and oEmbed. The optional `get_transcript` tool can call the Google Gemini API with a public YouTube URL under Google's API terms; a captions-only path is available for a Bedrock-only build. Speech recognition uses the Android on-device recogniser via the Flutter `speech_to_text` plugin; audio is processed and discarded, nothing a child says is stored. Gilli's voice is Amazon Polly. Models run on Amazon Bedrock by default, with Anthropic, OpenAI, and Ollama as configurable alternates.

## Pre-existing work disclosure (rules: new projects only)

> All code was written during the submission period, starting 5 September 2026. The product spec and design mockups predate the code by hours, not weeks, and contain no code. Standard tools were used: Strands Agents SDK, FastAPI, Flutter, the `youtube_player_iframe` and `speech_to_text` packages, and AI coding assistants.

---

## Required items checklist (from the rules page, read 5 Sep 2026)

| Requirement | Rule text (short) | Status |
|---|---|---|
| Built with Strands Agents SDK | Agent must be built with Strands and handle real work end to end | [ ] four agents in `agents/` |
| New project | Newly created during 10 Aug to 14 Sep 2026; disclose pre-existing code | [ ] disclosure text above |
| Public repo | Public URL on GitHub, GitLab, or Bitbucket | [ ] `gh repo edit ... --visibility public` |
| Open source license | MIT or Apache, included and visible | Done, `LICENSE` is MIT |
| README | Present, with setup instructions | [ ] final pass |
| Architecture diagram | Present | Done, `docs/architecture.svg` and `.png` |
| Text description | Explains features and functionality | This file, "About the project" |
| Demo video | Max 5 minutes; working project plus pitch (problem, audience, why it matters); YouTube or Vimeo, public | [ ] |
| Testing access | Link to a website, functioning demo, or test build; credentials if private | [ ] APK or live URL |
| AWS Builder ID | Required field | [ ] |
| Third-party disclosure | Authorised to use every third-party SDK, API, or data | Text above |
| Language | All materials in English or with English translation | Done; Urdu appears only inside the demo, described in English |
| Live demo link | Optional, helps Technical Implementation | [ ] if AgentCore or App Runner holds |
| builder.aws posts | Optional, up to three, 0.2 points each, published before the deadline, "Agents for Humans" in the title | [ ] post 1, [ ] post 2 |
| AWS credits form | Optional, $50, closes 11 September 12:00 PM PT | [ ] |
