# Agents for Humans: teaching a squirrel to co-watch, or designing four Strands agents for a user who cannot read

*Draft for builder.aws.com. The rules require "Agents for Humans" in the title, so keep the prefix. Publish before 14 September 2026, 5:00 PM PT. Replace every `[TBD from testing]` with a real number or delete the sentence.*

---

Most agent demos assume a user who can read a screen and type a reply. Our user is four. She cannot read, cannot hold a microphone button for a sentence, and will not wait more than a few seconds. That constraint shaped every decision in HeyGilli, an AI co-watching buddy for kids' YouTube, built on the Strands Agents SDK for the Agents for Humans hackathon.

The product in one paragraph: kids aged 4 to 11 watch YouTube for hours, and parental controls decide what plays and then do nothing. HeyGilli shows only parent-approved channels in the official YouTube embed and adds Gilli the palm squirrel, who pauses the video every few minutes to ask a question by voice. The child speaks or taps, Gilli replies, the video resumes. At night the parent gets a two-line digest. Ads still play, and nothing a child says is stored.

This post covers the agent design: the four agents, why a Graph and not a Swarm, how the model became a setting, and what the agent may show the parent.

## Four agents, four jobs

We resisted one "assistant" agent with twenty tools. Each agent has one trigger, one output type, and a tool set short enough to list.

**Curator** runs every six hours per household and when a parent adds a channel. Tools: `youtube_uploads` (channel RSS plus oEmbed, no API quota), `get_transcript`, `screen_video`, `notify_parent`. Output: approve, hide, or ask the parent, per new video. It decides alone on clear cases.

**Planner** is called by Curator for each approved video, once per age band. Tools: `get_transcript`, `icon_lookup`, `save_plan`. Output: a `QuestionPlan`, a Pydantic model via Strands structured output. Each question has a timestamp at a scene or sentence break, a type, an input mode (voice, pick, or copy), the expected answer and variants, the line Gilli says to model the answer, a gesture id, and for pick-it three icon ids from a fixed library.

**Buddy** is the live agent: one instance per session, kept warm by the gateway and driven over a WebSocket. Tools: `score_answer`, `tts`, `session_log`, `switch_mode`. It emits `ask`, `reply`, and `resume` and adapts mid-session. If a pre-reader's mic returns nothing twice, it switches the remaining questions to pick-it, which scores deterministically with no model call.

**Digest** runs nightly per kid. Tools: `read_sessions`, `read_memory`, `notify_parent`. It writes the digest as structured output and decides whether anything deserves a notification. Most nights the answer is no, and that is a feature.

Each agent is a Strands `Agent` with a frozen system prompt per band, a model, and plain Python functions with the `@tool` decorator. There is no framework of our own on top of Strands. The SDK's tracing gives us every tool call, which is what scrolls past in the demo video.

## Why a Graph and not a Swarm

Strands offers several multi-agent patterns. We used exactly one: Curator to Planner is a **Graph** with deterministic edges, and Planner fans out per age band. Buddy and Digest run standalone.

We can name every step in advance. A new upload is screened, then planned, then saved. No model needs to decide who works next. A Swarm, where agents hand off by judgement, is the right tool when the route is unknown. Here it would add latency, make failures harder to reproduce, and make the demo harder to explain in twenty seconds. Deterministic edges also let us cache: a plan is generated once per video per band and reused for every child.

The one place the model routes is inside Buddy, and narrowly: score this answer, pick a reply register, decide whether to switch to pick-it. That is a judgement about one child in one moment, which is what a model is for.

## The model is a setting

Strands is model-agnostic. The provider is a constructor argument on the agent. We leaned on that on purpose. Every agent reads its model from one environment variable:

```
HEYGILLI_MODEL_CURATOR=bedrock:us.anthropic.claude-sonnet-4-6
HEYGILLI_MODEL_PLANNER=bedrock:us.anthropic.claude-opus-4-8
HEYGILLI_MODEL_BUDDY=bedrock:us.anthropic.claude-haiku-4-5-20251001-v1:0
HEYGILLI_MODEL_DIGEST=bedrock:us.anthropic.claude-sonnet-4-6
```

A small loader parses `provider:model_id` and returns a `BedrockModel`, `AnthropicModel`, `OpenAIModel`, or `OllamaModel`. An unknown provider raises, so a typo fails fast. Amazon Bedrock is the default: the fastest Claude on the live path because a child is waiting, the strongest on the Planner because a plan is generated once and cached.

Two rules make "flexible" a fact rather than a claim. First, the client never parses free text: plans, scores, and digests are structured output on every provider. Second, every provider must pass the same eval before we trust it: [TBD from testing] transcripts across three bands and two languages, checked against band rules (no "why" questions under age 7, pick-it options clearly distinct, timing table respected), plus [TBD from testing] recorded child answers scored against a human label. In the demo we change one line, restart, and the same session turn runs on a second provider.

The loader is under sixty lines. The eval is the real work.

## What the agent is allowed to show the parent

The hackathon brief says agents should run in the background and surface only when there is a real decision for a human. We wrote the list down.

The agent acts alone when it screens a clear upload, generates a plan, runs a session end to end, adapts a session to pick-it, writes the digest, and notices which channels never get watched. It surfaces to the parent only when an upload is borderline and needs a yes or no, when a child has been stuck on one concept across three sessions, and when the daily time budget is about to end mid-video.

So the parent's phone shows two things: one prompt from Curator, "New from Blippi: 'Trip to the candy factory'. Sugar-heavy. Fine for Zara?" with Yes and Hide, and one nightly card from Digest. Everything else stays inside the agents.

## What we would do differently

Write the eval on day one, before the second agent; we spent [TBD from testing] hours tuning prompts by eye that a test set would have caught in minutes. Start AgentCore Runtime earlier; we set a hard stop and a fallback (agents in-process on App Runner, identical Strands code), and [TBD: say which one shipped].

The companion post, "Agents for Humans: child speech is the hard part", covers the pre-reader path, phonetic scoring, and what a real four-year-old did to our assumptions.

Code: https://github.com/mujahidmasood/heygilli. MIT.
