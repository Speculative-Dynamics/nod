# Testing Nod

Three layers, from fastest to most realistic.

## 1. End-to-end UI tests (Simulator)

`NodUITests/NodUITests.swift` drives the real app through every
user-facing feature: starters, sending and streaming, Stop, errors and
Try again, Copy/Share/Regenerate, the helpline card, persistence across
relaunch, every setting reaching the engine, memory notes, recall,
forgetting, Start fresh, onboarding branches, download states, the lock
screen, crash recovery, keyboard shortcuts and large text.

```bash
cd ios
xcodebuild test -project Nod.xcodeproj -scheme Nod \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skip-testing:NodUITests/NodRealEngineTests
```

The Simulator can't run Apple's model or the MLX models, so these tests
use a scripted engine (`Nod/Inference/ScriptedEngine.swift`, debug
builds only). It goes through the same history, memory, settings,
streaming and cancellation paths; only the words are scripted, and each
reply carries markers (`Heard: … Remembered: … About you: … (history N,
limit M)`) so the tests can check what actually reached the engine.

Debug launch arguments the tests use (`Nod/Views/DebugUIState.swift`):

| Argument | Effect |
| --- | --- |
| `-nodReset YES` | Start clean: conversation, memory, personal note and settings wiped |
| `-nodSkipSplash YES` | Skip the launch animation |
| `-nodFakeEngine on\|slow\|fail\|failFirst` | Scripted engine |
| `-nodAFM notSupported\|disabled\|none` | Force the Apple Intelligence state |
| `-nodDownload <state>` | Force the download card's state |
| `-nodLocked YES` | Hold the lock screen open |
| `-nodRecording YES` | Show the dictation UI |

All are compiled out of release builds.

## 2. Real engines (iPhone)

`NodUITests/NodRealEngineTests.swift` repeats the core flows with no
scripted engine: replies from Apple Intelligence, Stop, a real memory
note and recall, and (opt-in) downloading Qwen and getting a reply.
UI tests can't run on "My Mac (Designed for iPad)", so this needs an
iPhone with Apple Intelligence:

```bash
TEST_RUNNER_NOD_REAL_ENGINE=1 xcodebuild test -project Nod.xcodeproj -scheme Nod \
  -destination 'platform=iOS,name=<your iPhone>' \
  -only-testing:NodUITests/NodRealEngineTests -allowProvisioningUpdates
```

Add `TEST_RUNNER_NOD_REAL_MLX=1` for the Qwen download (~3 GB). This
installs a debug build over the App Store app, and every test wipes
Nod's data first, so don't run it on a phone whose Nod conversation
matters. The evals below exercise the same real engines through the
app's own reply and memory code without a device.

## 3. Reply quality and memory evals (Mac)

```bash
ios/evals/runner/run.sh                                  # listening, Apple Intelligence
ios/evals/runner/run.sh --suite memory                   # recall, search, grounding
ios/evals/runner/run.sh --engine mlx:/path/to/Qwen3.5-4B-4bit
```

Reports land in `ios/evals/results/` (not committed).

## Not automated

- Face ID itself (the Simulator has no passcode; the lock screen and
  toggle are tested, the biometric prompt isn't).
- Voice input end to end (the Simulator usually lacks the speech
  model; the recording UI is covered with `-nodRecording`).
- The App Switcher privacy cover (UI tests can't see the snapshot;
  checked by hand).
- Sharing to other apps and the feedback email (system sheets).
