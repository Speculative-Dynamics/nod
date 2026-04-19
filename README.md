<p align="center">
  <img src="website/assets/og-image.jpg" alt="A young man sitting under a tree at sunset, a small glowing orange cube spirit floating beside him — a watercolor painting." width="880" />
</p>

<h1 align="center">Nod</h1>

<p align="center"><em>For when you just need to be heard.</em></p>

<p align="center">
  <a href="https://usenod.app"><strong>usenod.app</strong></a> &nbsp;·&nbsp;
  <a href="https://apps.apple.com/us/app/">App Store</a> &nbsp;·&nbsp;
  <a href="LICENSE">MIT License</a>
</p>

---

## What Nod is

Nod is a small iOS app. You open it, and you see a quiet orange face that
blinks, slowly, once every few seconds. Underneath, two words:
*I'm listening.*

You type what's on your mind — or tap the mic and talk. A small AI model,
running entirely on your phone, reads what you wrote and writes back the way
a careful friend would. No advice. No cheerleading. No productivity journey.
No "how can I help you today?"

Sometimes, you don't even want a reply. There's a little orange face under
the message field — tap it, and the eyes blink slowly, once. No words. Just
the quietest possible *"I heard you."*

That's the whole app. That's why it's called Nod.

## Why we built it

Most apps built around mental health or wellness want to *do something* with
your words. Analyze them. Classify them. Track your mood. Score your
journey. Nudge you toward their KPI.

Sometimes you don't need any of that. Sometimes you just need to be heard —
by a presence that isn't trying to fix you, convert you, grow you, or mine
you.

We wanted to build that. A companion that's gentle, unintrusive, and
architecturally incapable of leaking a single word of what you say.

## How it's different

### It runs entirely on your phone

No servers. No accounts. No API keys. No login. Every word you type stays
on the device. The listening model (**Qwen 3.5 4B**) runs on-device via
MLX Swift. Memory and summaries are handled by Apple's own on-device LLM
(**FoundationModels**, part of Apple Intelligence).

We don't see what you write. **No one does.** Not because we promise —
because there is no pipe to send it through.

### There is nothing to collect

The app has no analytics, no telemetry, no tracking pixels, no third-party
SDKs for ads, attribution, or A/B testing. Your conversation sits in a
local SQLite database on your device, encrypted at rest by iOS. Tap
"Start fresh" and it's gone, irreversibly.

### No onboarding. No performance.

When you open Nod, it blinks. And waits. There's no tutorial, no suggested
prompts, no sign-in flow. Start typing when you're ready. Or don't. Nod
is in no rush.

### Open source

Every line is MIT-licensed and sits in this repo. The Swift, the system
prompts, the database migrations, the website copy — all of it. If
"trust us" bothers you, verify us. Read the code. Build it yourself if
you want.

## The listening prompt

The whole behavior of the app is shaped by a single instruction we give
the model. Here's a piece of it:

> Your job is not to solve problems.
> Speak like a real person who cares.
> Never cheerleade.
> Real presence doesn't announce itself.

## Getting it

Nod will be listed on the App Store as **Just Nod** — the name *Nod*
alone was taken, and besides, it matches the in-app button.

Requires an iPhone with Apple Intelligence — **iOS 26.0 or later**. On
first launch, the app downloads the Qwen model weights (~2.5 GB) once via
Apple's Background Assets framework. After that, it works fully offline.

A link to the App Store listing will appear at
[usenod.app](https://usenod.app) once the app ships.

## Repository layout

```
.
├── ios/          Native iOS app — see ios/README.md for build instructions
├── website/      Marketing site at usenod.app
└── LICENSE       MIT
```

For the iOS app's internal architecture, build steps, and engineering
notes, see [`ios/README.md`](ios/README.md).

## Who built this

[Speculative Dynamics Private Limited](https://usenod.app), a small
company in India. If you'd like to reach us:
[hello@usenod.app](mailto:hello@usenod.app).

## License

[MIT](LICENSE). Do what you want with the code. Attribution is kind but
not required.

---

<p align="center"><sub>Built with care. Runs on your phone. Shipped open.</sub></p>
