# HeyGilli

An AI co-watching buddy for kids' YouTube. Gilli the squirrel watches alongside a child on a tablet or phone, pauses every few minutes to ask a question by voice, and tells the parent at the end of the day what their kid learned. Kids call it by talking to it: "Hey Gilli".

Built for the **Agents for Humans** hackathon (AWS × Devpost), Everyday Agents track, on the **Strands Agents SDK**.

![HeyGilli architecture](docs/architecture.png)

## What it does

| For the child (phone, tablet; TV next) | For the parent (phone) |
|---|---|
| Only parent-approved channels, official YouTube embed, no search, no recommendations | Add channels by URL; kid profile with nickname and age, no child PII |
| At a natural break the video pauses and Gilli asks by voice | The agent screens every new upload in the background and asks the parent only about borderline ones |
| A 4-year-old answers with one word or a tap on one of three pictures; Gilli always models the answer word | A nightly two-line digest: words said for pre-readers, understood and shaky for older kids, one thing to ask at dinner |
| A 9-year-old answers in a sentence, in English or Urdu | Leaving kid mode needs the parent PIN |
| Kid mode is landscape and locks to the app | A Progress screen: minutes a day, whether questions are being answered, words coming back, what needs another look |

Ads still play and creators still get paid. Nothing a child says is stored; only a score and a ten-word paraphrase.

<p>
<img src="docs/screens/02-kid-home-zara.png" width="19%" alt="Picture-only home for a 4-year-old">
<img src="docs/screens/03-pick-it-pause.png" width="19%" alt="Pick-it pause: three icon cards, no text">
<img src="docs/screens/04-ayaan-question-urdu.png" width="19%" alt="Question for a 9-year-old with Urdu line">
<img src="docs/screens/05-digest-zara.png" width="19%" alt="Pre-reader digest">
<img src="docs/screens/06-digest-ayaan.png" width="19%" alt="Older-kid digest">
<img src="docs/screens/13-progress-zara.png" width="19%" alt="Progress for a pre-reader">
<img src="docs/screens/14-progress-ayaan.png" width="19%" alt="Progress for an older kid">
</p>

Live against the gateway on an Android emulator, 5 September: the Curator's approved uploads on Zara's picture-only home, then a Planner question on a real SciShow Kids video, spoken by Polly, and Gilli's reply after the listening window.

<p>
<img src="docs/screens/09-live-kid-home-curated.png" width="24%" alt="Live kid home with Curator-approved videos">
<img src="docs/screens/07-live-ask-ayaan.png" width="24%" alt="Live question on a real video">
<img src="docs/screens/08-live-reply-ayaan.png" width="24%" alt="Live reply and resume">
</p>

## How it is built

**Four Strands agents** in Python, each an `Agent` with a frozen system prompt, a model, and a few `@tool` functions:

| Agent | Runs | Tools | Decides |
|---|---|---|---|
| Curator | on schedule and on channel add | `youtube_uploads` (RSS + oEmbed, no API key), `get_transcript`, `screen_video`, `notify_parent` | approve, hide, or ask the parent |
| Planner | per approved video, per age band and language | `get_transcript`, `icon_lookup`, `save_plan` | a structured `QuestionPlan`; band and timing rules enforced in code afterwards |
| Buddy | live, one per session over a WebSocket | `score_answer`, `tts` (Amazon Polly), `session_log`, `switch_mode` | scoring, the reply, and mid-session adaptation |
| Digest | nightly per kid | `read_sessions`, `notify_parent` | the digest and whether anything deserves a notification |

Curator to Planner is a Strands Graph with deterministic edges. The FastAPI gateway exposes REST plus one WebSocket per session; the contract is in [docs/PROTOCOL.md](docs/PROTOCOL.md).

**The model is a setting.** Each agent reads `HEYGILLI_MODEL_<ROLE>=<provider>:<model id>`. Default is Amazon Bedrock in us-east-1; Anthropic direct, OpenAI, and Ollama are one-line alternates with the same code and the same eval (`agents/eval/run_eval.py`).

The client is one Flutter codebase for phone and tablet, with a Google TV layout as the next milestone. Storage is local JSON in development and DynamoDB for deployment.

## Layout

```
app/       Flutter client (Android phone + tablet)
agents/    Python: Strands agents, tools, FastAPI gateway, tests, eval
design/    Mockup artboards and the design canvas generator
docs/      Architecture diagram, protocol, screenshots, submission docs, video script, runbook
shared/    Icon library shared by planner and client
SPEC.md    Product and technical spec
```

## Run it

Gateway (needs AWS credentials with Bedrock and Polly in us-east-1):

```bash
cd agents
uv venv --python 3.12 && uv pip install -e ".[dev]"
cp .env.example .env
AWS_REGION=us-east-1 HEYGILLI_MODEL_DEFAULT=bedrock:us.amazon.nova-pro-v1:0 HEYGILLI_POLLY_VOICE=Ivy \
  uv run python -m uvicorn heygilli_agents.gateway:app --host 0.0.0.0 --port 8080
```

Tests and the provider eval:

```bash
cd agents
uv run pytest -q && uv run ruff check .
HEYGILLI_MODEL_PLANNER=fake: uv run python eval/run_eval.py
HEYGILLI_MODEL_PLANNER=bedrock:us.amazon.nova-pro-v1:0 AWS_REGION=us-east-1 uv run python eval/run_eval.py
```

App, live against the gateway (Android emulator reaches the host at 10.0.2.2):

```bash
cd app
flutter run --dart-define=HEYGILLI_API_URL=http://10.0.2.2:8080
```

App, demo mode with no gateway (canned kids, videos, plans, digests; a "demo" badge is shown):

```bash
cd app
flutter run --dart-define=HEYGILLI_DEMO=true
```

Full demo click path: [docs/demo-runbook.md](docs/demo-runbook.md). Agent service details: [agents/README.md](agents/README.md).

## Status

Nine-day build for the 14 September 2026 deadline. Verified so far: 73 offline tests; planner on a real SciShow Kids video via its public captions; Curator screening real uploads from two channels; a full live session turn on Bedrock with Polly audio; the Flutter client running live against the gateway on an Android emulator and in demo mode. Anthropic models on Bedrock are pending the account's use-case approval, so the interim default is Amazon Nova Pro; the switch back is one environment variable.

Not built yet: Google TV layout, AgentCore Runtime deployment (documented in `agents/README.md`), Gemini transcript path (no key on the build machine), EventBridge schedules.

## Honest notes

- The YouTube embed is used as-is. HeyGilli never blocks ads, downloads video, or draws over playback while it plays.
- Public captions are read with `youtube-transcript-api`; a video-understanding model that accepts YouTube URLs is the other path inside the same tool.
- Speech recognition runs on the device. The backend receives a transcript, scores it, and keeps only the result and a short paraphrase.

## License

MIT. See [LICENSE](LICENSE).
