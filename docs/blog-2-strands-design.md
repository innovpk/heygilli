# Agents for Humans: building HeyGilli, part 2 — designing eight agents with Strands

Part 1 was the idea. This part is the design: eight small Strands agents, the Strands features we leaned on, the multi-agent pattern we skipped, and the day our planned model turned out to be one we couldn't call.

## One agent per job

Instead of one assistant with twenty tools, each agent has one trigger, one output type, and a short tool list:

| Agent | Runs | Decides |
|---|---|---|
| Curator | when a channel is added, and on a schedule | approve, hide, or ask the parent |
| Planner | once per approved video and language | the questions Gilli asks |
| Buddy | live, one per session | how an answer scores, and Gilli's reply |
| Digest | nightly | the parent's note |
| Reviewer | when a channel is imported | what a channel really publishes |
| Coach | when a parent sets house rules | drafts for the parent only |
| Explainer | when a parent asks about a video | nothing: it answers, it doesn't rule |
| Playmate | each round of Gilli's games | how hard the next round is |

Only three of them have tools. Everything else, like fetching a transcript, listing uploads or generating Polly speech, is a plain Python function the gateway calls. That became the rule for the whole codebase: **the agents decide; the code fetches and enforces.** A model that can't reach the database can't corrupt it, and a rule written in code can be unit-tested.

All eight come from one factory. It builds a fresh `Agent` per request, since a Strands agent handles one call at a time, and takes a `model` argument that every test fills with a fake:

```python
def make_agent(role, system_prompt, tools=(), model=None) -> Agent:
    return Agent(name=f"heygilli-{role}", model=model or model_for(role),
                 system_prompt=system_prompt, tools=list(tools), callback_handler=None)
```

## Structured output: no prose between agents

Every agent returns a Pydantic model through Strands' structured output, never free text for code to parse. The schema is where most of the prompt engineering ended up:

```python
class CuratorDecision(BaseModel):
    decision: Literal["approve", "hide", "ask_parent"]
    reason: str = Field(description="Two or three sentences for the parent who has to "
                                    "decide ... Never restate the title.")
    concerns: list[str] = Field(description="Up to 3 short tags, one to three words each, "
                                            "naming what gave you pause.")
```

The `Literal` means the model can't invent a fourth verdict. One line describing `concerns` did more for the parent's screen than a paragraph of system prompt had: it keeps the tags short enough to skim.

![The Curator's concerns, as a parent sees them: short tags beside each verdict](blog/curator-tags.png)

## A tool's docstring is its whole manual

A Strands `@tool` is still a plain function, so the Curator's `screen_video` is also called directly by the pipeline. That's one implementation with two callers. But the docstring is all the model knows about a tool, and we learned that from a bug.

The Explainer's prompt showed the channel's ID but not the video's, so the model passed the channel ID to `search_transcript`. The search ran against nothing, and "not found" became a confident, wrong answer to a parent. Now both IDs are labelled, the tool rejects a channel ID and says why, and it returns `searched_whole_video` so the agent knows when "not found" can be trusted.

The same prompt treats a transcript as somebody else's content, to be described and never obeyed. That's prompt-injection defence for a product whose whole input is other people's videos.

## The Graph we didn't build

Our spec drew Curator → Planner as a Strands `GraphBuilder` graph. But graph nodes pass text, so the Planner would have re-read the Curator's prose to rebuild a decision that already existed as a typed object. The hand-off is plain code instead:

```python
decided = structured(agent, prompt, CuratorDecision, context={...})
...
if decision.decision == "approve":
    for language in languages:
        ensure_plan(video, band, language, store, planner, ...)  # the Planner, then rules.enforce
```

Our rule of thumb: use a multi-agent topology when you can't name the next step in advance. We always could.

## The model is a setting

Each agent reads `HEYGILLI_MODEL_<ROLE>=<provider>:<model id>`, and one loader turns that into a Strands model: Bedrock, Anthropic, OpenAI, Ollama, or a fake one for tests.

We had planned on Claude on Amazon Bedrock. The inference profiles all listed as `ACTIVE`, but every call failed:

```
ResourceNotFoundException: Model use case details have not been submitted
for this account.
```

Our eval scored **0 of 18** on Claude Sonnet 4.6, **0 of 18** on Claude Haiku 4.5, and **16 of 18** on Amazon Nova Pro. Because the model was a setting, switching took one environment variable. Production runs on Nova Pro today, and moving to Claude is the same one-line change once access is granted.

The lesson: call the model before you trust the console.

## Next

Part 3 covers how we keep a model from saying the wrong thing to a child: one function every call goes through, guardrails with one retry, full traces, and an audit that fixes past mistakes.

Code: https://github.com/mujahidmasood/heygilli. MIT.
