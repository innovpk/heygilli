# HeyGilli client ↔ gateway protocol (v1.7)

Shared contract between the Flutter client (`app/`) and the Python gateway (`agents/`). Both sides build to this file. Change it here first.

Base URL: `http://<host>:8080`. All bodies JSON. Auth: `Authorization: Bearer <token>` from `/auth/google`, or from `/auth/dev` when the server has no Google credentials configured (the fallback stays).

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
POST /auth/dev                 {name}                         → {token, household_id}   (kept as a fallback)
POST /auth/google              {server_auth_code, redirect_uri?}  → Session
GET  /me/youtube                                              → {linked, email}
GET  /me/youtube/subscriptions                                → {linked, subscriptions: Subscription[]}
POST /kids/{kid_id}/channels/import  {channel_ids: [...]}     → {added: Channel[], already: [...]}
DELETE /kids/{kid_id}/channels/{channel_id}                   → {removed: true}
POST /import/takeout           multipart: file=<zip>[, include_history]  → TakeoutPreview
POST /channels/reviews         {channel_ids: [...]}           → {reviews: ChannelReview[], pending: [...]}
POST /channels/drift/check     {channel_ids: [...]}           → {drifted: ChannelDrift[], checked: n}
GET  /channels/{channel_id}/review?refresh=false              → ChannelReview
POST /kids                     {nickname, age, languages[]}   → Kid
GET  /kids                                                    → Kid[]
POST /kids/{kid_id}/channels   {url}                          → Channel   (url = channel URL, @handle URL, or video URL; server resolves)
GET  /kids/{kid_id}/channels                                  → Channel[]
GET  /kids/{kid_id}/home                                      → {rows: [{title, videos: Video[]}],
                                                                 watching_allowed, blocked_reason,
                                                                 active_break: BreakPeriod | null}
POST /kids/{kid_id}/videos/{video_id}/ask  {question, history?: [[q,a]]}  → {answer, answered_from}
POST /sessions                 {kid_id, video_id, device}     → {session_id, video: Video, plan_ready: bool}
POST /sessions/{id}/end                                       → {ok: true}
GET  /kids/{kid_id}/digest?date=YYYY-MM-DD                    → Digest
GET  /kids/{kid_id}/analytics?days=14                         → Analytics
GET  /kids/{kid_id}/policy                                    → Policy
PUT  /kids/{kid_id}/policy     {answers: [...], notes}        → Policy
POST /kids/{kid_id}/policy/questions                          → {questions: [...], based_on: [channel titles]}
GET  /kids/{kid_id}/history                                   → HistoryInsight   (404 if never opted in)
DELETE /kids/{kid_id}/history                                 → {deleted: bool}
GET  /kids/{kid_id}/revisits                                  → {concepts: [...]}
GET  /kids/{kid_id}/words                                     → {words: WordSeed[]}
PATCH /kids/{kid_id}/limits    {daily_minutes, break_after_minutes,
                                break_minutes, max_video_minutes,
                                break_is_firm}                     → Kid
GET  /kids/{kid_id}/state                                     → WatchState
PUT  /kids/{kid_id}/break-messages  {messages: [...]}         → Kid
POST /kids/{kid_id}/break-messages/suggest                    → {suggestions: [...]}  (parent UI only)
POST /kids/{kid_id}/break/ack                                 → BreakPeriod
POST /kids/{kid_id}/break/override  {pin_ok: true}            → {cleared: true}  (parent only)
POST /kids/{kid_id}/digest/run                                → Digest   (runs the Digest agent now; dev convenience)
POST /curator/run              {kid_id}                       → {approved, hidden, ask_parent, stopped_early}   (dev convenience)
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

### Google sign-in and subscription import

The parent signs in with Google; a child never signs in to anything. One consent covers both
identity and `https://www.googleapis.com/auth/youtube.readonly`, which is what lets the parent
import the channels they already follow instead of pasting URLs.

`POST /auth/google` takes the **server auth code** from the client (not an access token),
exchanges it server-side for a refresh token using the *web* OAuth client credentials, and stores
that refresh token against the household. The refresh token never touches the device.

`redirect_uri` says what the code was minted against, because Google's token endpoint requires it
to match and the two platforms differ:

