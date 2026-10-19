# Changelog

All notable changes to **Nod (Just Nod)** are listed here, in reverse
chronological order. The format follows the spirit of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) — user-facing
changes first, then the engineering work that made them possible.

The project uses semantic-ish versioning under `MARKETING_VERSION` in
`ios/project.yml`. Build numbers (`CURRENT_PROJECT_VERSION`) increment
per TestFlight upload.

## [Unreleased]

### Reply quality
- **Apple Intelligence conversations rebuilt per turn.** Each reply now starts a fresh session from the stored conversation, with earlier messages as real chat turns and trimmed to fit the model's context window. Fixes long chats eventually failing, the model losing the thread when remembered people changed, and replies after Start fresh or regenerate seeing stale turns.
- **Real streaming on Apple Intelligence.** Replies appear as they're written, and Stop actually stops generation. The response-length setting now applies to Apple Intelligence too.
- **Apple Intelligence keeps more recent messages word-for-word** (up to 20 before older ones become a chapter note, versus 12 for downloaded models).
- **Rewritten listening prompt.** Roughly half the length, rules in priority order, and no example dialogue: evals showed the on-device model copying example lines and names ("Is this the same M?", "Sam") into unrelated replies.
- **Apple Intelligence replies use temperature 1.0**, which stopped long conversations looping on the same question shape. A refusal is retried once before showing the gentle error.
- **Banned-phrase guard.** Sentences containing phrases from `prompts/banned_phrases.txt` ("I'm sorry to hear…", "You're not alone") are removed from replies, including while streaming.
- **Error notices stay out of the conversation.** "Something went wrong" bubbles are no longer sent back to the model or written into memory.
- **Per-model sampling** for Qwen and Gemma, per their model cards. Chapter notes use steadier settings.
- **Refusals** show a gentler message, and are recognized on iOS 27's new error types. A refused chapter note no longer stalls memory forever.
- **Crisis support card.** A message that clearly signals crisis shows a fixed card with a local helpline (US, CA, UK, IE, AU, NZ, IN) and a link to findahelpline.com, independent of what the model says.

### Memory, redesigned
- **Nod remembers specifics from your own words.** Each time you write, your older messages are searched (names, distinctive words, and relationship words like boss/manager or girlfriend/partner) and the best few are shown to the model verbatim, with how long ago you said them. Nothing is paraphrased, so nothing gets invented, and a later correction wins.
- **Chapter notes replace the rolling summary.** When older messages age out, Nod writes a short note about that stretch, once, never rewritten. Any sentence naming a person or place you never mentioned is deleted before it's saved.
- **Memory screen is now a timeline of those notes.** Swipe one to forget it: the note goes, and Nod stops recalling that stretch. Your messages stay in the chat.
- **Entity extraction is gone**, along with the "Is this the same person?" banner. It cost a model call after every exchange and saved noise like "the commute was awful". About half as many model calls overall.
- **Fixed: summaries inventing details.** The old summary prompt's example (a partner "J", a job search, a fintech interview) leaked into real users' summaries. Existing summaries become your first chapter note; old entity data is deleted from disk.
- Measured on the new memory evals: 7/7 recall cases (corrections, paraphrases, small details, not volunteering) at ~24 model calls per 22-message conversation, versus ~46 before.

### Engineering
- `ios/evals/memory/` and `--suite memory`: recall, past-message search and grounding cases.
- `ios/evals/`: 33 scripted conversations and a Mac runner (`ios/evals/runner/run.sh`) that compiles the app's shared listening code and reports flagged replies.
- The app now launches in the iOS Simulator (MLX setup is skipped there).

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
