# Devpost submission text: HeyGilli

Copy each block into the matching Devpost field. Hackathon: Agents for Humans (AWS x Devpost). Track: Everyday Agents. Deadline: Monday 14 September 2026, 5:00 PM PT.

Rewritten 10 September to match what shipped. Items only the author can supply are listed under "Still needed" at the end.

---

## Project name

HeyGilli

## Tagline (60 characters max)

> A kids' YouTube buddy that asks by voice and briefs parents

(59 characters.)

## Track

Everyday Agents

---

## About the project

### Inspiration

Children aged 5 to 12 watch YouTube for hours, and most of that time is passive. Nobody asks them anything. Parents filter what plays, then feel guilty about the minutes anyway. At dinner the question is always "What did you watch?" and the answer is always "stuff".

Parental controls solve the wrong problem. They decide what a child can see, and do nothing during the video or after it. We wanted the opposite: an agent that does the tedious part, reading every new upload against what this family actually wants, and then sits in the room while the video plays.

The design floor was a 5-year-old who cannot read. If the youngest band needed text on screen, the design had failed. Everything for older children adds on top of that.

### What it does

HeyGilli is a kid-safe YouTube front end with a co-watching buddy, Gilli the squirrel.

**For the parent**, the agent does the busywork and asks only when there is a real decision:

- **Setup is a short questionnaire.** What the child may watch (a handful of questions about what is fine in this house, drawn from their own channels, each skippable), then what they like and what Gilli should suggest at a break. No channel lists to vouch for sight unseen.
- **Every upload is screened in the background** against those answers. The Curator approves clear cases alone, keeps back what breaks the safety rules, and asks the parent only about borderline videos. The review screen shows each verdict as skimmable tags, split into Shown and Hidden, with the reason one tap away.
- **Check before you allow.** A parent who finds a video or channel themselves pastes the link and Gilli reads it against their answers first, then they can allow just that video or add the channel. Three checks a day per household.
- **Ask about any video.** "Is the dog hurt in it?" is answered from the video's own transcript, and says so when it cannot tell.
- **A daily digest** in two lines: minutes, videos, which words a pre-reader said or what an older child understood, and one thing to ask at dinner. A Progress screen shows the week.
- Daily limits, breaks with an activity the parent chose, a parent PIN to leave kid mode, and a card when an approved channel starts publishing something different. HeyGilli never removes a channel on its own.
- **See what the agents did.** Every agent call is traced in full, every answer passes guardrails before anyone sees it, and a report lists what was caught and what was fixed.

**For the child**, on a phone, tablet or browser:

- Only videos the parent's rules allowed, and no recommendations. A child can search, by typing or by voice, but only among those videos; search never reaches YouTube. Videos play in the official YouTube embed, so ads still play and creators still get paid.
- The shelf is laid out like YouTube Kids: a section per channel for a child who reads, and one big grid of pictures, each with its title, for a child who does not yet.
- At a natural break the video pauses and Gilli asks one question by voice about what just happened. Two or three a video, sized to its length.
- A 5-year-old answers with one word, by tapping one of three pictures, or yes or no. The questions need no reading: Gilli asks aloud, and always says the answer word back.
- A 10-year-old answers in a sentence. Gilli builds on the answer and the video resumes. English or Urdu.
- Three age bands (5 to 6, 7 to 8, 9 to 12) set the question types, the listening window and Gilli's tone.
- Between videos Gilli naps on the shelf. A pinch wakes him: a tap, a click, or two fingers squeezed together. The games have their own button: find Gilli hiding behind one of the trees, or catch him as he pops up. The Playmate agent makes each round a little harder or easier from how the last one went, and the games follow the same limits as videos.

Nothing a child says is stored. Only a score and a ten-word paraphrase are kept.

### How we built it

All agent logic is Python on the **Strands Agents SDK**. There are eight agents, each a Strands `Agent` with a frozen system prompt, its own model setting, its own `@tool` list, and a Pydantic output schema it must fill in. The repo has twelve `@tool` functions; five are handed to agents, and the rest are called directly by the gateway as the plain functions they still are. No agent returns free text: every call goes through `structured()`, which asks Strands for `structured_output` and validates the object before anything uses it.