| Where the code came from | `redirect_uri` | Why |
|---|---|---|
| Android or iOS | omitted, or `""` | a native consent has no redirect at all, and sending one is refused |
| A browser | `"postmessage"` | Google's own name for a popup-mode code client; omitting it fails with `invalid_request Missing parameter: redirect_uri` |

Those two are the only values the server accepts. It is not a general passthrough: an arbitrary
redirect from a client is refused rather than forwarded to Google.

```
Session      {token, household_id, email, youtube_linked: bool}
Subscription {channel_id, title, thumb_url, approved_for: [kid_id, ...]}
```

`GET /me/youtube/subscriptions` returns the signed-in account's own YouTube subscriptions
(`subscriptions.list`, `mine=true`, paged 50 at a time, 1 quota unit per page), each marked with
the kids it is already approved for. `linked: false` with an empty list means the household has no
Google link yet, which is a normal state, not an error.

`POST /kids/{kid_id}/channels/import` approves several channels for one kid in a single call and
returns the ones it added versus the ones already approved. Importing does not auto-approve any
video: the Curator still screens each upload, which the server starts in the background so the
response does not wait on it.

Field-level detail the two sides agreed on while building this (shapes above are unchanged):

- `GET /me/youtube` → `{linked: bool, email: string | null}`; `email` is `null` when `linked` is
  false. An imported channel is a plain `Channel`, identical to a pasted one.
- `POST /kids/{kid_id}/channels/import` → `{added: Channel[], already: [channel_id, ...]}`;
  `already` is a list of channel id strings, not objects. Ids repeated in one request count once.
- `POST /auth/google` may carry a bearer token. With one, the Google account is linked to the
  household the parent is already in; without one, the household is derived from the Google
  account, so signing in again returns the same `household_id`.
- Errors the client should expect on these four endpoints: **503** when the server has no Google
  OAuth credentials configured (the message says which env vars are missing; fall back to
  `/auth/dev`), **401 "needs re-linking: …"** when a stored grant was revoked or expired (the
  server drops the link; sign in with Google again), **502** when Google itself is unreachable.
  `GET /me/youtube/subscriptions` never errors for an unlinked or revoked household: it answers
  `{linked: false, subscriptions: []}`.

Two limits worth stating plainly, because they shape the UI:

- The list is whatever the **signed-in account** follows, so the parent should sign in with the
  account the kids actually watch on, usually the one on the TV. On a shared family account those
  subscriptions are effectively the kids' own. It is a starting list to tick through, never an
  auto-approved catalogue.
- A child's subscriptions cannot be read separately. There is no API for a supervised child's
  account, and Family Link exposes none, so the account that signs in decides what the import sees.
- YouTube Kids profile subscriptions are not exposed by any API. Only the signed-in Google
  account's own YouTube subscriptions can be read.

### Takeout import: the children's own profiles

Google's Takeout export is the only route to a child's YouTube Kids subscriptions; no API exposes
them. A parent exports **YouTube and YouTube Music** with the `children` and `subscriptions`
categories, and the zip contains:

```
YouTube and YouTube Music/subscriptions/subscriptions.csv          the parent's own
YouTube and YouTube Music/children/<Profile name>/subscriptions.csv  one per YouTube Kids profile
YouTube and YouTube Music/children/<Profile name>/watch-history.html
YouTube and YouTube Music/children/<Profile name>/search-history.html
```

Each CSV is `Channel ID,Channel URL,Channel title`. The folder name is the child's profile name.

`POST /import/takeout` takes a zip and returns a preview. **Only the subscription CSVs are read**,
and the client enforces that before the network is involved: it opens the picked export on the
device, copies out only members whose path ends in `subscriptions.csv`, and uploads that small zip
instead of the original. Watch history and search history therefore never leave the phone, are never
stored and are never sent to a model. They are the most sensitive files in the export and nothing
here needs them. The server applies the same filter again, so a zip built by anything else is held
to the rule too. It is also the difference between a few kilobytes and a few hundred megabytes over
a phone connection.

```
TakeoutPreview {
  profiles: [{name, channel_count, channels: [{channel_id, title, url}]}],   // from children/
  parent:   {channel_count, channels: [...]} | null                          // from subscriptions/
}
```

The client then lets the parent map each profile to a kid (creating one if needed, since Takeout
carries no age) and import the channels through the existing per-kid import.

### Channel reviews

A child can be subscribed to a hundred channels. `POST /channels/reviews` reviews them in bulk so a
parent can see what each one actually shows.

