# HeyGilli demo runbook

How to run the full demo on a Mac with an Android tablet and an Android phone, in the order of `docs/video-script.md`. Written against SPEC v0.3 and `docs/PROTOCOL.md` on 5 September 2026 while the code was still being built. Lines marked **[verify]** name something the code must expose; check the exact module, flag, or command against `agents/` and `app/` before recording.

## 0. What you need

- Mac with `uv`, Flutter stable, `adb`, and `scrcpy` (`brew install scrcpy android-platform-tools`).
- Android tablet and Android phone, both Android 12 or newer (screen pinning, on-device Urdu speech recognition). USB debugging on.
- Both devices and the Mac on the same Wi-Fi network. Note the Mac's LAN IP: `ipconfig getifaddr en0`.
- AWS credentials with Bedrock access in `us-east-1` (model access confirmed on this account on 5 Sep). Anthropic API key for the swap beat.
- Three demo videos chosen and pre-ingested (section 4).
- Google Speech Services installed on the tablet with English and Urdu offline packs downloaded (Settings, System, Languages, Speech).

## 1. Environment

```bash
cd ~/innovpk/heygilli/agents
cp .env.example .env    # first time only
```

Set in `agents/.env`:

```bash
# Pinned in SPEC 9.5, verified in us-east-1 on 2026-09-05
HEYGILLI_MODEL_CURATOR=bedrock:us.anthropic.claude-sonnet-4-6
HEYGILLI_MODEL_PLANNER=bedrock:us.anthropic.claude-opus-4-8
HEYGILLI_MODEL_BUDDY=bedrock:us.anthropic.claude-haiku-4-5-20251001-v1:0
HEYGILLI_MODEL_DIGEST=bedrock:us.anthropic.claude-sonnet-4-6
AWS_REGION=us-east-1           # the account default is ap-southeast-1; every Bedrock call must pass us-east-1
AWS_PROFILE=<profile>          # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
ANTHROPIC_API_KEY=<key>        # second provider for the swap beat
GOOGLE_API_KEY=<key>           # optional; get_transcript Gemini path. Leave unset for captions-only.
HEYGILLI_STORAGE=local         # [verify] local JSON for the demo; dynamodb for deploy
HEYGILLI_DATA_DIR=./data       # [verify]
```

Never show `.env` on camera. Show it with `grep HEYGILLI_MODEL .env`.

## 2. Start the gateway

```bash
cd ~/innovpk/heygilli/agents
uv venv --python 3.12 && uv pip install -e ".[dev]"     # first time only
uv run uvicorn heygilli_agents.gateway:app --host 0.0.0.0 --port 8080 --reload   # [verify module path]
```

Check from the Mac:

```bash
curl -s localhost:8080/health      # [verify] or GET / ; expect 200
```

Check from the tablet's browser: `http://<mac-ip>:8080/health`. If that fails, the demo will fail. Fix Wi-Fi isolation (guest networks block device-to-device traffic) or use the phone's hotspot for all three devices.

## 3. Seed a household, a kid, and channels

All endpoints are in `docs/PROTOCOL.md`. Bearer token from `/auth/dev`.

```bash
BASE=http://localhost:8080
TOKEN=$(curl -s -X POST $BASE/auth/dev -H 'content-type: application/json' -d '{"name":"Mujahid"}' | jq -r .token)
H="-H 'authorization: Bearer $TOKEN' -H 'content-type: application/json'"

# Pre-reader
LISA=$(eval curl -s -X POST $BASE/kids $H -d "'{\"nickname\":\"Lisa\",\"age\":4,\"languages\":[\"en\",\"ur\"]}'" | jq -r .id)
# Older kid
RAYAN=$(eval curl -s -X POST $BASE/kids $H -d "'{\"nickname\":\"Rayan\",\"age\":9,\"languages\":[\"en\",\"ur\"]}'" | jq -r .id)

# Five channels for Lisa, by URL (channel URL, @handle, or a video URL; the server resolves)
for URL in \
  "https://www.youtube.com/@<channel1>" \
  "https://www.youtube.com/@<channel2>" \
  "https://www.youtube.com/@<channel3>" \
  "https://www.youtube.com/@<channel4>" \
  "https://www.youtube.com/@<channel5>"; do
  eval curl -s -X POST $BASE/kids/$LISA/channels $H -d "'{\"url\":\"$URL\"}'" | jq -c '{title, approved}'
done
# At least one science channel for Rayan (the volcano video)
eval curl -s -X POST $BASE/kids/$RAYAN/channels $H -d "'{\"url\":\"https://www.youtube.com/@<science-channel>\"}'" | jq -c .
```

Write the kid ids down; the app needs the right profile selected.

If a `make seed` or `python -m heygilli_agents.seed` exists **[verify]**, use it instead and skip the curl block. It should create the same two kids and channels and pre-ingest the demo videos.

## 4. Run the Curator and pre-ingest the demo videos

This is the "agent in the background" beat and also the cache warm-up. Do it the day before recording, and again ten minutes before, so plans are cached and no child waits on the Planner.

