# HeyGilli agent service

Six [Strands](https://strandsagents.com) agents (Curator, Planner, Buddy, Digest, Coach, Reviewer)
behind a FastAPI gateway that speaks [`docs/PROTOCOL.md`](../docs/PROTOCOL.md) to the
Flutter client. Python 3.12.

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
  reviewer.py     one channel's recent uploads -> ChannelReview (cached per channel, not per kid)
  digest.py       a kid's day -> parent Digest (counts in code, words from the model)
  breaks.py       time-limit accounting: when a break is due, when a sitting resets (pure, no store)
  coach.py        drafts FOR THE PARENT only: break-time lines, and household policy questions
  drift.py        two reviews of one channel -> did it get worse; a model only describes, never decides
  history.py      watch-history.html -> counts, then the file and every video title are discarded
  revisit.py      one shaky concept re-asked later, never first, never twice running, never as a retest
  words.py        one Urdu word a session, looked up in shared/icons.json; no model translates anything
  analytics.py    a window of sessions -> the parent Analytics payload (pure counts + one model note)
  google_auth.py  parent's Google sign-in: server auth code -> refresh token -> live access token
  takeout.py      a Google Takeout zip -> TakeoutPreview; subscription CSVs only, never history
  gateway.py      REST + WebSocket (uvicorn)
  store.py        LocalStore (JSON under .data/) | DynamoStore (single table)
  tools/          youtube (no key + subscriptions.list), transcript (Gemini or public captions), icons, tts (Polly), notify, screening
tests/            367 offline tests (fake model, mocked network)
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
uv run pytest -q          # 367 passed; no network, no AWS, fake model for every role
uv run ruff check .
```

`tests/conftest.py` pins `HEYGILLI_MODEL_*=fake:`, `HEYGILLI_TTS=off`, a temp-dir store, and makes
any real HTTP call fail. Coverage: schema round-trips, LocalStore CRUD, every 7.2/7.3 rule, Buddy
scoring (deterministic pick, copy-it never scored, forgiving phonetics, switch to pick after two
empty answers), Planner post-validation, icon fuzzy lookup, YouTube/caption tools against canned
pages, Curator and Digest pipelines, Google sign-in end to end (code exchange, refresh-token
preservation, one refresh per expiry, `invalid_grant` -> re-link, subscription paging, import),
and a scripted WebSocket session through `gateway.py`
(hello -> ready, position -> pause -> ask, answer -> reply -> resume, bye -> end).
Also Takeout zip parsing (nested and localised folder names, BOM, CRLF, quoted commas, a
non-Takeout zip, zip-slip, oversize, and an assertion that the history files are never opened) and
channel reviews (thin evidence -> `unknown` with no model call, `sample_titles` pinned to the
evidence, cache hit avoids a second call, bulk cached/pending, delete scoped to one kid).

## Takeout import

Google's Takeout export is the only route to a **YouTube Kids profile's** subscriptions: the Data
API exposes the signed-in account's own list and nothing else, and Family Link exposes nothing. The
parent exports "YouTube and YouTube Music" and uploads the zip to `POST /import/takeout`, which
returns a `TakeoutPreview` and persists nothing; the parent then maps each profile onto a kid
through the existing per-kid import.

```
YouTube and YouTube Music/subscriptions/subscriptions.csv            the parent's own
YouTube and YouTube Music/children/<Profile name>/subscriptions.csv  one per YouTube Kids profile
```

- **History is never opened.** `watch-history.html` and `search-history.html` sit in the same
  folders and are the most sensitive files in the export. Only `.csv` members can be candidates, so
  an `.html` cannot be read even by accident, and
  `test_takeout.py::test_history_files_are_never_opened` spies on `ZipFile.open` to prove it.
- **Locale and layout.** Nothing is matched by a fixed path. A member is a candidate when it is a
  `.csv` and either is named `subscriptions.csv` or has a stem equal to its own folder's name
  (`abonnements/abonnements.csv`), and that same test tells the parent's list from a child profile.
  The own-list file is what names the locale's word for "subscriptions", so a French export
  (`enfants/Rayan/abonnements.csv`) parses like an English one. Top folder name is irrelevant.
- **Guards.** 50 MB upload cap (streamed, refused at 413 rather than buffered), 20 000 entries,
  4 MB per CSV, 5 000 channels per list, 50 profiles; any member with an absolute path or a `..`
  segment refuses the whole zip; a zip with no subscriptions CSV gets a 400 that says what to
  re-export. Rows are taken only when the first cell is a real channel id, so headers, blank lines
  and localised column names need no special case.

Checked against a real export on 2026-09-05 (the developer's own; the data is never copied into the
repo and the profile names are not reproduced here): 304 KB, 5 zip members, 3 of them opened —
two child profiles with 148 and 19 channels, and 1 on the parent's own list. Every test fixture is
invented.

## Channel reviews

The Curator screens one video; the Reviewer answers "what does this channel actually publish?",
which is the question a parent has after importing 148 subscriptions in one go.

```
POST /channels/reviews  {channel_ids}  -> {reviews: [...cached now...], pending: [...]}   client polls
GET  /channels/{id}/review?refresh=true                                    -> one ChannelReview
DELETE /kids/{kid_id}/channels/{channel_id}                                -> {removed: true}
```

- **Evidence.** One request to the channel's public RSS feed: no API key, no quota, no `search`
  endpoint. It carries the channel's own title plus ~15 recent uploads with titles and short
  descriptions, and that is the whole basis of the review. `sample_titles` is set in code from what
  was actually put in the prompt, so a parent can see the basis and a model cannot claim to have
  read something it was not given.
- **Honesty is enforced in code, not asked for in the prompt.** Fewer than three readable uploads
  and the verdict is `unknown` with a note saying how many there were — the model is never called,
  so it cannot guess from a channel name. An unreachable feed and a model failure are both
  `unknown`, never a default `good`.
- **Caching.** A review is a property of the channel, not of a kid, so it is cached globally by
  channel id with `reviewed_at` and the model id. `POST /channels/reviews` returns hits immediately
  and starts the misses in the background, four at a time (`REVIEW_CONCURRENCY`) in worker threads,
  so 148 channels neither stampede Bedrock nor block the event loop. Ids already in flight stay in
  `pending` without starting a second run.
- **Wording.** The prompt asks what the channel publishes and flags only what a parent would want
  to know (`ads_or_merch`, `consumerism`, `scary`, `mature_language`, `low_quality`, `off_topic`,
  `not_for_kids`, `unclear`), forbids inventing specifics, and forbids moralising about creators:
  a channel that sells merch is selling merch. Removing a channel takes it from that kid only —
  a sibling keeps theirs and the review cache is untouched.

Live on Bedrock Nova Pro, 8 real channels from the export above: 22.4 s total (2.8 s each),
29 307 in / 1 922 out tokens, **$0.0037 per channel**. `Kid-E-Cats` came back `unknown` on its own
merits — its feed really did hold one upload.

## Time limits and movement breaks

A child watches for 25 minutes; Gilli stops the video and gives them something physical to do,
built from what they just watched; nothing plays until the break is over. The difference between
limiting screen time and filling the gap.

```
PATCH /kids/{id}/limits  {daily_minutes, break_after_minutes, break_minutes, max_video_minutes} -> Kid
GET   /kids/{id}/state                                    -> WatchState
POST  /kids/{id}/break/ack                                -> MovementBreak   (records; does not shorten)
POST  /kids/{id}/break/override  {pin_ok: true}           -> {cleared: bool} (parent, behind the PIN)
POST  /sessions                                           -> 409 {detail: {error, state}} when blocked
GET   /kids/{id}/home                                     -> ... + watching_allowed, blocked_reason, active_break
ws    {t: "break", break: BreakPeriod}                    -> stop playback; the session then ends
```

- **Accounting is pure functions over sessions** (`breaks.py`, no store, no clock of its own).
  Continuous watching resets on a break or a 10-minute gap with no session, and deliberately
  ignores dates — 23:55 to 00:10 is one sitting. The daily total is per session `date`, so
  yesterday rolls off at midnight without anything having to run at midnight. Live seconds count
  before they are persisted, or a child could pass their limit mid-video.
- **A break ends on the clock, never on a tap.** `ack` sets `acked` and changes nothing else;
  `override` moves `ends_at` to now, which is also what resets the sitting. Expiry needs no job:
  `is_active()` is a comparison.
- **When it fires.** Past the limit, `due()` answers `wait_for_moment` until a question pause or
  the end of the video, and `now` after three more minutes whether or not one arrived. The task is
  written in the background from a minute *before* the limit, so even an unannounced interrupt
  usually has a real task; if it is still not ready 2 s after the break fires, the child gets a
  built-in one and the model call is dropped. Nobody watches a frozen frame while a model thinks.
- **The safety gate is code, not prompt** (`breaks.validate`). A generated task is dropped if it
  mentions climbing, furniture, jumping off things, running, stairs, outdoors, water, kitchens,
  sharp objects, fast spinning, needing an adult, fetching equipment, or punishment framing; if it
  is under 1 or over 3 minutes; or, for band `4_6`, if it is a sequence rather than one imitation,
  needs reading, or has no spoken line. The reason comes back as a string and is logged.
  `SAFE_FALLBACKS` ships four tasks per band and every one of them is run through the same gate by
  the test suite — which is how two of them got rewritten.
- **A break never depends on a model call succeeding.** Rejection, provider error, throttle,
  timeout, no model at all: same code path, a built-in task.

Live on Bedrock Nova Pro against the two real kids in `.data/` (Abu 8, Abeeha 6):

| titles fed in | generated | rejected |
|---|---|---|
| Abu's football + Danny Go dance uploads | "Football Warm-Up", "Football Dribble Dance", "Football Star Warm-Up" | 0/5 |
| Abeeha's Mario Party + Larva Kids uploads | "Mario Party Mini-Game", "Luigi Jumps", "Mermaid Wave" | 0/5 |
| Abu's *"More Free Furniture!? \| Toca Boca World"* | — | **5/5**, all furniture (`'chair'`, `'sofa'`, `'furniture'`) |
| Abeeha's *"Barbie Meerjungfrauen"* (mermaids) | "Mermaid Tail Wiggle", "Mermaid Waves" | 0/5 — never reached for water |

25% of live generations were rejected, all of them by the furniture rule on a video that is *about*
furniture. That is the gate working as intended and the trade it makes: a false positive costs a
built-in task, a false negative is an adult telling a six-year-old to climb something.

Two things the live runs changed in the code rather than the prompt. Nova Pro copied the system
prompt's "a volcano video becomes crouching small and erupting tall" verbatim for a child whose
videos were Mario Party and Barbie, so the examples are now explicitly labelled as the method and
not tasks to reuse. And the first `4_6` rule rejected *every* generation on the word "then" —
"crouch small and then erupt tall" is one imitation, so the rule now counts sequence markers
instead of banning the word.

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

## Google sign-in and subscription import

The parent signs in with Google once; the child never signs in to anything. One consent covers
identity and `https://www.googleapis.com/auth/youtube.readonly` — a **sensitive** scope, not a
restricted one, so it needs the OAuth consent screen filled in but no third-party security
assessment. That grant is what turns "paste channel URLs" into "tick the channels you already
follow" (SPEC §6.1).

```
GOOGLE_CLIENT_ID=<id>.apps.googleusercontent.com     # the **web** OAuth client, not the Android one
GOOGLE_CLIENT_SECRET=<secret>
```

Both come from the *web* client of the same Google Cloud project as the Android client, with
YouTube Data API v3 enabled. The Android client mints a **server auth code**; only the web client's
id and secret can exchange it. Leave them unset and `/auth/google`, `/me/youtube` and
`/me/youtube/subscriptions` answer **503** naming the two variables; `POST /auth/dev` keeps working,
so nothing else in the demo depends on having a Google project.

```
Android consent  ->  server_auth_code  ->  POST /auth/google
                                            oauth2.googleapis.com/token (grant_type=authorization_code,
                                            web client id+secret, no redirect_uri)
                                              -> refresh_token (first consent only) + access_token
                                            store: refresh token, parent email, cached access token
POST /auth/google -> {token, household_id, email, youtube_linked}
GET  /me/youtube/subscriptions  -> subscriptions.list(mine=true), 50/page, 1 quota unit per page,
                                   each channel marked with the kids it is already approved for
POST /kids/{kid}/channels/import -> bulk approve -> Curator screens the new uploads in the background
```

Details worth knowing:

- `google_access_token()` returns the cached access token until 60 s before it expires, then
  refreshes exactly once and re-caches. A refresh token is returned by Google only on the *first*
  consent, so a later exchange that comes back without one never overwrites the stored one.
- `invalid_grant` (the parent revoked access, or the token expired) clears the link and surfaces
  "needs re-linking" — a 401 on `/auth/google`, and a plain `{linked: false, subscriptions: []}` on
  the two `/me/youtube` reads, which the protocol already defines as a normal state.
- The channel id comes from `snippet.resourceId.channelId`. `snippet.channelId` is the
  *subscriber's* own channel and is identical on every row; a test pins the difference.
- An imported channel goes through the same `_approve_channel` path as a pasted URL, so it behaves
  identically afterwards. Importing approves channels, never videos.
- The parent's subscriptions are the *parent's*: a list to tick through, not a catalogue. And
  YouTube Kids profile subscriptions are not exposed by any API — only the signed-in account's own.

## Protocol

The gateway implements `docs/PROTOCOL.md` exactly (REST objects, WebSocket message shapes,
`text` omitted for band 4_6, `listen_ms + 1500 ms` timeout -> `input: "none"`). No protocol change
was needed for the smoke, for the Takeout import, or for channel reviews.
`tests/test_gateway.py` is the executable version of that document; `test_takeout.py`,
`test_reviewer.py` and `test_gateway_breaks.py` pin the newer sections, field by field.

Time limits needed three additions, all made in `PROTOCOL.md` first: `GET /kids/{id}/home` now
carries `watching_allowed`, `blocked_reason` and `active_break` beside its rows; the 409 body is
`{detail: {error, state}}` for both refusal reasons; and `WatchState.minutes_left_today` is `null`,
not 0, when a kid has no daily limit.

**The break payload was contested and is now settled**, both halves on the parent-authored
`BreakMessage` / `BreakPeriod` design. The earlier `MovementBreak` / `BreakTask` design had the app
inventing an instruction for a child and implying it could tell whether the child obeyed; it could
not, and it is not the app's place. What a break says is now a list of sentences a parent typed,
read out verbatim, and empty is a supported answer: the video stops and Gilli says only that it is
break time. `coach.py` can draft lines, but a draft reaches a child only after the parent saves it.
Whether a break holds is `break_is_firm`, also the parent's.

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
- Dev auth is an HMAC-signed household token from `/auth/dev` or `/auth/google`; set
  `HEYGILLI_SECRET`.
- The Google link stores three things per household and nothing else: the refresh token, the
  parent's email, and the cached access token with its expiry. No child field, no profile, no
  photo. **The refresh token is stored in the clear**, in the same JSON store as everything else:
  it is a credential that grants read-only access to the parent's YouTube subscriptions until they
  revoke it, and a real deployment would encrypt it at rest (KMS-backed field encryption, or
  Secrets Manager keyed by household) with the key outside the data store. That is a known
  hackathon shortcut, stated rather than papered over. It is never returned by any endpoint, and
  no token, refresh token or auth code is ever logged — not even in an error path.
- The parent can drop the link (`google_auth.unlink`); `POST /auth/google` re-creates it.
- A Takeout upload is read in memory and thrown away: `POST /import/takeout` writes nothing, not
  even a cache entry, and the child's watch and search history are never opened at all. The only
  child-supplied string that leaves the parse is the profile folder name, which is returned to the
  parent for mapping and is not stored unless they choose it as a kid's nickname.
- A `ChannelReview` is about a channel, not a child. It holds no household, kid or session id, which
  is why it can be cached globally and shared.

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
- A channel review never expires. `reviewed_at` is recorded and `refresh=true` re-runs one, but
  nothing ages the cache out, so a channel that changes character keeps its old review until
  someone asks for a refresh.
- The Reviewer reads ~12 recent uploads. That is what the RSS feed gives for free, and it is a
  snapshot: a channel with a bad month and a good year reads as bad, and a channel whose feed is
  quiet reads as `unknown` (`Kid-E-Cats` in the live run). Flags come from titles and short
  descriptions only — nothing watches the video, so in-video ad reads and sponsor segments are
  invisible.
- Takeout gives subscriptions but no ages, so the parent still maps each profile to a kid by hand.
  There is no re-import diff: uploading a newer export re-lists everything rather than showing what
  changed since last time.
- Google sign-in has never run against real Google: there are no OAuth credentials on this machine
  and creating them needs the user's own Google account. Everything below the HTTP boundary is
  tested (request payloads, paging, refresh, revocation), but the round trip — consent screen,
  server auth code, a real `subscriptions.list` — is unverified. First real run to watch: whether
  the Android client requests offline access, since without it Google returns no refresh token.
- No token encryption at rest and no revocation endpoint (`oauth2.googleapis.com/revoke`) yet;
  `google_auth.unlink` only forgets the local copy.
- Eval is 3 synthetic transcripts, not the 20 real ones plus 60 labelled child answers SPEC 9.5
  calls for.
- Movement breaks: `max_video_minutes` filters the home rows but `POST /sessions` does not refuse a
  too-long video, so a stale home screen can still start one. The safety gate is English-only —
  an Urdu task would sail through every word rule — and it reads the words, not the meaning, so
  "pretend to place a sofa" is rejected while a genuinely unsafe sentence built from safe words
  would not be. Continuous watching inside a live session is wall-clock from when the socket opens,
  which counts a paused video as watching. There is no TTS for the break line: the client speaks
  `task.spoken` on-device. Break records are never pruned.