```
ChannelReview {
  channel_id, title, thumb_url,
  verdict: "good" | "mixed" | "concern" | "unknown",
  summary,                       // one or two sentences on what this channel actually publishes
  flags: [{kind, note}],         // kind: ads_or_merch | consumerism | scary | mature_language
                                 //       | low_quality | off_topic | not_for_kids | unclear
  good_for: ["4_6", "7_8", "9_11"],
  sample_titles: [...],          // the recent uploads the review was actually based on
  reviewed_at, model
}
```

Reviews are a property of the channel, not the kid, so they are cached globally and shared across
households. `POST /channels/reviews` returns whatever is cached immediately and lists the rest in
`pending`; the client polls the same endpoint until `pending` is empty. `refresh=true` on the single
GET forces a re-review.

Two rules the wording must hold to:

- The review is evidence-based. `summary` and `flags` are drawn from the channel's recent upload
  titles and descriptions, and `sample_titles` shows the parent what was actually read. When there
  is too little to go on the verdict is `unknown`, never a guess.
- The review is advice, not a verdict on a creator. The parent decides; `DELETE` removes a channel
  from that kid immediately.

### Time limits and break periods

A parent sets the limits, and a parent decides what happens during the gap. Gilli enforces the
clock and speaks the parent's words. **He never invents an instruction for a child.**

`Kid` gains five settings, parent-editable via `PATCH /kids/{id}/limits`:

```
daily_minutes        total watching allowed per day        (default 60, 0 = no limit)
break_after_minutes  continuous watching before a break    (default 25, 0 = never)
break_minutes        how long the break lasts              (default 5)
max_video_minutes    longest single video offered          (default 0 = no limit)
break_is_firm        true  = the timer must run out        (default true)
                     false = the child may return early
```

Break messages are parent-authored and live on the kid:

```
BreakMessage { id, text, spoken }   // text for 7+, spoken is what Gilli says aloud
```

`PUT /kids/{id}/break-messages` replaces the list. An empty list is a valid, safe state: Gilli then
says only that it is break time and when watching resumes, with no instruction at all.

`GET /kids/{id}/state` is what the client checks before offering anything to watch:

```
WatchState {
  minutes_today, minutes_left_today,
  continuous_minutes,                  // since the last break or a 10-minute gap
  watching_allowed: bool,
  blocked_reason: "daily_limit" | "break" | null,
  active_break: BreakPeriod | null
}

BreakPeriod {
  id, kid_id, started_at, ends_at, seconds_left,
  message: BreakMessage | null,        // whichever of the parent's lines was chosen
  is_firm: bool,
  acked: bool
}
```

**When a break fires.** The server counts continuous watching. Once `break_after_minutes` is
passed it waits for the next natural moment, a question pause or the end of the video, so a child
is never cut off mid-sentence; if none arrives within 3 more minutes it interrupts anyway. The
session socket sends `{t: "break", break: BreakPeriod}` and the client must stop playback.

**No video plays during a break.** `POST /sessions` returns 409 with the active break, and
`GET /kids/{id}/home` sets `watching_allowed: false`. With `break_is_firm` the break ends only when
its timer runs out; `POST /break/ack` records that the child says they are done and earns warm words
from Gilli, nothing more. With `break_is_firm` false the same call ends the break. A parent can
always end one early with `POST /break/override` behind the PIN.

**Suggestions go to the parent, never to the child.** `POST /kids/{id}/break-messages/suggest`
returns candidate lines drawn from what this child actually watches, for the parent to edit, keep or
discard in the parent UI. Nothing suggested reaches a child until the parent saves it. There is no
model call anywhere in the child-facing break path: by the time a break starts, every word Gilli can
say was written or approved by the parent.

### Household policy: what this family actually wants

The Curator screens every upload, but "is this all right for a child" has no general answer. One
household is fine with unboxing videos and not with cartoon peril; the next is the other way round.
Without asking, the Curator applies someone else's taste and the parent has to correct it one video
at a time forever.

```
Policy {
  kid_id, updated_at,
  answers: [{id, question, choice, weight}],   // choice: "fine" | "sometimes" | "rather_not"
                                               // weight: how much this one moved the Curator (0.0-1.0)
  notes: string                                // the parent's own words, free text, may be empty
}
PolicyQuestion { id, question, why, options: ["fine", "sometimes", "rather_not"] }
```