- **Curator**: screens each new upload against the household's answers and the safety rules. `@tool`: `screen_video`. Structured output `CuratorDecision`: approve, hide or ask the parent, with short topic and concern tags.
- **Planner**: writes the questions for each approved video, per age band and language, as a Pydantic `QuestionPlan`. `@tool`: `icon_lookup`, `list_icons`, so a picture question can only name an icon that exists. Band and timing rules are enforced in code afterwards.
- **Buddy**: runs live, one per session over a WebSocket; scores the answer, writes Gilli's reply, and adapts mid-session.
- **Digest**: writes the nightly parent digest and decides whether anything deserves a notification.
- **Reviewer**: describes what a channel actually publishes, from its feed; also notices when an approved channel drifts. `@tool`: `screen_video`.
- **Coach**: drafts household questions and break lines **for the parent**. Nothing it writes reaches a child until the parent saves it.
- **Explainer**: answers a parent's question about one video from its transcript. `@tool`: `search_transcript`, `channel_reputation`, `screen_video` — the agent chooses what evidence it needs, and `search_transcript` returns `searched_whole_video` so it knows when "not found" can be trusted.
- **Playmate**: runs Gilli's two games. After each round it decides how hard the next one should be for this child and what Gilli says; the code clamps the numbers per age band, picks where Gilli hides, checks the line, and caps a game at five rounds.

The agents decide; plain code fetches and enforces. An agent gets a tool where a judgement needs evidence it should go and fetch — the Explainer deciding to search a transcript, the Planner checking an icon exists. Fetching uploads, Polly speech and the length and safety rules stay ordinary functions the gateway calls, because nothing about them is the model's to decide. A `@tool` is still a plain function, so `screen_video` has two callers: the agent that may reason about it, and the pipeline that always runs it. The Curator-to-Planner hand-off is a typed Python pipeline rather than a Strands Graph, so the Planner never re-parses the Curator's prose and every plan passes the same rule check.

**Every agent call is traced, checked and audited.** All eight agents go through one function, and three things happen there:

- **Full traces.** Each call is a root OpenTelemetry span that Strands' own spans nest under: the agent, each model call with its prompt, answer and token counts, each tool call. The trace is stored with the household's data and can go to any OTLP collector. What a child said is replaced before anything is written.
- **Guardrails.** Every answer is checked before it is used. Nothing a child hears may contain unsafe words, links or a question about the child; Gilli never says "wrong"; the Curator cannot approve a video whose own title trips a safety rule; the digest cannot claim a child heard a word no question used. A blocked answer goes back to the agent once, saying what was wrong, and a second one falls back to the safe built-in.
- **Report and fix.** Every call is an event and every violation an incident. After each screening an audit looks back over what the agents already did: it hides approvals that break a safety rule, sends back to the parent the ones that should have been asked about, drops cached questions a child must not hear, and reports any agent whose answers keep ending in the fallback. It never overrules a parent.

The model is a setting: each agent reads `HEYGILLI_MODEL_<ROLE>=<provider>:<model id>`. Production runs on **Amazon Bedrock** (Amazon Nova Pro while Anthropic access on the account is pending); Anthropic, OpenAI and Ollama are one-line alternates with the same code. Every feature falls back to a deterministic built-in when a model call fails.

Around the agents: a **FastAPI** gateway on Render (REST plus one WebSocket per session), **Amazon DynamoDB** for storage, **Amazon Polly** for Gilli's voice, public captions and **Gemini** for reading a YouTube video we do not own, and on-device speech recognition. The client is one **Flutter** codebase that builds for web, Android and iOS; the web build is live at heygilli.com/app.

### Challenges we ran into

**Reading a video we do not own.** YouTube's caption download works only for your own videos, and from a datacenter address the public captions are often refused. Everything goes through one function with a proxy for captions and a video-understanding model as the second path. When neither works, the video is read on its title and description and the parent is told so ("title only") rather than shown a verdict that pretends otherwise.

**A preference is not a safety rule.** A channel's topics are the channel's, not each video's: a science channel posts a birthday message, an educational one posts quote compilations. The Curator checks each upload against what the family said they like, but it hides only for the safety rules; a video that merely misses the family's topics goes to the parent as a question, never hidden for that alone.

**Child speech.** Recognisers are trained on adults. A 5-year-old whispers, mumbles and says "gaffe" for giraffe. The backend scores against the expected word and its variants, partial counts as success for pre-readers, and after two silent turns the questions switch to pictures, which need no speech.

**Trusting an agent after the fact.** A prompt that says "never say wrong" is a request, not a guarantee. Checking every answer in code, sending a bad one back once with the reason, and then auditing what was already done turned "the model usually behaves" into something we can show: each call's full trace, what was caught, and what was fixed.

**A user who cannot read.** Every message to the youngest band omits text entirely. The question is voice, the answer is voice or a tap, and the feedback is Gilli saying the word with a gesture. The pictures come from a fixed library of kid-safe icons, so nothing is generated per video and nothing needs a safety review.

### Accomplishments that we're proud of

- A working loop, deployed: parent setup, background screening, kid session with voice questions, and the digest, live at heygilli.com.
- The agent pings the parent only when a decision is genuinely theirs; everything else it settles alone and shows its reasons.
- A question path for pre-readers that needs no reading: Gilli asks aloud, and they tap a picture or say one word.
- Playing by YouTube's rules throughout: official embed, ads untouched, no overlays during playback, no downloads.
- 685 backend tests and 622 client tests, offline.

