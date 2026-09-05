# HeyGilli client ↔ gateway protocol (v1)

Shared contract between the Flutter client (`app/`) and the Python gateway (`agents/`). Both sides build to this file. Change it here first.

Base URL: `http://<host>:8080`. All bodies JSON. Auth: `Authorization: Bearer <token>` from `/auth/dev` (hackathon) — Google sign-in later.

## Enums

- `age_band`: `"4_6" | "7_8" | "9_11"`
- `language`: `"en" | "ur"`
- `question.type`: `"name_it" | "copy_it" | "pick_it" | "recall" | "why" | "predict" | "explain" | "compare" | "apply" | "opinion"`
- `question.input`: `"voice" | "pick" | "copy"`
- `answer.input`: `"voice" | "pick" | "copy" | "none"`
- `result`: `"correct" | "partial" | "off_topic" | "unclear" | "silence"`
- `gesture`: `"idle" | "stretch" | "shrink" | "spin" | "point" | "roar" | "think" | "cheer"`

## REST

```
POST /auth/dev                 {name}                         → {token, household_id}
POST /kids                     {nickname, age, languages[]}   → Kid
GET  /kids                                                    → Kid[]
POST /kids/{kid_id}/channels   {url}                          → Channel   (url = channel URL, @handle URL, or video URL; server resolves)
GET  /kids/{kid_id}/channels                                  → Channel[]
GET  /kids/{kid_id}/home                                      → {rows: [{title, videos: Video[]}]}
POST /sessions                 {kid_id, video_id, device}     → {session_id, video: Video, plan_ready: bool}
POST /sessions/{id}/end                                       → {ok: true}
GET  /kids/{kid_id}/digest?date=YYYY-MM-DD                    → Digest
POST /kids/{kid_id}/digest/run                                → Digest   (runs the Digest agent now; dev convenience)
POST /curator/run              {kid_id}                       → {approved: [...], hidden: [...], ask_parent: [...]}   (dev convenience)
GET  /parent/inbox                                            → ParentPrompt[]   (things the Curator wants a yes/no on)
POST /parent/inbox/{id}        {decision: "approve"|"hide"}   → {ok: true}
```

### Objects

```
Kid        {id, nickname, age, age_band, languages[], avatar}
Channel    {id, title, thumb_url, approved: bool}
Video      {id, channel_id, title, duration_s, thumb_url, age_ok: bool, plan_ready: bool}
Digest     {kid_id, date, minutes, videos, asked, answered,
            understood[], shaky[], words_said[], words_heard[], dinner_prompt, kind: "prereader"|"older"}
ParentPrompt {id, kid_id, video: Video, reason, created_at}
```

## WebSocket `/sessions/{id}/ws`

Client connects after `POST /sessions`. Server drives the loop. All messages `{ "t": "<type>", ... }`.

Client → server

```
{t: "hello"}
{t: "position", seconds: number}                               every ~500 ms while playing
{t: "answer", q: number, input: "voice", transcript: string}
{t: "answer", q: number, input: "pick", option: 0|1|2}
{t: "answer", q: number, input: "copy"}                        kid made a sound / did the action
{t: "answer", q: number, input: "none"}                        listening window elapsed with nothing
{t: "resumed"}                                                 client resumed playback after "resume"
{t: "bye"}
```

Server → client

```
{t: "ready", plan_questions: number, age_band, language}
{t: "pause"}                                                   pause playback now
{t: "ask", q: number, type, input, text?: string, tts_url: string, listen_ms: number,
           options?: [{icon_id, label}], gesture}              text omitted for band 4_6
{t: "reply", text?: string, tts_url: string, result, gesture, model_word?: string}
{t: "resume"}                                                  resume playback
{t: "end", summary_tts_url: string, words_said[]}
{t: "error", message}
```

Ordering per question: `pause` → `ask` → (client `answer`) → `reply` → `resume`. If no `answer` arrives within `listen_ms` + 1500 ms, the server treats it as `input: "none"`.

## TTS

`tts_url` points at `GET /tts/{hash}.mp3` served by the gateway (cached). If TTS is unavailable the URL is empty and the client falls back to on-device TTS using `text` (or `model_word` for 4_6).

## Icon library

`shared/icons.json`: `[{id, concept, en, ur, file}]`. The Flutter app bundles `app/assets/icons/<file>.svg`; the Planner picks `icon_id` only from this list.