```
GET  /kids/{kid_id}/policy                                    → Policy
PUT  /kids/{kid_id}/policy      {answers: [...], notes}       → Policy
POST /kids/{kid_id}/policy/questions                          → {questions: [...], based_on: [channel titles]}
```

`POST /policy/questions` asks the Coach agent for questions worth asking **this** parent, drawn from
what this child already watches: a household with forty gaming channels gets asked about gaming, not
about make-up tutorials. `why` says which channels prompted the question, so the parent can see it
was not a guess, and `based_on` lists the channel titles the questions were actually drawn from.
An empty `based_on` means there was nothing to draw on — a child with no channels yet gets the
questions every family is asked, and the screen must say so rather than claiming otherwise. Questions are proposed; answers are the parent's alone, and an unanswered question
carries no weight. An empty `Policy` is valid and means the Curator falls back to age-band defaults.

The Curator reads the policy when screening, and a `rather_not` answer is a reason to route a video
to `ask_parent` rather than to hide it silently — the parent stays the decider.

### Watch history: opt-in, aggregate, discarded

By default a Takeout import reads **only** the subscription CSVs and the history files never leave
the phone (above). That default does not change. A parent who wants to know what their child has
actually been watching — as opposed to what they subscribed to years ago — can opt in for one
import, and the terms are narrow:

- The client includes `watch-history.html` only when the parent has ticked that box for that import.
- The server parses it to counts, writes the aggregate below, and **discards the file and every
  video title in it**. Nothing is stored per-video and no video title is persisted.
- Only channel names — never video titles — are ever sent to a model.

```
POST /import/takeout     multipart: file=<zip>, include_history=true   → TakeoutPreview
GET  /kids/{kid_id}/history                                            → HistoryInsight | 404

HistoryInsight {
  kid_id, generated_at, source: "takeout",
  videos, first_watched, last_watched,               // counts and dates, not titles
  top_channels: [{title, videos, subscribed: bool}], // most watched first, at most 20
  unsubscribed_share,                                // 0.0-1.0: how much came from channels they do not follow
  by_hour: [24 integers],                            // when watching happens, local to the export
  summary                                            // two or three sentences, from the aggregate above
}
```

`unsubscribed_share` is the number that matters: a child whose watching is mostly from channels
nobody chose is being fed by the recommender, not by their own subscriptions. The summary says what
the numbers show and nothing else — it makes no claim about a child's character or interests.

A household that never opts in has no `HistoryInsight`, and `GET /kids/{id}/history` answers 404.
Deleting it is one call: `DELETE /kids/{kid_id}/history` → `{deleted: bool}`.

Which kid a profile's history belongs to is something only the parent knows, since Takeout carries
no identity, so the server holds each profile's aggregate against the **profile name** until the
parent says. That is the existing mapping step, and it gains one optional field:

```
POST /kids/{kid_id}/channels/import  {channel_ids: [...], profile?: "Rayan"}  → {added, already}
```

`profile` is the `TakeoutProfile.name` these channels came from. With it, that profile's pending
aggregate becomes this kid's `HistoryInsight` (which is also the first moment `subscribed` and
`unsubscribed_share` can be computed, because they are relative to what this kid now follows) and
the pending copy is deleted. Without it nothing is attached, so an import the parent abandons
leaves counts under a profile name and nothing tied to a child.

Two limits of the parse, stated because they show on the screen. Only a file named exactly
`watch-history.html`, inside a child profile's folder, is ever opened: a localised export yields no
history at all rather than risk opening the search history, and the signed-in parent's own watch
history is never in scope. And the timestamps Google writes are localised, so a non-English export
contributes its counts with no dates and an empty `by_hour`.

### Asking about one video

`POST /kids/{kid_id}/videos/{video_id}/ask` → `{answer, answered_from}`.

The screening writes a few sentences and the parent decides. That is enough when their question is
the one the Curator happened to answer, and no use when it is not — "is the dog hurt in it?", "does
it sell them something at the end?", "why is this one being kept from her?". Those are answerable
from words already cached.

The Explainer is a tool-using agent, because the excerpt it is handed is only the opening of the
video — as much as fits. `search_transcript` reaches the whole transcript, `channel_reputation`
returns what an earlier channel review already found, and `screen_video` is the same rule check the
Curator runs. It is told not to answer "the words don't mention it" without having searched.

