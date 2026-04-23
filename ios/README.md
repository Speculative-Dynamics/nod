# Nod — iOS app

Native SwiftUI app. iOS 26+ deployment target. All inference runs on-device —
Apple FoundationModels for memory and summarization, MLX Swift for the
listening model (Qwen 3, Qwen 3.5, or Gemma 4 E2B).

Product positioning and "why" live in [the repo root README](../README.md).
This file is for anyone building or hacking on the iOS code.

## Prerequisites

- macOS with **Xcode 16+**
- **XcodeGen** installed (`brew install xcodegen`) — only needed if you edit `project.yml` and want to regenerate `Nod.xcodeproj`
- Apple Developer account (Organization tier for App Store distribution; Personal tier works for local device installs with a 7-day provisioning profile)
- **iPhone 15 Pro or later** for on-device testing — required for Apple Intelligence (FoundationModels) and to fit MLX 4B model weights in memory
- Apple Intelligence enabled in Settings → Apple Intelligence & Siri on the test device

## Build and run

```bash
git clone git@github.com:Speculative-Dynamics/nod.git
cd nod/ios
open Nod.xcodeproj          # the project is committed, no generation needed
```

In Xcode: select your iPhone as the run destination, pick your Team in
Signing & Capabilities on the `Nod` target, then `Cmd+R`.

**Command-line build verification:**

```bash
xcodebuild -scheme Nod \
  -destination 'generic/platform=iOS' \
  build
```

**If you edit `project.yml`** (changing dependencies, targets, or build
settings), regenerate the Xcode project:

```bash
cd ios && xcodegen generate
```

`Nod.xcodeproj` is committed so a fresh clone builds without needing
XcodeGen installed.

## Source layout

```
vent/
├── prompts/                         # ALL LLM prompts (repo root, reusable across platforms)
│   ├── listening_mode.md            # THE listening-mode system prompt
│   ├── summary.md                   # running-summary compression prompt
│   └── entity_extraction.md         # memory entity extraction prompt
│
└── ios/
    ├── README.md                    # you are here
    ├── project.yml                  # XcodeGen source of truth
    ├── Nod.xcodeproj/               # committed so first-clone builds
    ├── Nod.xcscheme                 # shared scheme
    ├── evals/
    │   └── listening-mode/          # vent-transcript regression fixtures
    └── Nod/                         # Swift source
        ├── NodApp.swift             # @main, SwiftUI App entry point
        ├── AppDelegate.swift        # background-URLSession re-attachment
        ├── LaunchCrashBreaker.swift # crash-loop recovery on cold launch
        ├── Info.plist               # launch screen, permissions
        ├── Nod.entitlements         # memory + app-group capabilities
        ├── AppLock/
        │   ├── AppLockManager.swift    # Face ID state + auth flow
        │   └── AppLockOverlay.swift    # locked-screen UI
        ├── Inference/
        │   ├── InferenceEngine.swift           # shared protocol + error enum
        │   ├── EngineHolder.swift              # routes between AFM and MLX
        │   ├── EnginePreference.swift          # which model the user picked
        │   ├── FoundationModelsClient.swift    # Apple on-device LLM (AFM)
        │   ├── MLXEngineClient.swift           # MLX, parameterized by model spec
        │   ├── MLXModelSpec.swift              # Qwen 3 / Qwen 3.5 / Gemma 4 specs
        │   ├── MLXR2BackgroundSession.swift    # Background-Assets-style download
        │   ├── DownloadEvent.swift             # UI event enum from downloader
        │   ├── DownloadMetrics.swift           # progress numbers for the card
        │   ├── DownloadTuning.swift            # throttle + retry parameters
        │   ├── SpeedWindow.swift               # rolling-average download speed
        │   ├── DictationRecognizer.swift       # iOS 26 SpeechAnalyzer wrapper
        │   ├── EntityExtractorService.swift    # FoundationModels memory extraction
        │   └── ExtractedEntity.swift           # @Generable schema for memory
        ├── Storage/
        │   ├── Message.swift                   # data model
        │   ├── MessageDatabase.swift           # GRDB.swift SQLite persistence
        │   ├── ConversationStore.swift         # store + running summary + compression
        │   ├── Entity.swift                    # memory entity record
        │   ├── EntityStore.swift               # entity CRUD + semantic search
        │   └── EntityEmbedder.swift            # NLEmbedding vector gen
        ├── Personalization/
        │   └── PersonalizationStore.swift      # sidebar toggles + free-form field
        ├── Views/
        │   ├── ChatView.swift                  # main chat screen
        │   ├── EmptyStateView.swift            # zero-messages first-launch view
        │   ├── SidebarView.swift               # settings + memory + danger-zone
        │   ├── MemoryView.swift                # browse and purge entity memory
        │   ├── SplashView.swift                # 2s cold-launch animation
        │   ├── NodMascot.swift                 # canonical face + eye + blinker
        │   ├── MiniNodFace.swift               # nav-bar mascot wrapper
        │   └── NodAnimation.swift              # bubble eye-blink + thinking-scan
        ├── Assets.xcassets/
        │   ├── AppIcon.appiconset/             # home-screen icon (1024pt master)
        │   └── NodAccent.colorset/             # brand orange, light + dark values
        └── Preview Content/                    # SwiftUI preview resources
```

Prompts live at the repo root so website and future platforms can read
the same text. XcodeGen copies them into the app bundle as a folder
resource (see `project.yml`).

## Architecture — a one-line tour

- **`NodApp`** mounts `ChatView`. `ChatView` owns the conversation and composes everything else.
- **`EngineHolder`** is the routing layer. It picks between `FoundationModelsClient` (Apple Intelligence) and `MLXEngineClient` (on-device 4B models via MLX) based on device capability and user preference.
- **`MLXR2BackgroundSession`** does the heavy model download via iOS background URLSession so it survives app suspend and kill. `MLXEngineClient` orchestrates it and emits progress events through `DownloadEvent` / `DownloadMetrics`.
- **`ConversationStore`** is the message log. `MessageDatabase` (GRDB/SQLite) persists. When the log grows past a threshold, `ConversationStore` fires a FoundationModels summarization so the context stays bounded.
- **`EntityExtractorService`** + **`EntityStore`** are the "memory" layer — AFM extracts structured facts from each turn, embeds them, and they flow back into the system prompt.
- **`AppLockManager`** guards the whole app behind Face ID when the user opts in. `AppLockOverlay` is what shows while locked.
- **`DictationRecognizer`** wraps iOS 26's `SpeechAnalyzer` + `SpeechTranscriber` for voice input. Runs entirely on-device.
- **`NodMascot`** (in `Views/`) is the single source of truth for the orange face — see the comments in that file for the tokens and the relationship to the app icon.

## Tests

No test target yet. Evals live under `ios/evals/listening-mode/` as vent
transcripts that get rerun against the listening prompt whenever the
prompt changes.

## License

MIT — see [`../LICENSE`](../LICENSE).
