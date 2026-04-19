# Nod — iOS app

Native SwiftUI app. iOS 18.2+ deployment target. All inference runs on-device.

## Prerequisites

- macOS with Xcode 16+ installed
- Apple Developer account (Organization tier, for App Store distribution — Personal tier works for local device installs with a 7-day provisioning profile)
- An iPhone 15 Pro or later for on-device testing (required for Apple FoundationModels and Qwen 4B)
- Apple Intelligence enabled in Settings → Apple Intelligence & Siri on the test device

## Source layout

```
ios/
├── README.md                 # you are here
├── Nod/                      # Swift source (imported into Xcode project)
│   ├── NodApp.swift          # @main, SwiftUI App entry point
│   ├── Views/
│   │   ├── ChatView.swift    # main chat screen (message list + input bar)
│   │   ├── NodAnimation.swift # eye-blink brand gesture
│   │   └── EmptyStateView.swift # first-launch empty chat
│   ├── Audio/
│   │   └── Transcriber.swift # SFSpeechRecognizer wrapper for optional dictation
│   ├── Inference/
│   │   ├── InferenceEngine.swift      # protocol both clients conform to
│   │   ├── FoundationModelsClient.swift # Apple on-device LLM (day-1 primary)
│   │   └── QwenClient.swift  # MLX Swift + Qwen 3.5 4B (added in day 3-4)
│   ├── Storage/
│   │   ├── Message.swift     # data model
│   │   └── ConversationStore.swift  # GRDB.swift SQLite persistence
│   └── Resources/
│       └── Prompts/
│           └── listening_mode.md  # THE listening-mode system prompt
└── evals/
    └── listening-mode/       # saved real vent transcripts as regression fixtures
```

The `.xcodeproj` file is NOT checked in — Xcode generates it when you create the project.

## Day 1 setup (one-time, ~15 minutes)

1. Open Xcode → File → New → Project → iOS → App
2. Configure:
   - **Product Name:** Nod
   - **Team:** your Apple Developer team
   - **Organization Identifier:** `app.usenod` (matches the domain you own)
   - **Interface:** SwiftUI
   - **Language:** Swift
   - **Testing System:** Swift Testing (WWDC 2024)
   - **Storage:** None
3. Save the project into this `ios/` directory. Xcode will create `Nod.xcodeproj/` alongside the existing `Nod/` folder.
4. In Xcode, delete the default `NodApp.swift` and `ContentView.swift` that Xcode generated (keep the ones already in `Nod/` from this repo).
5. Right-click the `Nod` folder in Xcode → "Add Files to Nod" → select every file already present in `Nod/` so Xcode picks them up.
6. Drop the app icon into `Assets.xcassets/AppIcon.appiconset/` at the required sizes (1024pt master at minimum for App Store; Xcode generates smaller sizes automatically if you use a single 1024pt).
7. Set deployment target to **iOS 18.2** in project settings.
8. Add `Color Set` named `NodAccent` to `Assets.xcassets`. Dark value: `#E89260`. Light value: `#F27A3B`. Set `.accentColor` in `NodApp.swift` to read from this.
9. Set the app's default appearance to Dark in `Info.plist` (`UIUserInterfaceStyle = Dark`).

## Day 1 build goal

A working text-only chat screen:
- Dark background
- Empty state: Nod face + "I'm listening."
- Type into the input field, tap send
- Apple FoundationModels responds via `FoundationModelsClient`
- Response appears as a left-aligned bubble
- Nod eye-blink animation plays between send and response

Run on your iPhone 15 Pro via Xcode (`Cmd+R` with phone selected as destination).

## Running and iterating

```bash
# From Xcode GUI: Product → Run (Cmd+R) with your iPhone selected as destination.
# For command-line build verification (after the project exists):
xcodebuild -scheme Nod -destination 'generic/platform=iOS' build
```

## Next phases

After Day 1 works, follow the design doc's Next Steps (day 2-6). Day 3-4 adds MLX Swift + Qwen 3.5 4B via Background Assets. The `QwenClient.swift` file in this repo is a stub until then.

## License

MIT — see `../LICENSE`.