### What we learned

- Strands makes the model a constructor argument, so "provider-flexible" cost us a config loader, not an abstraction layer. That mattered when the account's Anthropic access was still pending.
- Letting the agent decide and letting code enforce is what makes an agent trustworthy with children: the model makes the judgement call, and the rules it cannot break are code.
- For pre-readers, the learning moment is the buddy saying the word, not the child getting it right. Once we accepted that, scoring got simpler and kinder.
- Latency is a product feature when a child is waiting: the Buddy stays warm for the session and speech is cached.

### What's next

- Anthropic models on Bedrock once access is granted, and AgentCore Runtime for the agents.
- iOS on the App Store; a Google TV layout from the same Flutter codebase.
- Sibling mode on a shared screen, with questions pitched to whoever answers.

---

## Built with

`strands-agents` `opentelemetry` `python` `fastapi` `websockets` `pydantic` `amazon-bedrock` `amazon-nova` `amazon-polly` `amazon-dynamodb` `flutter` `dart` `youtube-iframe-api` `gemini-api` `render` `cloudflare-pages`

---

## Links

| Field | Value |
|---|---|
| Live demo | https://heygilli.com |
| Try the screening, no login | https://heygilli.com/try |
| Web app | https://heygilli.com/app/ |
| Repo | https://github.com/mujahidmasood/heygilli (must be public before submitting) |
| Demo video | https://youtu.be/7pqNpfnOi2c (4:56; set to Public before submitting, currently Unlisted) |
| builder.aws post 1 | https://builder.aws.com/content/3J9lT0BiJ7M7ZwYqX6EbldIShrC/agents-for-humans-building-heygilli-part-1-the-concept-and-the-requirements |
| builder.aws post 2 | https://builder.aws.com/content/3J9lmlk9RcHyUqdhf08wPp8ZsGZ/agents-for-humans-building-heygilli-part-2-designing-eight-agents-with-strands |
| builder.aws post 3 | still needed |
| AWS Builder ID | @innovpk |

## Testing instructions (Devpost field)

> **No login:** https://heygilli.com/try shows the Curator's verdicts on three real uploads.
>
> **The app:** open https://heygilli.com/app/ and choose **Set up without Google**. It creates a household with no account. Add a child (pick an age from 5 to 12), answer or skip the questions, then tap **Find videos**. The screening runs on the server and videos appear within a few minutes on the review screen. Allow some, then **Enter kid mode** to watch with Gilli; allow the microphone when the browser asks. The first request can take about 30 seconds while the free-tier server wakes up.
>
> **From source:** clone the repo and follow the README ("Run it").

## Third-party integrations disclosure (Devpost field)

> HeyGilli plays videos through the official YouTube IFrame Player API in an embedded player. Ads are untouched, nothing is downloaded, and nothing is drawn over a playing video. New uploads are discovered through public channel RSS feeds and oEmbed; a parent's channel search and video lengths use the YouTube Data API under Google's terms. Transcripts come from public captions or the Google Gemini API given a public YouTube URL. Speech recognition runs on the device; nothing a child says is stored. Gilli's voice is Amazon Polly. Models run on Amazon Bedrock. Google Sign-In is optional for parents.

## Pre-existing work disclosure

> All code was written during the submission period, starting 5 September 2026. The product spec and design mockups predate the code by hours and contain no code. Standard libraries were used: Strands Agents SDK, FastAPI, Flutter, `youtube_player_iframe`, `speech_to_text`, and AI coding assistants.

---

## Still needed before submitting

| Item | Owner |
|---|---|
| Demo video: uploaded, 4:56, https://youtu.be/7pqNpfnOi2c. Still Unlisted; switch to Public before submitting | author |
| AWS Builder ID: @innovpk | done |
| Teammates: Unzila Zafar (@unzila15) and Aida Valiyeva (@aidavaliyeva) are on the submission, checked 11 September | done |
| Repo public. The ad clip is out of the code and off heygilli.com; it remains only in the history of two early commits | author |
| README Status section updated (test counts, the Gemini path now exists) | can be done now |
| builder.aws post 3 (optional bonus), "Agents for Humans" in the title, published before the deadline. Parts 1 and 2 are up: https://builder.aws.com/content/3J9lT0BiJ7M7ZwYqX6EbldIShrC/agents-for-humans-building-heygilli-part-1-the-concept-and-the-requirements and https://builder.aws.com/content/3J9lmlk9RcHyUqdhf08wPp8ZsGZ/agents-for-humans-building-heygilli-part-2-designing-eight-agents-with-strands | author |
