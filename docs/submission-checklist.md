# HeyGilli submission checklist, 5 to 14 September 2026

Deadline: **Monday 14 September 2026, 5:00 PM PT** (that is 5:00 AM PKT on Tuesday 15 September; 2:00 AM CEST on 15 September). Target: submit on Saturday 13 September. Sunday 14 is buffer only.

Rules source: agentsforhumans.devpost.com/rules, read 5 September 2026. Re-read it once on 13 September before pressing Submit.

Judging: 15 September to 8 October. Winners announced on or around 14 October, 2:00 PM PT.

---

## Do today, Friday 5 September

- [ ] Create AWS Builder ID at profile.aws.amazon.com. Save the ID; the Devpost form asks for it.
- [ ] Register for the hackathon on Devpost (agentsforhumans.devpost.com, "Join hackathon"), same email as the Builder ID.
- [ ] Submit the $50 AWS credits request form (Devpost Resources tab). It closes Thursday 11 September, 12:00 PM PT. Do not wait for that day.
- [x] Bedrock model access confirmed in us-east-1; ids pinned in `agents/.env.example` and SPEC 9.5.
- [x] Repo created: github.com/mujahidmasood/heygilli, private. MIT `LICENSE` present.
- [ ] Register heygilli.com or heygilli.io if wanted for the demo link (optional).

## Saturday 6 to Wednesday 10 September: build

Per SPEC section 14. Items that affect the submission only:

- [ ] Day 2: Planner producing plans for the three demo videos. Save the raw outputs; they are the honest fixtures for demo mode.
- [ ] Day 3: first full Buddy turn on the tablet. Record it with `scrcpy` even if rough; it is backup footage.
- [ ] Day 4: real 4-year-old test. Write the numbers down the same day (turns asked, utterances heard, partial or better). They go into `docs/blog-2-child-speech.md` where it says `[TBD from testing]`.
- [ ] Day 5: Curator Graph, borderline push staged, Digest both cards. AgentCore Runtime attempt; hard stop end of day, fall back to in-process on App Runner and say so in README.
- [ ] Day 6: kid-mode home, phone kid mode, gestures. TV only if everything above is done.
- [ ] Decide the second provider for the swap beat: Anthropic direct (default plan) or OpenAI.

## Thursday 11 September

- [ ] **Credits form closes 12:00 PM PT.** If not submitted yet, submit before noon PT (midnight PKT on 11/12 September).
- [ ] Provider eval run on Bedrock and the second provider. Record pass and fail counts; fill `[TBD from testing]` in `docs/blog-1-strands-design.md`.
- [ ] Second child test if possible.
- [ ] README final pass: what shipped, what did not, setup that works from a clean clone, `docs/architecture.png` embedded, link to `docs/PROTOCOL.md`.
- [x] Architecture diagram updated to match what shipped (dashed boxes for anything still planned). Done 6 Sep: six agents, three platforms, the v1.7 routes.
- [ ] Publish builder.aws post 1: `docs/blog-1-strands-design.md`. Title must contain "Agents for Humans". Remove every `[TBD]`. Save the URL.
- [ ] Write the testing instructions and third-party disclosure text in `docs/devpost-submission.md` to match reality.

## Friday 12 September: record

- [ ] Run `docs/demo-runbook.md` section 9 checks, then record all beats per `docs/video-script.md`.
- [ ] Child segments recorded with camera plus `scrcpy` backup. Parent consent noted.
- [ ] Terminal beats recorded: Curator trace, provider swap. Keys redacted.
- [ ] Digest cards recorded from real session data of the day.
- [ ] Build the release APK for the test build. Install it on a device that has never had a debug build and run the click path once.
- [ ] Live demo link check: if the gateway is deployed (AgentCore or App Runner), hit it from a phone on mobile data. If not, the test build plus README is the testing access.
- [ ] Publish builder.aws post 2: `docs/blog-2-child-speech.md`. Title must contain "Agents for Humans". Numbers from the child test filled in, or the sentences removed. Save the URL.

## Saturday 13 September: submit

Do these in order.