```bash
eval curl -s -X POST $BASE/curator/run $H -d "'{\"kid_id\":\"$LISA\"}'" | jq .
eval curl -s -X POST $BASE/curator/run $H -d "'{\"kid_id\":\"$RAYAN\"}'" | jq .
```

Expect `{approved: [...], hidden: [...], ask_parent: [...]}`. For the video beat, one video must land in `ask_parent`. Stage it: add a channel with a sugar-heavy or ad-heavy recent upload (the spec uses a Blippi candy-factory video as the example) so `screen_video` marks it borderline. If the Curator approves it anyway, lower the borderline threshold in the Curator system prompt **[verify config name]** rather than faking the response.

Check the inbox and the plans:

```bash
eval curl -s $BASE/parent/inbox $H | jq .
eval curl -s "$BASE/kids/$LISA/home" $H | jq '.rows[].videos[] | {id, title, age_ok, plan_ready}'
```

Every demo video must show `plan_ready: true` before you record.

For the terminal shot, run the Curator in a terminal window sized 1280 x 720 with an 18 pt font and Strands tracing on **[verify env var, for example `STRANDS_TRACE=1` or OTEL settings]**. The trace should show `youtube_uploads`, `get_transcript`, `screen_video`, the Graph edge to Planner, `icon_lookup`, `save_plan`, and `notify_parent`.

## 5. Build and install the app

```bash
cd ~/innovpk/heygilli/app
flutter pub get
adb devices                                 # both devices listed
flutter run -d <tablet-serial> --dart-define=HEYGILLI_API_URL=http://<mac-ip>:8080 \
                               --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID=<web client id>
flutter run -d <phone-serial>  --dart-define=HEYGILLI_API_URL=http://<mac-ip>:8080 \
                               --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID=<web client id>
```

Both defines matter. `HEYGILLI_API_URL` (not `..._BASE_URL`) is the name `BuildConfig` reads.
It now defaults per platform — `10.0.2.2` on an Android emulator, `localhost` on an iOS simulator
or in a browser — and **neither is reachable from a real device on your wifi**, which is what the
demo runs on. Without `HEYGILLI_GOOGLE_SERVER_CLIENT_ID` — the **web** client id, from
`agents/.env` — the Google button is present but disabled, and there is no way to sign in on the
day. Take both from a build you have actually launched, not from this file.

Or build once and install on both: `flutter build apk --release --dart-define=...` then `adb -s <serial> install build/app/outputs/flutter-apk/app-release.apk`. Use the release APK for recording; debug builds stutter on the embed.

The tablet is the kid's screen. The phone is the parent's screen and, for beat 9, a kid-mode screen.

If a beat needs an iOS simulator or a browser instead — the same codebase builds both — the
gateway is at `localhost` for each, so only the client id define is needed:

```bash
flutter run -d "iPhone 17 Pro"              --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID=<web client id>
flutter run -d web-server --web-port 5601   --dart-define=HEYGILLI_GOOGLE_SERVER_CLIENT_ID=<web client id>
```

Google sign-in does not complete in a browser (google_sign_in's web plugin wants a rendered
button, not the phone flow) and the app says so rather than hanging. Record any web beat in demo
mode, or hand the browser a token minted with `POST /auth/dev`.

Start screen mirroring for backup footage: `scrcpy -s <tablet-serial> --record tablet-take1.mp4 --no-audio-playback`.

## 6. Click path per video beat

Beat numbers match `docs/video-script.md`.

**Beat 2, parent setup (phone).** Open HeyGilli. Sign in with Google — there is no name-typing path in the UI any more, so the build must carry `HEYGILLI_GOOGLE_SERVER_CLIENT_ID` (section 5). Kids list shows Lisa and Rayan. Tap Lisa. Channels tab shows the five channels. Tap "Add channel", paste one more URL, watch it resolve to a title and thumbnail. Tap "Kid mode". The phone is now locked to kid mode; hand the tablet over.

**Beat 3, Curator (terminal plus phone).** In the terminal run the `curator/run` command from section 4 for Lisa. Trace scrolls. On the phone, the inbox badge or push appears: "New from <channel>: '<title>'. <reason>. Fine for Lisa?" Tap Yes. Confirm in the terminal: `curl $BASE/parent/inbox` now returns an empty list, and the video shows in Lisa's home.

**Beat 4, pre-reader name-it (tablet).** Open HeyGilli on the tablet. Profile picker: tap Lisa's avatar. Picture-only home. Tap the giraffe video's thumbnail; Gilli reads the title aloud on focus if the client supports it. Video plays. At the planned timestamp (about two minutes in; check `t_sec` in the plan) the video pauses on the frame, Gilli appears in the corner, the question plays, the big mic button pulses for five seconds. Child speaks. Gilli replies with the model-the-answer line and a gesture. Video resumes.

To skip the wait during rehearsals, seek to five seconds before the first `t_sec` using the player's scrubber. Do not seek during the recorded take; the pause must look natural.

**Beat 5, pick-it (tablet).** Same video or the second demo video. At the next pause, three pictures appear. Question plays: "Show me the blue one." Child taps. Gilli replies. Resume. If the mic gave nothing in beat 4 twice, the Buddy has already switched this question to pick-it on its own, which is fine and worth saying on camera.

