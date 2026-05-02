<p align="center">
  <img src="website/assets/hero/desktop.png" alt="A young man sitting under a tree at twilight, a small glowing orange cube floating beside him — distant mountains and town lights below." width="880" />
</p>

<h1 align="center">Nod</h1>

<p align="center"><em>For when you just need to be heard.</em></p>

<p align="center">
  <a href="https://usenod.app"><strong>usenod.app</strong></a> &nbsp;·&nbsp;
  <a href="https://apps.apple.com/in/app/just-nod/id6762388689"><strong>App Store</strong></a> &nbsp;·&nbsp;
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

Most apps that get your words want to *do something* with them. Analyze
them. Classify them. Score your habits. Nudge you toward their KPI.

Sometimes you don't need any of that. Sometimes you just want to talk to
something that listens — not a tool that's trying to fix you, convert you,
grow you, or mine you.

We wanted to build that. A small chat app that's gentle, unintrusive, and
architecturally incapable of leaking a single word of what you say.

## How it's different

### It runs entirely on your phone

No servers. No accounts. No API keys. No login. Every word you type stays
on the device, read only by a model running on the same chip. Out of the
box, that model is Apple's own on-device LLM — **FoundationModels**, part
of Apple Intelligence. Nothing to download. It just works.

If you'd rather run an open-weights model on your phone, open settings and
switch the engine to **Qwen 3 Instruct 2507**, **Qwen 3.5 4B**, or
**Gemma 4 E2B** — all via MLX Swift. When you switch for the first time,
Nod downloads the weights (2–3 GB, Wi-Fi by default) once via Apple's
Background Assets framework. After that, inference is fully offline.

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

Requires an iPhone with Apple Intelligence — **iOS 26.0 or later**. Works
instantly on Apple's on-device model — no extra download needed. If you
switch to an open-weights engine (Qwen or Gemma via MLX) in settings,
Nod downloads the selected model once (2–3 GB, Wi-Fi only by default).
Otherwise, nothing is downloaded; nothing leaves the device.

Available on the App Store as **[Just Nod](https://apps.apple.com/in/app/just-nod/id6762388689)**.

## Repository layout

```
.
├── ios/          Native iOS app — see ios/README.md for build instructions
├── website/      Marketing site at usenod.app
├── prompts/      LLM prompts, shared across platforms
└── LICENSE       MIT
```

For the iOS app's internal architecture, build steps, and engineering
notes, see [`ios/README.md`](ios/README.md). For a repo-wide overview,
see [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Contributing

We welcome contributions. Quickest way in:

- Pick up an issue labeled [`good first issue`](https://github.com/Speculative-Dynamics/nod/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
  or [`help wanted`](https://github.com/Speculative-Dynamics/nod/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22).
- Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup, branch
  conventions, what we're looking for, and what we've decided not
  to build.
- Have a question before filing an issue? Open a
  [Discussion](https://github.com/Speculative-Dynamics/nod/discussions).
- Found a security issue? See [`SECURITY.md`](SECURITY.md) — do not
  file security problems as public issues.

By participating, you agree to follow our
[Code of Conduct](CODE_OF_CONDUCT.md).

## Who built this

[Speculative Dynamics Private Limited](https://usenod.app), a small
company in India. If you'd like to reach us:
[hello@usenod.app](mailto:hello@usenod.app).

## License

[MIT](LICENSE). Do what you want with the code. Attribution is kind but
not required.

---

<p align="center"><sub>Built with care. Runs on your phone. Shipped open.</sub></p>