1. [ ] Edit the video to under 5:00. Subtitles on the Urdu beat. Export 1080p.
2. [ ] Upload to YouTube as **public**. Title: "HeyGilli: an AI co-watching buddy for kids' YouTube (Agents for Humans hackathon)". Description: repo, test build, both builder.aws links, one line on what is not built. Copy the URL.
3. [ ] Upload the test APK somewhere public and stable (GitHub Release on the repo is simplest: `gh release create v0.1.0-hackathon build/app/outputs/flutter-apk/app-release.apk --title "HeyGilli hackathon build" --notes "Android 12+. See docs/demo-runbook.md."`). Copy the URL.
4. [ ] Final commit of README, docs, and diagram. No secrets in the repo: `git grep -nE 'AKIA|sk-ant-|AIza' -- . ':!*.md'` returns nothing. `.env` is gitignored.
5. [ ] **Flip the repo to public:**
   ```bash
   gh repo edit mujahidmasood/heygilli --visibility public --accept-visibility-change-consequences
   ```
   Then open https://github.com/mujahidmasood/heygilli in a private browser window and confirm README, LICENSE, and `docs/architecture.svg` render.
6. [ ] Fill the Devpost form from `docs/devpost-submission.md`:
   - [ ] Project name: HeyGilli
   - [ ] Tagline (60 chars max)
   - [ ] About the project (all seven sections)
   - [ ] Built with tags
   - [ ] "Try it out" links: repo, test build, live demo if any
   - [ ] Video link (YouTube, public)
   - [ ] Image gallery: `docs/architecture.png`, two or three tablet and phone screenshots, one digest card
   - [ ] Track: Everyday Agents
   - [ ] AWS Builder ID
   - [ ] builder.aws post URLs (two)
   - [ ] Testing instructions
   - [ ] Third-party integrations disclosure
   - [ ] Pre-existing work disclosure (new projects only rule)
   - [ ] Team: solo
7. [ ] Preview the submission page. Click every link from a different device. Play the video to the end.
8. [ ] Submit. Screenshot the confirmation.
9. [ ] Re-read the rules page once. If anything changed since 5 September, fix and resubmit (Devpost allows edits until the deadline).

## Sunday 14 September: buffer

- [ ] No planned work. If something broke, fix it before 5:00 PM PT (5:00 AM PKT Monday night into Tuesday).
- [ ] Confirm the submission still shows as submitted at 4:00 PM PT.

---

## Required items, one line each

| Item | Where | Done |
|---|---|---|
| Strands Agents SDK used for all agent logic | `agents/heygilli_agents/` | [ ] |
| Public repo URL | github.com/mujahidmasood/heygilli | [ ] |
| MIT license visible | `LICENSE` | [x] |
| README with setup instructions | `README.md` | [ ] |
| Architecture diagram | `docs/architecture.svg`, `docs/architecture.png` | [x] drawn, [x] matches what shipped (6 Sep) |
| Text description | `docs/devpost-submission.md` | [x] drafted, [ ] finalised |
| Demo video, 5:00 max, public on YouTube | [ ] URL | [ ] |
| Testing access: test build or live link | GitHub Release APK, gateway URL | [ ] |
| AWS Builder ID | in Devpost form | [ ] |
| Third-party disclosure | in Devpost form | [ ] |
| English materials | all docs English; Urdu only inside the demo, subtitled | [x] |
| builder.aws post 1, "Agents for Humans" in title | [ ] URL | [ ] |
| builder.aws post 2, "Agents for Humans" in title | [ ] URL | [ ] |
| Credits form, by 11 Sep 12:00 PM PT | Devpost Resources | [ ] |
| Live demo link (optional) | [ ] URL | [ ] |

## Cut order if behind, from SPEC section 14

TV stretch, then AgentCore Memory, then phone kid mode (keep phone as parent app only), then provider swap on camera (keep it in the README with a recording), then Urdu for the 9_11 band (keep it for 4_6), then the borderline-video push (keep Curator auto-approve). Never cut: Strands agents, tablet loop with a real child, digest, video, repo hygiene.