Two guarantees are in code rather than in the prompt:

- **`answered_from` is derived from the fetch that actually happened**, never from the model's
  account of itself. A model that can say "I watched it" eventually says so about a video nobody
  could fetch, and that is the one claim on this screen a parent has to be able to trust. The
  values are `the words of the video`, `the title and description only`, and `nothing`.
- **`search_transcript` distinguishes "not in the video" from "nobody read the video"** via
  `searched_whole_video`. They are opposite answers to a parent and a tool that returns
  `found: false` for both invites the confident wrong one.

Nothing here decides anything: no verdict moves and no shelf changes. It is information for
somebody about to decide, and the switch stays theirs.

Stateless. `history` is the earlier turns of the same conversation, oldest first, held by the
client — there is no reason to keep a record of what a parent was worried about, and every reason
not to, including that it would then have to be deleted with the child.

### Channel drift: a channel is not what it was

A review is a snapshot. Channels change hands, chase trends, and start running gambling ads two
years after a parent approved them. `reviewed_at` is on every `ChannelReview` for this reason.

```
POST /channels/drift/check   {channel_ids: [...]}   → {drifted: ChannelDrift[], checked: n}

ChannelDrift {
  channel_id, title,
  was:  {verdict, flags: [...], reviewed_at},
  now:  {verdict, flags: [...], reviewed_at},
  worse: bool,                    // the verdict moved toward concern, or a new flag appeared
  what_changed,                   // one sentence naming the difference, not restating the review
  sample_titles: [...]            // the new uploads that changed it
}
```

Only `worse: true` drifts are surfaced to a parent; a channel that improved is not something anyone
needs to be interrupted about. A drift raises an entry in `GET /parent/inbox` naming the channel and
what changed, and the parent decides. **HeyGilli never removes a channel on its own** — a drift is
information, and removal stays a `DELETE` the parent makes.

Re-review is rate-limited server-side to at most once a week per channel; `checked` says how many
were actually re-read rather than answered from cache. One call re-reads at most ten channels, since
each is a feed fetch and a model call; the rest stay due and the next call takes them.

A drift is never inferred from an `unknown`: a channel whose feed could not be read today says
nothing about whether it changed, so the parent keeps the review they had and no card is raised.

Because the inbox now carries two kinds of thing, `ParentPrompt` gains a discriminator. Both
payload keys are always present, one of them null:

```
ParentPrompt {id, kid_id, kind: "video" | "channel_drift",
              video: Video | null, drift: ChannelDrift | null, reason, created_at}
```

`POST /parent/inbox/{id}` on a `channel_drift` entry records the parent's answer and closes the
card. It never removes the channel — neither decision does, because removal is a `DELETE` the
parent makes.

### Revisiting a shaky concept

Analytics already knows which concepts a child was shaky on (`needs_another_look`). Acting on it is
one field: the Planner may seed one question about an earlier concept into a later video's plan.

```
Question gains:  revisit: {concept, last_seen} | null     // null on all but at most one question per plan
GET /kids/{kid_id}/revisits                               → {concepts: [{concept, times_shaky, last_seen, asked_again}]}
```

Rules, because a child noticing they are being retested is the failure mode:

- At most **one** revisit question per session, never the first question, and never two sessions in
  a row about the same concept.
- It is asked as a fresh question about the new video, not as "remember when you got this wrong".
  The `revisit` field is bookkeeping for the parent's screen; nothing in `text` refers to the past.
- A concept the child gets right twice leaves the list. Nothing is ever asked a third time.

Two clarifications the server side needed. Plans are cached per (video, band, language) and shared
by every household, so a revisit is **never written into the cached plan**: it is seeded into a copy
when the session's socket opens, which is also why `revisit` does not appear on the `ask` message —
it is bookkeeping for the parent, and nothing the device receives says a question is a second
attempt. And `asked_again` counts a revisit that actually went out to the child, so a session they
left before reaching it does not use up one of the two chances that concept gets.

There is no fallback question. A revisit has to be answerable from the video just watched, so when
the model is unavailable, or says this video gives no honest way to ask, the session simply runs
without one. Bands 7_8 and 9_11 only: a pre-reader's plan has no concepts.

### Bilingual word seeding

For a kid whose `languages` include `ur`, Gilli may offer the Urdu word for something the child has
just shown they understand in English, then ask for it in a later session. This is the one place the
product teaches rather than checks, and it is opt-in by virtue of the language list.

