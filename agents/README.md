# HeyGilli agent service

Four [Strands](https://strandsagents.com) agents (Curator, Planner, Buddy, Digest) behind a FastAPI
gateway that speaks [`docs/PROTOCOL.md`](../docs/PROTOCOL.md) to the Flutter client. Python 3.12.

```
heygilli_agents/
  schemas.py      SPEC 10 data model + PROTOCOL.md wire objects (pydantic v2)
  rules.py        SPEC 7.2/7.3 as code: band types, timing table, pick-it validity, model lines
  models.py       HEYGILLI_MODEL_<ROLE>=provider:model  ->  a Strands Model (bedrock|anthropic|openai|ollama|fake)
  llm.py          make_agent() + structured(): every model call goes through here
  fake_model.py   deterministic Strands Model so tests and the eval run offline
  planner.py      transcript -> PlanDraft (model) -> rules.enforce -> QuestionPlan (cached per video/band/language)
  buddy.py        SessionEngine: ask / score / reply / switch-to-pick; nothing a child says is kept
  curator.py      new uploads -> approve | hide | ask_parent -> fan out to the Planner
  digest.py       a kid's day -> parent Digest (counts in code, words from the model)
  gateway.py      REST + WebSocket (uvicorn)
  store.py        LocalStore (JSON under .data/) | DynamoStore (single table)
  tools/          youtube (no key), transcript (Gemini or public captions), icons, tts (Polly), notify, screening
tests/            73 offline tests (fake model, mocked network)
eval/             run_eval.py + 3 synthetic transcripts; results land in eval/results/
scripts/          smoke_gateway.py: REST + one WebSocket turn against a running gateway
```

## Run

```bash
cd agents
uv venv --python 3.12 && uv pip install -e ".[dev]"      # add .[ollama] .[openai] .[gemini] as needed
cp .env.example .env                                       # pick providers, see below
uv run python -m uvicorn heygilli_agents.gateway:app --port 8080
curl localhost:8080/healthz
```

Everything Bedrock/Polly goes to **us-east-1** regardless of the account's default region
(`HEYGILLI_BEDROCK_REGION`, `HEYGILLI_POLLY_REGION`). Local state lives in `.data/` (JSON store,
cached TTS mp3s under `.data/tts/`, served at `GET /tts/<sha1>.mp3`).

If the repo directory was moved after `.venv` was created, the console scripts in `.venv/bin`
keep the old absolute path in their shebang (`uvicorn`, `pytest`, `ruff` fail with "No such file").
Recreate the venv or run everything through `.venv/bin/python -m <module>`; this repo's venv was
repointed on 2026-09-05.

## Test

```bash
uv run pytest -q          # 73 passed; no network, no AWS, fake model for every role
uv run ruff check .
```

`tests/conftest.py` pins `HEYGILLI_MODEL_*=fake:`, `HEYGILLI_TTS=off`, a temp-dir store, and makes
any real HTTP call fail. Coverage: schema round-trips, LocalStore CRUD, every 7.2/7.3 rule, Buddy
scoring (deterministic pick, copy-it never scored, forgiving phonetics, switch to pick after two
empty answers), Planner post-validation, icon fuzzy lookup, YouTube/caption tools against canned
pages, Curator and Digest pipelines, and a scripted WebSocket session through `gateway.py`
(hello -> ready, position -> pause -> ask, answer -> reply -> resume, bye -> end).

## Eval

```bash
HEYGILLI_MODEL_PLANNER=fake: uv run python eval/run_eval.py                                  # offline, 18/18
HEYGILLI_MODEL_PLANNER=bedrock:us.amazon.nova-pro-v1:0 uv run python eval/run_eval.py         # ~40 s
HEYGILLI_MODEL_PLANNER=bedrock:us.anthropic.claude-sonnet-4-6 uv run python eval/run_eval.py
```

3 fixtures x 3 bands x 2 languages. Each cell asks the Planner for a draft, records the draft's
band-rule violations (how good is the provider on its own), runs `rules.enforce`, and checks the
final plan again. A cell passes when the final plan is clean **and** came from the model rather
than the generic fallback. A pass/fail table prints; the JSON (with every draft and final plan)
goes to `eval/results/<provider>-<timestamp>.json`.

Results on 2026-09-05:

| provider | pass | notes |
|---|---|---|
| `fake:` | 18/18 | 32 draft violations, all fixed by `rules.enforce` (that is the point of the fake) |
| `bedrock:us.amazon.nova-pro-v1:0` | 15/18 | 83 draft violations fixed; 2 cells fell back (giraffes 4_6: every pick-it had 0 or 2 "correct" options), 1 cell `modelStreamErrorException` (Nova emitted an invalid tool-use sequence, 7_8 ur). 3-10 s per plan. |
| `bedrock:us.anthropic.claude-haiku-4-5-20251001-v1:0` | 0/18 | every call: `ResourceNotFoundException: Model use case details have not been submitted for this account` |

The Anthropic use-case form gate is an account state, not a code path: the same 18 cells run
unchanged once it is approved.

## Live smoke (Bedrock, 2026-09-05)

```bash
uv run python -m uvicorn heygilli_agents.gateway:app --port 8080 &
uv run python scripts/smoke_gateway.py --video 0jKoOUZ1GBM --channel https://www.youtube.com/@SciShowKids --age 8
```

Gateway on `HEYGILLI_MODEL_DEFAULT=bedrock:us.amazon.nova-pro-v1:0`, Polly `Ivy`, real
SciShow Kids video (503 s, manual English captions via `youtube-transcript-api`):

| step | latency | result |
|---|---|---|
| POST /auth/dev, /kids, /kids/{id}/channels (@SciShowKids resolved from the channel page, no API key) | 1 ms each (channel cached) | ok |
| POST /sessions | 1 ms, `plan_ready: true` (plan cached from an earlier call; a fresh plan takes ~6 s in the background) | ok |
| WS hello -> ready | 0 ms | `plan_questions: 3` |
| position 120.5 s -> pause -> ask | 704 ms (Polly synth of the question) | recall question, `tts_url` served as `audio/mpeg` |
| answer (voice) -> reply -> resume | 2694 ms (Nova Pro ScoredReply 2170 ms + Polly) | `off_topic` with a gentle redirect (the canned answer was about lava, the question about kinds of volcanoes: correct call) |
| bye -> end | 944 ms (Polly summary line) | ok |
| GET /kids/{id}/digest | 2760 ms (DigestNarrative) | 1 asked, 1 answered, dinner prompt written |
| POST /curator/run (5 newest uploads) | 62 s | 4 approved with plans, 1 hidden by the rule pre-screen ("too short"), home row populated |
| Planner on the real video, 3 bands | 2.7-6.5 s each | 1/2/2 questions, zero rule violations |

Full transcript: `eval/results/smoke-gateway-nova-pro-20260905.txt`. The first smoke attempt hung
before `ask` while five concurrent Planner calls for the same video were in flight (repeated
`POST /sessions` while `plan_ready` was false each scheduled another); `gateway.py` now dedupes
in-flight planning per (video, band, language) and the second attempt was clean.

Polly: `Ivy` (neural, child voice) exists in us-east-1; one slow-rate 4_6 line synthesised in
0.62 s to a 31.8 KB mp3 under `.data/tts/`. Polly has no Urdu voice, so `language=ur` returns an
empty `tts_url` and the client speaks on device (PROTOCOL.md "TTS").

## Provider swap

One env line per role; the agent code never changes (`models.py`).

```bash
# Bedrock (SPEC 9.5 defaults; Anthropic ids need the account's use-case form approved)
HEYGILLI_MODEL_CURATOR=bedrock:us.anthropic.claude-sonnet-4-6
HEYGILLI_MODEL_PLANNER=bedrock:us.anthropic.claude-sonnet-4-6
HEYGILLI_MODEL_BUDDY=bedrock:us.anthropic.claude-haiku-4-5-20251001-v1:0
HEYGILLI_MODEL_DIGEST=bedrock:us.anthropic.claude-sonnet-4-6
# Bedrock, key-free today
HEYGILLI_MODEL_DEFAULT=bedrock:us.amazon.nova-pro-v1:0
# Anthropic direct
HEYGILLI_MODEL_DEFAULT=anthropic:claude-opus-5            ANTHROPIC_API_KEY=...
# OpenAI                                                 (uv pip install -e ".[openai]")
HEYGILLI_MODEL_DEFAULT=openai:gpt-4.1-mini                OPENAI_API_KEY=...
# Ollama, local, no keys                                 (uv pip install -e ".[ollama]")
HEYGILLI_MODEL_DEFAULT=ollama:llama3.2:3b                 OLLAMA_HOST=http://localhost:11434
# Offline
HEYGILLI_MODEL_DEFAULT=fake:
```

Verified on this account in us-east-1 on 2026-09-05: `us.amazon.nova-pro-v1:0` and
`us.amazon.nova-lite-v1:0` answer; `us.anthropic.claude-haiku-4-5-20251001-v1:0` answered one
CLI call and was then gated with the same `ResourceNotFoundException` as
`us.anthropic.claude-sonnet-4-6` ("Model use case details have not been submitted");
`us.anthropic.claude-opus-4-8` is `AccessDeniedException: not available for this account`.

### Why not a Strands Graph

SPEC 9.3 sketches Curator -> Planner as a Graph. `GraphBuilder` nodes hand each other free text,
so the Planner would re-parse the Curator's prose and the 7.3 enforcement would sit outside the
graph anyway. `curator.py` keeps the two Strands agents and makes the edge typed Python: the
Curator returns a `CuratorDecision` (structured output), code fans out to the Planner per
(band, language), every plan passes `rules.enforce`. Deterministic edges, no prose in between.

## Protocol

The gateway implements `docs/PROTOCOL.md` exactly (REST objects, WebSocket message shapes,
`text` omitted for band 4_6, `listen_ms + 1500 ms` timeout -> `input: "none"`). No protocol change
was needed for the smoke. `tests/test_gateway.py` is the executable version of that document.

## Data safety

- The only record of anything a child said is `Answer.result` plus a <=10-word `paraphrase`
  (`Score`/`Answer` validators cap it); `word_said` for pre-readers is the *expected* word, never the
  child's utterance. Raw STT transcripts are scored in memory and dropped
  (`tests/test_buddy.py::test_older_band_uses_model_reply_and_keeps_only_paraphrase`).
- No child name (nickname only), no photo, no audio stored. TTS mp3s are Gilli's lines, keyed by
  text hash.
- Every system prompt carries `SAFETY_RULES` (never mock, never "wrong", no personal questions,
  nothing scary, only questions answerable from the video). Pre-readers never get a "why".
- `tools/screening.py` can hide or escalate a video before a model sees it, never approve.
- Dev auth is an HMAC-signed household token from `/auth/dev`; set `HEYGILLI_SECRET`.

## Deploying to AgentCore Runtime

Not attempted yet. Two routes:

**Custom container (verified against the AWS devguide, "Get started without the AgentCore CLI",
read 2026-09-05).** AgentCore Runtime accepts any ARM64 container on port 8080 that exposes
`POST /invocations` and `GET /ping`; a FastAPI + Strands app is the documented example, so the
gateway needs those two endpoints added and a Dockerfile:

```bash
docker buildx create --use
docker buildx build --platform linux/arm64 -t <acct>.dkr.ecr.us-east-1.amazonaws.com/heygilli-agents:latest --push .
aws ecr create-repository --repository-name heygilli-agents --region us-east-1
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <acct>.dkr.ecr.us-east-1.amazonaws.com
# then boto3 bedrock-agentcore-control.create_agent_runtime(agentRuntimeName=..., agentRuntimeArtifact={
#   "containerConfiguration": {"containerUri": "<image>"}}, networkConfiguration={"networkMode": "PUBLIC"},
#   roleArn="arn:aws:iam::<acct>:role/AgentRuntimeRole")
# and bedrock-agentcore.invoke_agent_runtime(agentRuntimeArn=..., runtimeSessionId=<33+ chars>, payload=..., qualifier="DEFAULT")
```

Base image in the docs: `FROM --platform=linux/arm64 ghcr.io/astral-sh/uv:python3.11-bookworm-slim`.
Caveat for HeyGilli: `/invocations` is request/response; the Buddy WebSocket would stay on the
gateway (App Runner) and call the Runtime per turn, or the whole gateway runs on App Runner with
the agents in-process (SPEC 9.3 fallback, which is what runs today).

**Starter toolkit / AgentCore CLI (unverified).** The toolkit README says
`pip install bedrock-agentcore-starter-toolkit` and marks itself legacy in favour of
`npm install -g @aws/agentcore`; the `agentcore configure / launch / invoke` flags could not be
fetched from docs.aws.amazon.com during this session, so they are not reproduced here.

## Known gaps

- Anthropic models on Bedrock are gated on this account until the use-case form is approved; the
  demo config today is Nova Pro (or Anthropic direct / Ollama).
- Nova Pro's 4_6 drafts often mark 0 or 2 pick-it options as correct and land at 540 s in a 540 s
  video; `rules.enforce` drops them and the plan falls back to a single copy-it. Sonnet/Haiku are
  expected to do better; re-run the eval once they are reachable.
- Transcript path is public captions (`youtube-transcript-api`, unofficial). Gemini
  (`GOOGLE_API_KEY` + `.[gemini]`) is wired but untested here (no key on this machine).
- Curator and Digest run on demand (`POST /curator/run`, `POST /kids/{id}/digest/run`); no
  EventBridge schedule yet. No AgentCore Memory; no push notifications (parent inbox only).
- `DynamoStore` is implemented but only `LocalStore` has been exercised.
- Eval is 3 synthetic transcripts, not the 20 real ones plus 60 labelled child answers SPEC 9.5
  calls for.
