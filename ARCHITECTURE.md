# Architecture

A short map of the whole repo. Use this to orient yourself before
diving into a specific sub-project.

For the deep Swift-internal tour, see [`ios/README.md`](ios/README.md).
For the product story, see [`README.md`](README.md).

## Top-level layout

```
nod/
├── ios/          Native iOS app (SwiftUI, iOS 26+)
├── website/      Marketing site — static HTML/CSS, deployed to usenod.app
├── prompts/      LLM system prompts, shared across platforms
├── README.md     Product overview
├── ARCHITECTURE.md  ← you are here
├── CONTRIBUTING.md  How to contribute
├── CODE_OF_CONDUCT.md
├── SECURITY.md   Responsible disclosure
├── CHANGELOG.md
└── LICENSE       MIT
```

Three things live at the repo root rather than inside `ios/` because
they are platform-neutral:

- **`prompts/`** — the listening-mode prompt, the chapter-note prompt,
  and the banned-phrase list. Any future platform (web, Android)
  reads the same text. XcodeGen copies these into the iOS app bundle
  as a folder resource (see `ios/project.yml`).
- **`website/`** — the marketing site. Pure static, deployed via
  GitHub Pages (`.github/workflows/pages.yml`).
- **Docs** — README, CONTRIBUTING, SECURITY, CHANGELOG. Public-facing.

## Data flow

The app is single-user, local-only. No server. The diagram below is
the full data flow for one send-and-respond turn:

```
 ┌──────────────────────────────────────────────────────────┐
 │  User                                                    │
 │    types text OR taps mic and speaks                     │
 └──────────────────┬───────────────────────────────────────┘
                    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  ChatView (SwiftUI)                                      │
 │    - Text field: SwiftUI TextField                       │
 │    - Voice: DictationRecognizer (iOS 26 SpeechAnalyzer)  │
 │      both feed into the same send path                   │
 └──────────────────┬───────────────────────────────────────┘
                    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  ConversationStore                                       │
 │    - Appends user Message to SQLite (GRDB)               │
 │    - Builds the prompt: listening_mode + personalization │
 │      + memory (ConversationMemory) + recent turns        │
 └──────────────────┬───────────────────────────────────────┘
                    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  EngineHolder (router)                                   │
 │    Routes to one of:                                     │
 │      - FoundationModelsClient   (Apple Intelligence)     │
 │      - MLXEngineClient          (Qwen 3 / 3.5 / Gemma 4) │
 │    based on EnginePreference and device capability.      │
 └──────────────────┬───────────────────────────────────────┘
                    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  On-device LLM                                           │
 │    - AFM:  Apple's private framework, no weights on disk │
 │    - MLX:  ~2-3 GB weights downloaded once via Background │
 │            Assets, live on the app group container       │
 │    Streams response tokens back.                         │
 └──────────────────┬───────────────────────────────────────┘
                    ▼
 ┌──────────────────────────────────────────────────────────┐
 │  ChatView                                                │
 │    Renders assistant Message token-by-token as it streams│
 │ ConversationStore                                        │
 │    Persists the final response to SQLite                 │
 │    If the verbatim backlog grows past a threshold, the   │
 │    oldest batch gets a write-once chapter note and ages  │
 │    out, so context stays bounded                         │
 └──────────────────────────────────────────────────────────┘
```

**Key property:** nothing leaves the device. No network call happens
during a turn. The only network use in the whole app is the one-time
model download from our R2 CDN (public, read-only, model weights
only — no user data is ever sent).

## The iOS app — one-line tour

If you want to fix something, here is where to look:

- **Main screen** → `ios/Nod/Views/ChatView.swift`
- **Voice input** → `ios/Nod/Inference/DictationRecognizer.swift`
- **Which model runs** → `ios/Nod/Inference/EngineHolder.swift`
- **On-device LLM clients** → `FoundationModelsClient.swift`, `MLXEngineClient.swift`
- **Model download** → `ios/Nod/Inference/MLXR2BackgroundSession.swift`
- **Persistence** → `ios/Nod/Storage/MessageDatabase.swift` (GRDB/SQLite)
- **Memory** → `ios/Nod/Storage/ConversationMemory.swift` (see "Memory" below)
- **Reply quality evals** → `ios/evals/` (run `ios/evals/runner/run.sh`)
- **Face ID lock** → `ios/Nod/AppLock/`
- **The orange face everywhere** → `ios/Nod/Views/NodMascot.swift`

The full annotated tree with what each file does is in
[`ios/README.md`](ios/README.md).

## The website

`website/` is pure static HTML/CSS/JS, no build step. The GitHub
Actions workflow at `.github/workflows/pages.yml` deploys it to
GitHub Pages which serves [usenod.app](https://usenod.app) via the
custom domain set in `website/CNAME`.

Sub-pages:

- `/` — landing page (`index.html`)
- `/privacy/` — privacy policy (required by App Store)
- `/terms/` — terms of service

## The prompts

`prompts/` is the text that shapes how Nod behaves:

- **`listening_mode.md`** — the main system prompt. This is the
  product's personality. Changes here ripple into every response.
  It deliberately has no example dialogue: the on-device model copies
  example lines and names into real replies.
- **`chapter_note.md`** — prompt for the short note written about each
  stretch of conversation as it ages out of the verbatim window.
- **`banned_phrases.txt`** — support-bot phrases the reply guard strips.

If you change a prompt, run `ios/evals/runner/run.sh` (and
`--suite memory` for memory changes) before and after, add a case
that captures the change, and reference the results in your PR.

## Memory

Nod remembers in two ways, both on-device (`ConversationMemory`):

- **The user's own words.** On every send, the user's older messages
  are searched (`PastMessageRecall`: content words, rarer ones weighted
  higher, relationship synonyms like boss/manager) and the best few are
  shown to the model verbatim with how long ago they were said. This is
  where specifics come from. Nothing is paraphrased, so nothing can be
  invented, and newer messages win over older ones.
- **Chapter notes.** When older messages age out of the verbatim
  window, the model writes a short note about that stretch, once, never
  rewritten. `MemoryGrounding` deletes any sentence naming a person or
  place the user never mentioned. The latest note is always in context
  for continuity; older notes only when relevant. Notes are what the
  Memory screen shows; deleting one also stops recall of that stretch.

Memory is labelled "don't bring it up unless they do" and only
relevant pieces are included, so Nod doesn't volunteer old topics.

This replaced a rolling summary plus per-exchange entity extraction.
Evals showed both invented details on the on-device model (names
copied from prompt examples, people that were never mentioned) and
extraction cost a model call per exchange. See CHANGELOG.

## CI / CD

Two GitHub Actions workflows:

- **`.github/workflows/ios.yml`** — iOS build verification on every PR
  touching `ios/**` or `prompts/**`. Uses Xcode 26 + iPhone 17 Pro
  Simulator + SPM cache. No signing, no tests, no archive. Build-only.
- **`.github/workflows/pages.yml`** — deploys `website/` to GitHub
  Pages on push to `main`.

There is no release automation yet. App Store submission is manual
via Xcode → Product → Archive.

## What's not here

Explicitly by design:

- No server code. No API. No database other than the user's local
  SQLite.
- No analytics SDK. No telemetry. No crash reporting SDK.
- No account / login / auth system.
- No push notifications.
- No cloud sync (iCloud backup is opt-in and uses Apple's standard
  backup, not our infrastructure).

If you open a PR that adds any of the above, please read
[`CONTRIBUTING.md`](CONTRIBUTING.md) first — those are intentional
constraints, not gaps.
