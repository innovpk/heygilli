# Agents for Humans: building HeyGilli, part 1 — the concept and the requirements

This is the first of three posts on how we built HeyGilli for the AWS Agents for Humans hackathon. This one covers the idea and the requirements we wrote before any code. Part 2 is the design: eight agents on the Strands Agents SDK, with code. Part 3 is how we made those agents trustworthy enough to put in front of a family.

## The problem

Kids watch a lot of YouTube, and nearly all of it is passive. Nobody asks them anything. At dinner the question is "What did you watch?" and the answer is "stuff".

Parental controls answer a different question. They decide what a child is allowed to see, and then they do nothing: nothing while the video plays, nothing afterwards. A parent who wants more has two options, and neither scales. They can sit and watch every video themselves, or they can read every new upload from every channel their child likes before it plays.

That second job is the one we wanted to hand to an agent. It is repetitive, it never ends, and most of the time the answer is obvious. Now and then it isn't, and that is exactly when a parent wants to be asked.

## The concept

HeyGilli is a kid-safe front end for YouTube with a co-watching buddy: Gilli, a palm squirrel.

**For the parent, it is an agent that does the busywork.** Setup is a short questionnaire about what is fine in this house. From then on, every new upload on the family's channels is read in the background and checked against those answers. Clear cases are settled without the parent. Borderline ones come to the parent as a question with a reason attached. At the end of the day there is a two-line digest: what was watched, what the child took in, and one thing to ask at dinner.

**For the child, it is a friend on the sofa.** The shelf shows only videos the family's rules allowed: no search, no recommendations. Videos play in the official YouTube player, so ads still play and creators still get paid. At a natural break the video pauses, and Gilli asks one question by voice about what just happened. The child answers by talking or by tapping a picture, Gilli replies, and the video carries on.

## Why this has to be an agent, not an app

The hackathon's brief asked for agents that run in the background and come to a human only when there is a real decision to make. We turned that into a table before writing code, and it became the product's spine:

| The agent does this on its own | It comes to the parent only when |
|---|---|
| Watches the approved channels for new uploads, reads each one, and writes the questions Gilli will ask | An upload is borderline and needs a yes or a no |
| Runs a co-watching session from start to finish: pause, ask, listen, reply, resume, adapt | An approved channel starts publishing something different from what the parent approved |
| Writes the nightly digest and chooses one dinner-table question | The day's time limit is about to run out in the middle of a video |

The right-hand column is short on purpose. Every row we added to it was one more interruption in a parent's day, so each had to earn its place.

## The requirements we wrote down first

Before any code, we wrote a spec with a list of product principles. These principles did more to shape the architecture than any technical choice did, so they are worth listing.

1. **Voice first.** The child never reads instructions. Gilli speaks, and the child speaks or taps back.
2. **Never mock, never fail.** A wrong answer gets curiosity, not correction. Silence is not a failure either: Gilli says the answer and moves on.
3. **Interrupt lightly.** Only a few questions per video, each at a natural break, never in the middle of a sentence.
4. **The parent owns everything.** The parent has the account, child profiles hold no personal data, and a PIN guards leaving kid mode.
5. **Play by YouTube's rules.** Official embed, ads left alone, nothing drawn over a playing video, no downloads.
6. **Bilingual by default.** English and Urdu, because the households we built for speak both, and English-first products leave them out.
7. **Suggest, never enforce.** A model may draft something for a parent, or ask a parent. Only the parent decides.
8. **Never claim more than the data supports.** If a claim can't be backed by the data on the screen showing it, the screen doesn't make it.

Three requirements came out of those principles that we did not expect to matter as much as they did:

- **HeyGilli never removes a channel on its own.** When an approved channel drifts, it raises a card, and that card has no Approve or Hide button because there is no single video to decide about. Removal is always a parent's action. An agent that quietly deletes something a parent chose is an agent that parent stops trusting.
- **Nothing a child says is stored.** What is kept is a score and a ten-word paraphrase. That one rule reaches all the way into the tracing code, as part 3 shows.
- **"Title only" is said out loud.** YouTube does not give transcripts of other people's videos to a server that asks for them. When a video can't be read, it is judged on its title and description, and the parent is told exactly that. The alternative is a verdict that pretends to have watched it.

## The hackathon's own requirements

The rules added a few hard constraints. All agent logic had to use the Strands Agents SDK, and the repo had to be public, with an architecture diagram and a demo video. We added one of our own: every agent had to work on Amazon Bedrock and still fall back to something safe when a model call failed. That last one turned out to matter a great deal. It is the story of part 2.

## What we set out to ship, and what shipped

The scope was the full loop: parent setup, background screening, a live co-watching session with voice questions, and the digest. It had to work end to end, not just in slides.

What shipped:

- The web app, live at heygilli.com, from a single Flutter codebase that also builds for Android and iOS.
- A Python gateway with eight Strands agents on Amazon Bedrock.
- Gilli's voice from Amazon Polly.
- Storage in Amazon DynamoDB.
- A no-login demo of the screening at heygilli.com/try.

We also added two short games with Gilli between videos, and a "check before you allow" feature: a parent pastes a video link they found themselves and gets it read against their own answers first.

## Next

Part 2 opens up the design. It covers why we ended up with eight small agents instead of one big one, what Strands' structured output and `@tool` gave us, the multi-agent Graph we decided not to use, and what happened when the model we had planned around turned out to be one our account could not call.

Code: https://github.com/mujahidmasood/heygilli. MIT.
