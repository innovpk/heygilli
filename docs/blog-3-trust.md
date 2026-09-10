# Agents for Humans: building HeyGilli, part 3 — making the agents trustworthy

Part 1 covered the concept and part 2 the eight Strands agents. This last post answers the question every parent asks first: how do you know the agent won't say something it shouldn't?

A prompt that says "never say *wrong*" is a request, not a guarantee. One day a model will say "wrong" anyway. What we built is a way to catch that before a child hears it, to show a parent the whole story afterwards, and to go back and fix what was already done.

## One door for every model call

All eight agents make their model calls through a single function, `structured()`. The eval, the tests, and the live gateway all use the same path, so anything we add there applies everywhere at once. Three things happen inside it: a trace, a guardrail check, and an audit record.

```python
def structured(agent, prompt, output_model, *, context=None):
    with tracer.start_as_current_span("heygilli.agent", attributes={...}) as span:
        out = _invoke(agent, prompt, output_model)          # Strands structured output
        found = guardrails.check(output_model.__name__, out, context)
        blocked = guardrails.blocking(found)
        if not blocked:
            finish("warned" if found else "ok", found)
            return out

        # The first answer is in the agent's history, so the feedback alone
        # is enough for it to know what to change.
        retry = _invoke(agent, guardrails.feedback(blocked), output_model)
        if not guardrails.blocking(guardrails.check(output_model.__name__, retry, context)):
            finish("fixed", found)
            return retry
        finish("blocked", found, "guardrail")
        raise GuardrailError(role, blocked)
```

## Guardrails: checked in code, sent back once

Every answer is checked in code before anyone sees it. What gets checked depends on who will read it.