**Beat 6, older kid English (tablet).** Exit to the profile picker (parent gate: PIN or long-press, **[verify]**). Tap Rayan. Home shows channel rows with titles. Tap the volcano video. At the first pause the question shows as text and is spoken. Tap the mic, answer in a sentence within eight seconds. Gilli builds on the answer. Resume.

**Beat 7, Urdu (tablet).** In Rayan's session, language toggle to Urdu **[verify where: parent settings or per-session]**. Next question arrives in Urdu. Answer in Urdu. Reply in Urdu. Or run a second video with the profile's language set to `ur`.

**Beat 8, provider swap (terminal plus tablet).** In the terminal:

```bash
grep HEYGILLI_MODEL .env
sed -i '' 's|^HEYGILLI_MODEL_BUDDY=.*|HEYGILLI_MODEL_BUDDY=anthropic:claude-opus-5|' .env
grep HEYGILLI_MODEL_BUDDY .env
# restart the gateway (Ctrl-C the uvicorn process, run the start command again; --reload does not re-read .env)
```

On the tablet, start a new session on the same video and let one question turn run. Gilli replies through the second provider. If tracing prints the provider or model id, keep that line on screen. Afterwards, set the line back to Bedrock.

**Beat 9, phone kid mode (phone).** The phone is still in kid mode from beat 2. Tap a video, let one question turn run on the small screen. Then swipe or tap the exit, enter the parent PIN, land on the parent home.

**Beat 10, digest (phone).** Run the Digest agent now rather than waiting for midnight:

```bash
eval curl -s -X POST $BASE/kids/$LISA/digest/run $H | jq .
eval curl -s -X POST $BASE/kids/$RAYAN/digest/run $H | jq .
```

On the phone, open Digest. Lisa's card: minutes, videos, questions, words said, words heard, try today. Rayan's card: minutes, videos, asked, answered, understood, shaky, ask at dinner. The digest is built from the sessions you just ran, so do beats 4 to 7 first.

**Beats 11 to 13** are slides: `docs/architecture.png` and the closing slides.

## 7. If the network dies: demo mode

The Wi-Fi at a recording location is the single most likely failure. Prepare two layers.

**Layer 1, hotspot.** Put the Mac, tablet, and phone on the phone's hotspot before recording starts, and use that IP in the build. Test it once the day before. A hotspot has no client isolation and survives a venue's Wi-Fi going down.

**Layer 2, demo mode.** The spec does not define a demo mode; it should exist before recording day and is a recommendation for the builders, not a description of shipped code. Suggested shape, cheapest first:

1. **Gateway offline fixtures.** Run the gateway with `HEYGILLI_DEMO=1` **[to build]**. Plans, screening results, and digests are served from `agents/fixtures/` JSON captured from real earlier runs. `score_answer` still runs against the configured model if reachable, otherwise falls back to the phonetic rule for band 4_6 and to a fixed "partial" reply for older bands. TTS lines are pre-rendered into the `/tts` cache by a `make warm-tts` step **[to build]** so no Polly call is needed live. In this mode the gateway on the Mac serves everything from disk and only the Mac-to-tablet hop needs to work, which the hotspot covers.
2. **Client canned session.** If even the gateway is unreachable, the app shows a small "Demo" entry behind the parent gate **[to build]** that replays a recorded session (plan, ask, reply messages, and cached mp3s bundled as assets) against the YouTube embed. The embed itself still needs internet for the video; YouTube will not play offline and we do not cache media, by design and by YouTube's terms. So this layer covers a dead gateway, not a dead internet connection.
3. **Footage.** Every take is also recorded with `scrcpy`. If live recording fails completely, the edit uses the earlier day's footage, and the video says so.

Keep the fixture set honest: fixtures are captured outputs from the real agents, saved to disk, and marked with the date they were captured. Do not hand-write a plan or a digest for the fixtures.

## 8. Reset between takes

```bash
# Clear sessions and digests but keep kids, channels, plans   [verify command]
uv run python -m heygilli_agents.reset --keep-plans
```

Or with local JSON storage, delete `data/sessions*.json` and `data/digests*.json` and restart the gateway. Never delete `data/plans*.json` before a take; regenerating plans costs a minute per video per band.

On the tablet: force-stop HeyGilli, reopen, pick the profile again. Confirm the mic permission prompt does not reappear (grant it once during rehearsal).

## 9. Pre-recording check, five minutes before

- [ ] `curl http://<mac-ip>:8080/health` from the tablet browser returns 200.
- [ ] `plan_ready: true` for all three demo videos in both kids' home rows.
- [ ] `/parent/inbox` has exactly one borderline item waiting for beat 3, or is empty with the Curator ready to produce one.
- [ ] `.env` model lines point at Bedrock; Anthropic key present for beat 8.
- [ ] Tablet volume 70 percent, screen pinning on, Do Not Disturb on, brightness fixed.
- [ ] Phone notifications on for HeyGilli only.
- [ ] `scrcpy --record` running.
- [ ] Camera rolling before the child sits down.
