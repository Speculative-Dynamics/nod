# Changelog

All notable changes to **Nod (Just Nod)** are listed here, in reverse
chronological order. The format follows the spirit of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — user-facing
changes first, then the engineering work that made them possible.

The project uses semantic-ish versioning under `MARKETING_VERSION` in
`ios/project.yml`. Build numbers (`CURRENT_PROJECT_VERSION`) increment
per TestFlight upload.

## [Unreleased]

### Maintenance
- Post-V1-audit housekeeping: renamed stale `qwen.download` log category to `mlx.download`, updated pre-rename `QwenClient` / `QwenR2BackgroundSession` references in comments and `project.yml` to their current names, rewrote `ios/README.md` to reflect the actual current source layout and build flow.
- Added this CHANGELOG.

## [0.1.0] — Build 21 — 2026-04

First public-ready build. Not yet on the App Store.

### Added
- **Voice input** — tap the mic in the input row to dictate. Siri-style orange edge glow while recording. Uses iOS 26's `SpeechAnalyzer` + `SpeechTranscriber`, fully on-device. Auto-commits after 2.5s of silence or manual stop.
- **Canonical mascot system** — single `NodMascot` component with tokens for colors, geometry, blink cadence. Every in-app rendering (splash, onboarding hero, nav bar, empty state, lock screen) pulls from the same primitives. Eye color pixel-verified against the app icon (`#1a1a1a`).
- **Shared blinker** — `NodMascotBlinker` drives the 4.5s ± jitter idle blink for every persistent face. Jitter keeps two on-screen mascots naturally desynced.
- **Face ID app lock** — opt-in sidebar toggle. Locks the app behind biometric auth when backgrounded. Passcode falls back via the system.
- **Memory system** — AFM extracts structured facts from each turn, embeds them, surfaces them in a browsable "what Nod remembers" view in the sidebar. Can be purged per-entity or wholesale.
- **Personalization** — two toggles and a free-form text field in the sidebar, injected into the system prompt on every send.
- **Theme support** — light / dark / system in sidebar.
- **Four engine options** — Apple FoundationModels (AFM), Qwen 3 Instruct 2507, Qwen 3.5 4B, Gemma 4 E2B Text. Switching preserves the conversation.
- **Onboarding for unsupported devices** — AFM-unavailable path offers MLX as a fallback, or explains the requirement if the device can't run either.
- **Model delivery via R2 + Background Assets** — 2-3 GB download survives app suspend, resumes across kills, defaults to Wi-Fi only with a cellular opt-in toggle.
- **Cold-launch animation** — `SplashView` plays a 2-second wake-up: orange square condenses to icon, eyes fade in, one blink, hand off to chat.
- **Start fresh** — clears conversation, running summary, and memory. Irreversible.
- **iCloud backup opt-in** — off by default; when on, the local SQLite file is included in the user's iCloud backup.
- **Mail feedback shortcut** — sidebar link opens Mail with a prefilled `hello@usenod.app` message carrying the app version.

### Fixed
- Keyboard no longer auto-opens after voice dictation lands — the experience stays spoken, not typed.
- Streaming responses cancel cleanly via Stop button; regenerate replaces the last turn without duplicating.

### Engineering
- Generalized the MLX layer: one `MLXEngineClient` parameterized by `MLXModelSpec` replaces what used to be a Qwen-only client.
- Background download loop uses classic `URLSessionDownloadTask` in a background session identifier (survives kill), with per-file retry and rolling-average speed tracking.
- Hash-verified model files on arrival, size-verified on reopen.
- Crash-loop recovery via `LaunchCrashBreaker` on cold launch.
- Partial speech-transcriber results no longer touch `@Published` state — avoids main-actor saturation during voice input.

---

Links:
- [Repository](https://github.com/Speculative-Dynamics/nod)
- [Website](https://usenod.app)
- [Privacy policy](https://usenod.app/privacy)