Anything a child hears (a question, Gilli's reply, a game line, a break line) is held to the child-text rules:

```python
def child_text(label: str, text: str | None) -> list[Violation]:
    """The rules for anything a child will hear or see."""
    out = []
    if hits := _hits(text, CHILD_WORDS):
        out.append(Violation("unsafe_word", f"{label} says {', '.join(hits)}"))
    if _PERSONAL.search(text):   # "what's your name / address / school ..."
        out.append(Violation("personal_question", f"{label} asks the child about themselves"))
    if _LINK.search(text):
        out.append(Violation("link", f"{label} contains a link"))
    return out
```

A separate pattern catches Gilli being harsh: "wrong", "incorrect", "you failed".

What only a parent reads is checked for consistency instead:

- The Curator can't approve a video whose own title trips a safety rule.
- The digest can't claim a child said a word that no question ever used.

When an answer breaks a blocking rule, it isn't thrown away straight off. The agent gets it back once, with the reason:

```python
def feedback(violations):
    rules = "\n".join(f"- {v.detail}" for v in violations)
    return ("Your last answer cannot be used, because it broke these rules:\n"
            f"{rules}\n"
            "Give the answer again in the same format, fixing those points and changing nothing else.")
```

Because the first answer is still in the Strands agent's conversation history, that short message is all the agent needs. If the second answer also fails, `GuardrailError` is raised. That error is a subclass of `LLMError`, so every caller's existing fallback already handles it: the Planner uses the built-in questions, and the Curator asks the parent. The model can fail, but a child never hears it fail.

## Wrap the provider's exceptions, or your fallbacks are worthless

This lesson cost us a production outage.

Every caller catches `LLMError` and falls back to something safe. But when our Bedrock model ID turned out to be one the account couldn't invoke (see part 2), botocore raised `ResourceNotFoundException`. That is not an `LLMError`, so it went straight past every handler written for exactly this case and left the gateway as a 500.

An unhandled 500 carries no CORS headers, so the browser reported a CORS error, and the model was never mentioned. Videos with a cached plan kept working, which made the failure look intermittent.

The fix is one `try` in `_invoke`, the only function that calls the agent:

```python
try:
    result = agent(prompt, structured_output_model=output_model)
except LLMError:
    raise
except Exception as e:  # provider SDK, transport, throttling, entitlement
    raise LLMError(f"{agent.name}: {type(e).__name__}: {e}") from e
```

A model you can't reach is one failure with one meaning, whoever hosts it. None of the callers should need to import botocore to handle it.

## Full traces, with the household's own data

Strands emits OpenTelemetry spans for each agent run: the agent, every event-loop cycle, every model call with its messages and token counts, and every tool call. `structured()` opens one root span around each call, tagged with the role, the household, and the child. HeyGilli collects every span under that root, and when the root ends it stores the whole trace as one document next to the household's other data.

We kept traces there, rather than in an observability backend, for two reasons:

- A trace is readable on the free tier with nothing else deployed.
- When a household is deleted, its traces go with it, like everything else about it.

Setting `OTEL_EXPORTER_OTLP_ENDPOINT` also sends them to any OTLP collector.

One thing is never kept: what a child said. The Buddy's prompt contains the child's words, and they are replaced before anything is written. That is the "nothing a child says is stored" requirement from part 1, applied in the tracing layer too.

## Audit and auto-fix

Guardrails catch a bad answer as it happens. The audit looks back over what the agents have already done, because rules change and old decisions stay in the database.

- **Every call is recorded as an event**: the role, what came back, how long it took, whether a guardrail fired, and whether the retry fixed it. Every violation becomes an incident linked to its trace.
- **After each screening, `audit_household` re-checks past decisions against the current rules:**
  - A Curator approval that breaks a safety rule is hidden.
  - One that should have gone to the parent goes back to them.
  - A cached question plan containing something a child mustn't hear is dropped, so the next play writes a new one.
  - An agent whose answers keep ending in the fallback is reported as degraded.
- **The audit never touches a decision a parent made.** It fixes the agents' mistakes, not the family's choices.

The gateway's `/agents/report` puts it together for a parent: what the agents did, what was caught, and what was fixed, each linked to its full trace. "The model usually behaves" became something we can show.

## An eval before any provider is trusted

No model provider is trusted until it passes the same eval: three real transcripts, across three sets of question rules and two languages, which makes 18 cells. Each cell is checked twice:

1. The model's **draft** is checked against the rules. This measures how good the provider is on its own.
2. `rules.enforce` runs, and the **final** plan is checked again. This asks whether a child would ever see a violation.

A cell passes only when the final plan is clean *and* came from the model rather than the built-in fallback. That is what produced the numbers in part 2: 0 of 18 and 0 of 18 on the two gated Claude models, and 16 of 18 on Amazon Nova Pro. That's also how a forced provider change took one line.

Underneath the eval, 665 backend tests run offline on a fake model provider. Almost none of them need a real model, because the rules they test live in code.

## What runs on AWS

- **Amazon Bedrock** in us-east-1, through cross-region inference profiles. Amazon Nova Pro is the production model for all eight agents while Anthropic access on the account is pending.
- **Amazon Polly** for Gilli's voice.
- **Amazon DynamoDB**, as a single table keyed by household: the partition key is the household and the sort key is the entity type plus its ID. Deleting a household deletes everything about it, traces included.

The gateway is FastAPI: REST plus one WebSocket per live session. The next step is moving the agents onto Amazon Bedrock AgentCore Runtime.

## What we'd tell another team

- **Put every model call behind one function.** Tracing, guardrails, retries, and auditing were each a few lines, because there was one place to add them.
- **Check the output in code, then give the model one chance to fix it.** Telling the agent exactly which rule it broke costs one short message, and an answer that still fails lands on a fallback, not in front of a child.
- **Wrap the provider's exceptions where you call it.** A fallback you wrote carefully is worthless if the real error never reaches it.
- **Invoke the model before you believe the console.** A listing API can say `ACTIVE` about a model your account can't call.
- **Watch the token ratio, not the bill.** Ours ran 6.04M input tokens to 188K output, about 32 to 1. Agents that read transcripts are input machines, and every cost decision that mattered was about what went *into* the prompt.

That completes the series: part 1 covered the concept and requirements, part 2 the Strands design, and part 3 how we made it trustworthy.

Code: https://github.com/mujahidmasood/heygilli. MIT.
