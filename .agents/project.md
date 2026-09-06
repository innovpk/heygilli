# HeyGilli — Project Manifest

**What it is:** An AI co-watching buddy for kids' YouTube. A squirrel called Gilli watches
alongside a child, pauses at a natural break, asks one question about what just happened,
listens to the spoken answer, and replies. A parent gets a digest of what was understood and
what was shaky. Built for the Agents for Humans hackathon (AWS × Devpost, Everyday Agents
track, deadline **14 September 2026, 5:00 PM PT**); Strands Agents SDK is mandatory there.

**Target users:** parents in Pakistan and the diaspora, and their 4–11-year-olds. The child
never signs in, never types, and under 7 never sees text at all — everything they get is
spoken. Urdu/English bilingual households are the design centre, not an afterthought.

**The rule the whole product bends around:** *the app never enforces anything and never
decides anything on a parent's behalf.* It can suggest; a parent approves. Break-time
messages are sentences a parent typed, read out verbatim. A channel that drifts raises a
card, it is never removed. Watch history is off until someone ticks a box, per import.
If a screen is about to claim something the data does not support, that is a bug of the
first rank — it has shipped three times (see Conventions).

**Stack:**
- Client: `app/` — Flutter 3.41 / Dart 3.11. Android, iOS and web all build and run.
- Agents + gateway: `agents/` — Python 3.12, Strands Agents SDK, FastAPI (uvicorn, port 8080).
- Models: Amazon Bedrock, us-east-1. Every model call has a deterministic fallback.
- Contract: `docs/PROTOCOL.md` (currently **v1.7**) is the authority for both halves.

## Layout (paths relative to project root)
- App dir: `app` (native shells in `app/android`, `app/ios`; web shell in `app/web`)
- Backend: `agents` (`heygilli_agents/` package, `tests/`, `eval/`, `scripts/`)
- Contract + submission docs: `docs/` · Product spec: `SPEC.md` · Design: `design/`

## Commands
- Gateway (start this first; nothing in the app works without it):
  `cd agents && uv run python -m uvicorn heygilli_agents.gateway:app --port 8080` → `/healthz`
- Dev/run web: `cd app && flutter run -d web-server --web-port 5601` → http://localhost:5601
- Dev/run Android: `cd app && flutter run -d <emulator>` (host is **10.0.2.2**, not localhost)
- Dev/run iOS: `cd app && flutter run -d <simulator udid>` (host is localhost)
- Build: `flutter build web` · `flutter build apk` · `flutter build ios --simulator`
- Test: `cd app && flutter test` **and** `cd agents && uv run pytest -q` — both, always.

## Conventions
- **`docs/PROTOCOL.md` is the contract.** Change it first, then both halves. A field added on
  one side only is invisible to every test on both sides.
- **Green suites on both halves prove nothing about the seam between them.** This has bitten
  twice: the client silently never sent `profile` on import, so a watch-history aggregate
  never attached to any child; and channel-drift inbox entries rendered blank with Approve
  and Hide buttons that did not apply. Both suites were green throughout. Client tests must
  use payloads captured from the **running** gateway, never fixtures hand-written to match
  the parser they are testing.
- **A screen must never claim more than its data supports.** Shipped three times: a digest
  praising questions nobody answered; a policy header saying the questions came from this
  child's channels when they were generic; a break screen implying Gilli could tell whether
  a child stood up. If the client has to *infer* the claim, the gateway should be sending
  the fact instead (this is what `based_on` on the policy payload is for).
- **No invented children anywhere.** No fake kid names in code, fixtures, screenshots or
  docs — a real household's names, or none.
- Privacy claims are enforced by mutation-tested assertions, not by comment. The watch-history
  test spies the store's write primitive *and* re-reads every persisted JSON byte off disk,
  and genuinely fails when a video title leaks.
- Anthropic models on Bedrock are **gated** on this account pending the use-case form; the
  interim default is `bedrock:us.amazon.nova-pro-v1:0` and every feature falls back to a
  built-in when a model call fails. `agents/.env.example` records the exact errors.