```
Question gains:  word: {term, language, gloss, first_heard: bool} | null

WordSeed {kid_id, term, language, gloss, times_heard, times_said, first_heard, last_heard}
GET /kids/{kid_id}/words                → {words: WordSeed[]}
```

The existing analytics vocabulary (`said` / `emerging`) is the same data seen from the parent's side:
`emerging` is exactly a `WordSeed` with `times_said == 0`.

Rules:

- At most one new word per session. A child who hears six new words remembers none.
- Never a word for a concept the child has not already got right in their stronger language.
- Polly has no Urdu voice, so an Urdu term falls back to on-device TTS (see **TTS**); a device with
  no Urdu voice installed gets the English question with no seed rather than a silent one.

How the server delivers it. The term is never a translation a model made: it comes from
`shared/icons.json`, which already carries an `en` and a `ur` for every concept, matched **exactly**
(the fuzzy `find_icon` lookup is right for picking a picture and wrong for teaching a word). The
ask-back question is written in code from that same entry, so nothing unreviewed reaches a child.

The offer arrives on the reply, not inside its text, because Polly cannot say it:

```
{t: "reply", ..., word?: {term, language, gloss, first_heard}}
```

`word` is present only after a **correct** answer to a seeded question — the word is for something
the child has just shown they understand. A client with no voice for `language` simply leaves it
out; the child still gets the English reply, never a silence. The ask-back needs no wire change: it
is an ordinary question in the language the child is watching in, whose expected answer is the term.

Also, since one special question per session is the limit: a word ask-back gives way to a revisit
that is already in the plan.


### Analytics

`GET /kids/{kid_id}/analytics?days=14` (days: 7-90, default 14). Everything is derived from
Sessions, Answers and question plans. It never exposes anything a child said beyond the single
words Gilli asked for and the paraphrase already stored.

```
Analytics {
  kid_id, band, days, generated_at,
  totals:   {minutes, videos, sessions, asked, answered, answer_rate},   // answer_rate 0.0-1.0
  daily:    [{date, minutes, videos, asked, answered}],   // oldest first, missing days filled with zeros
  vocabulary: {                                           // meaningful for band 4_6
    total_said, new_this_week,
    said:     [{word, times_said, first_said}],           // most recent first
    emerging: [{word, times_heard}]                       // Gilli modelled it, the kid has not said it yet
  },
  concepts: [{concept, asked, understood, shaky, last_seen}],  // bands 7_8 / 9_11
  needs_another_look: [{concept, times_shaky, last_seen}],     // shaky on 2+ separate days
  channels: [{channel_id, title, minutes, videos}],            // most minutes first
  note: {kind, text}                                           // kind: praise | suggestion | watch | quiet
}
```

`note` is one or two plain sentences written by the Digest agent about what changed and what the
parent could do. `kind: "quiet"` means there is nothing worth acting on, and the client shows it
in a muted style rather than as an alert. The note never shames the parent or the child and never
compares one kid to another.

Empty history is a valid response: zeros, empty lists, and a `quiet` note.

## WebSocket `/sessions/{id}/ws`

Client connects after `POST /sessions`, sending the bearer token as an `Authorization` header on the upgrade (servers may ignore it in dev). The client sends `hello` only after it is subscribed to the socket; the server must not emit `ready` before `hello`. Server drives the loop. All messages `{ "t": "<type>", ... }`.

Client → server

```
{t: "hello"}
{t: "position", seconds: number}                               every ~500 ms while playing
{t: "answer", q: number, input: "voice", transcript: string}
{t: "answer", q: number, input: "pick", option: 0|1|2}
{t: "answer", q: number, input: "copy"}                        kid made a sound / did the action
{t: "answer", q: number, input: "none"}                        listening window elapsed with nothing
{t: "repeat", q: number}                                       say the question again, once (SPEC 7.4)
{t: "resumed"}                                                 client resumed playback after "resume"
{t: "bye"}
```

Server → client

