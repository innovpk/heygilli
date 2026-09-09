# Agents for Humans: teaching a squirrel to co-watch, or seven Strands agents for a user who cannot read

*Draft for builder.aws.com. The rules require "Agents for Humans" in the title, so keep the prefix. Publish before 14 September 2026, 5:00 PM PT. Every number in this post comes from a command whose output is in the repo. Do not add one that does not.*

---

Most agent demos assume a user who can read a screen and type a reply. Our user is four. She cannot read, cannot hold a microphone button down for a sentence, and will not wait more than a few seconds. That constraint shaped every decision in HeyGilli, an AI co-watching buddy for kids' YouTube, built on the Strands Agents SDK for the Agents for Humans hackathon.

The product in one paragraph: kids aged 4 to 11 watch YouTube for hours, and parental controls decide what plays and then do nothing else. HeyGilli shows only parent-approved channels in the official YouTube embed and adds Gilli the palm squirrel, who pauses the video every few minutes to ask a question by voice. The child speaks or taps, Gilli replies, the video resumes. At night the parent gets a two-line digest. Ads still play, and nothing a child says is stored.

This post is about the agent design: what the seven agents are, the multi-agent pattern we built and then threw away, and what happened when the model we had chosen turned out to be one we could not call.

## Seven agents, seven jobs

We resisted one "assistant" agent with twenty tools. Each agent has one trigger, one output type, and a tool list short enough to print.

| Agent | Runs | Tools it may call | Decides |
|---|---|---|---|
| Curator | on channel add and on schedule | `screen_video` | approve, hide, or ask the parent |
| Planner | per approved video, per band and language | `icon_lookup`, `list_icons` | a `QuestionPlan` |
| Buddy | live, one per session over a WebSocket | — | scoring, the reply, mid-session adaptation |
| Digest | nightly per kid | — | the parent's note, and whether to notify at all |
| Reviewer | per channel on import | `screen_video` | what a channel actually publishes |
| Coach | when a parent writes a break line or sets policy | — | drafts for the parent; nothing here reaches a child |
| Explainer | when a parent asks about one video | `search_transcript`, `channel_reputation`, `screen_video` | nothing — it answers, it does not rule |

Three of the seven have tools at all. That surprised us. Everything else the pipeline needs — fetching a transcript, listing a channel's uploads, Polly speech, notifying a parent — is a plain Python function the gateway calls in code, not a tool handed to a model.

The split turned out to be the useful one: **the agents decide, the code fetches and enforces.** A model that cannot reach the store cannot corrupt it. A rule that lives in `rules.enforce` can be unit-tested; a rule living in a prompt cannot. We have 567 tests, and almost none of them need a model.

`ROLES` in `models.py` has exactly seven entries, each with its own `HEYGILLI_MODEL_<ROLE>`. Four further prompts reuse a role's model rather than adding an eighth: channel drift runs on `reviewer`, the revisit question on `planner`, the progress note and the watch-history summary on `digest`.

## The Graph we did not build

Our spec sketched Curator → Planner as a Strands `GraphBuilder` graph, and the installed SDK (strands-agents 1.54) has one. We did not use it, and the reason turned out to be worth more than the feature.

Graph nodes hand each other free text. The Planner would have had to re-parse the Curator's prose to learn which video had been approved — reconstructing, badly, a decision that was already a typed object. And the rule enforcement that makes a plan safe for an age band would still have sat outside the graph, because it is code, not a node.

So the hand-off is a typed Python pipeline. The Curator agent makes the judgement call with Strands structured output, code fans out to the Planner agent per (band, language), and every plan passes `rules.enforce` on the way out. Same two agents, deterministic edges, no prose in between, every step reproducible in a test.

The general lesson: reach for a multi-agent topology when you cannot name the next step in advance. We could always name it. What we actually needed was structured output and a function call, and Strands gives you both without a topology.

The one place a model routes is inside Buddy, and narrowly: score this answer, pick a register, decide whether this child has stopped talking. That is a judgement about one child in one moment, which is what a model is for.

## The model is a setting, and we found out the hard way

Strands is model-agnostic; the provider is a constructor argument. Every agent reads `HEYGILLI_MODEL_<ROLE>=<provider>:<model id>`, and a sixty-line loader returns a `BedrockModel`, `AnthropicModel`, `OpenAIModel`, `OllamaModel`, or a fake. An unknown provider raises, so a typo fails fast.

We had picked Claude Sonnet for the Curator, Planner, and Digest, and Claude Haiku for the live path where a child is waiting. `aws bedrock list-inference-profiles` reported every one of them `ACTIVE` in us-east-1, so we wrote them into the config and moved on.

They do not work on our account. Every call comes back:

```
ResourceNotFoundException: Model use case details have not been submitted
for this account. Fill out the Anthropic use case details form before
using the model.
```

The inference-profile listing describes the profile, not your account's entitlement to invoke it. Only an invocation tells you that. Our eval scored **0 of 18 cells** on Sonnet 4.6, **0 of 18** on Haiku 4.5, and **16 of 18** on Amazon Nova Pro, which needs no such form.

This is the entire point of making the model a setting, and it is the only reason our deadline survived: the fix was one environment variable, not a rewrite. Every agent, every prompt, every structured-output schema was already provider-neutral, because the eval had forced it to be from the second agent onward.

Two rules made "flexible" a fact rather than a claim. The client never parses free text — plans, scores, and digests are structured output on every provider. And no provider is trusted until it passes the same eval: three transcripts across three age bands and two languages, eighteen cells, each checked against the band contract (no "why" questions under age 7, pick-it options clearly distinct, the timing table respected) both before and after `rules.enforce` runs.

The loader is under sixty lines. The eval is the real work.

## What the agent is allowed to show the parent

The brief says agents should run in the background and surface only when there is a real decision for a human. We wrote the list down.

The agent acts alone when it screens a clear upload, generates a plan, runs a session end to end, switches a session to pick-it, and writes the digest. It surfaces to the parent when an upload is borderline, when an approved channel has drifted into something else, and when the day's minutes are about to run out mid-video.

One rule shaped more code than any other: **HeyGilli never removes a channel by itself.** A drift raises a card with no Approve and no Hide on it. Removal is a `DELETE` the parent makes. An agent that quietly deletes something a parent chose is an agent a parent stops trusting, and in a product about their child there is no recovering from that.

## What we would do differently

**Invoke the model before believing the console.** Hours went to a config that every listing API said was fine.

**Write the eval on day one.** It is what turned a forced provider change into a one-line edit.

**Wrap the provider's exceptions at the boundary.** Our `structured()` helper wraps nothing, so a botocore `ResourceNotFoundException` sails straight past the `except LLMError` that exists in `build_plan` precisely so a planner failure degrades to canned questions instead of a dead request. Cached plans kept serving throughout, which made it look intermittent rather than broken. The fallback you carefully wrote is worthless if the real error never reaches it.

**Watch the token ratio, not the bill.** Ours ran 6.04M input tokens against 188K output — 32 to 1. Agents that read transcripts are input machines, and every cost decision that mattered was about what we put *into* the prompt, not which model we picked.

The companion post, "Agents for Humans: child speech is the hard part", covers the pre-reader path, phonetic scoring, and what a real four-year-old did to our assumptions.

Code: https://github.com/mujahidmasood/heygilli. MIT.