```
{t: "ready", plan_questions: number, age_band, language, question_times: number[]}
           question_times = the seconds the questions are scheduled for, so the client can show
           the child where they are coming. The client still never decides when to ask.
{t: "pause"}                                                   pause playback now
{t: "ask", q: number, type, input, text?: string, text_ur?: string, speak?: string,
           tts_url: string, listen_ms: number, options?: [{icon_id, label}], gesture}
           text omitted for band 4_6; speak = what on-device TTS says when tts_url is empty
           (needed for 4_6 where text is absent); text_ur = Urdu line shown beside text for 7+
{t: "reply", text?: string, tts_url: string, result, gesture, model_word?: string}
{t: "resume"}                                                  resume playback
{t: "end", summary_tts_url: string, summary_text?: string, words_said[]}   summary_text = on-device TTS fallback
{t: "break", break: BreakPeriod}                                stop playback; the session then ends
{t: "error", message}
```

A `break` is followed immediately by `end` and the socket closes: the session is over and the next
`POST /sessions` is a 409 until the break's clock runs out. It can arrive instead of an `ask` at a
question pause, at the end of the video, or on its own three minutes after the limit passed. The
409 body is the same shape for both reasons a session is refused:

```
409 {"detail": {"error": "break" | "daily_limit", "state": WatchState}}
```

`WatchState.minutes_left_today` is **null**, not 0, when the kid has no daily limit
(`daily_minutes: 0`); `watching_allowed` is always the real gate. `POST /break/override` answers
`{cleared: false}` when no break was running, and `POST /break/ack` is a 404 when nothing is.

(The break payload itself is the one open question — see the conflict note in "Time limits and
break periods" above.)

Ordering per question: `pause` → `ask` → (client `answer`) → `reply` → `resume`. If no `answer` arrives within `listen_ms` + 1500 ms, the server treats it as `input: "none"`.

A `repeat` for the question in flight is answered with the same `ask` again and restarts that window from the moment it arrives — a child asks because they are stuck, which is to say late, so topping up what was left would read them the question and then cut them off anyway. One per question (SPEC 7.4 "never repeat a question more than once"); past that, and for any `q` that is not the live one, it is ignored. The client must not replay the question on its own: the deadline lives on the server, and a device replaying it would be talking over a `reply` and a `resume` already in flight.

## TTS

`tts_url` points at `GET /tts/{hash}.mp3` served by the gateway (cached). If TTS is unavailable the URL is empty and the client falls back to on-device TTS using `text` (or `model_word` for 4_6).

## Icon library

`shared/icons.json`: `[{id, concept, en, ur, file}]`. The Flutter app bundles `app/assets/icons/<file>.svg`; the Planner picks `icon_id` only from this list.


### Search, and the line it does not cross

`search_enabled` is a per-kid setting, off until a parent turns it on
(`PATCH /kids/{id}/limits`). With it on, `GET /kids/{id}/home?q=` filters the
videos **already approved for that child** and can return nothing else. There is
no code path from a child's query to YouTube's search, and there must not be:
the allowlist is the product, and a search box that could return anything would
undo it. `home` answers `searchable` so the client knows whether to draw the box
at all; a query from a kid whose parent left it off is ignored, not refused.

A pre-reader (band `4_6`) never sees the box even when the setting is on. They
cannot read it or type into it, and no other screen in the product shows them
text.

### The language a child actually speaks

The Curator hides a video whose captions are in a language outside the kid's
`languages`. It is decided in code from the caption language code, not asked of
a model, because it is a fact and because a model reading a Cyrillic title has
been happy to approve it for an English-speaking five-year-old. An unknown
language is not a reason to hide: plenty of children's videos have captions
disabled, and refusing everything unidentifiable would empty the shelf.

### Session socket

`ws /sessions/{id}/ws` takes the household token as the **`token` query
parameter**. Not a header: a browser cannot set headers on a WebSocket at all,
so a header-only client works on a phone and silently never connects on the
web — the session is created over REST and then nothing ever drives it, which
looks exactly like a video that simply never asks a question.


### One voice, including the lines the client writes

Session lines arrive with a `tts_url` already. Several screens are composed on
the device, though — the end of the day, an empty shelf, and the break lines a
parent typed — and those were falling straight through to on-device TTS. On a
phone that is passable; in a browser it is the operating system's robot, and it
is the first thing anyone says about the app.

`POST /tts {text, language?, slow?}` returns `{url}` for the same cached mp3 a
session line gets. The text is capped at 300 characters: every real caller is a
sentence or two, and this mints Polly requests.

`{"url": ""}` is a normal answer, not an error — the client then speaks the
words on-device exactly as before. A screen going silent because Polly is down
would be worse than a plain voice.
