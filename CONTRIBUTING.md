# Contributing to Nod

Thanks for wanting to help. Nod is an open-source iOS app for people
who just want to be heard. It runs entirely on-device, collects no
user data, and has no accounts. Those are the core constraints behind
every decision here.

This guide covers how to set up, what to work on, how we review, and
the conventions we use.

---

## What we want help with

If you are new to the project, the fastest way in is to pick up an
issue labeled **[`good first issue`][gfi]** or **[`help wanted`][hw]**.

[gfi]: https://github.com/Speculative-Dynamics/nod/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22
[hw]: https://github.com/Speculative-Dynamics/nod/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22

High-value areas beyond those labels:

- **Accessibility.** VoiceOver, Dynamic Type, keyboard navigation.
  An app people open during private moments has to be accessible.
  Audit any screen you use and flag what breaks.
- **Prompt quality.** The listening prompt lives at
  [`prompts/listening_mode.md`](prompts/listening_mode.md). If you
  have a fixture (an anonymized vent transcript) where Nod's reply
  lands wrong, add it under [`ios/evals/listening-mode/`](ios/evals/listening-mode/)
  and open an issue.
- **New engine support.** New open-weight on-device models that fit
  in 4-6 GB of RAM. Follow the pattern in
  [`ios/Nod/Inference/MLXModelSpec.swift`](ios/Nod/Inference/MLXModelSpec.swift).
- **Bug reports.** Concrete repro steps go a long way. Issue template
  walks you through the details.

What we **don't** want (already decided, not open for revisiting):

- Analytics, telemetry, crash reporting SDKs. Nod collects zero data.
  This is in the README for a reason.
- Cloud sync, account systems, login flows. The local-only stance is
  the product, not a limitation to fix.
- Push notifications / reminders / streaks. Nod is calm by design.
- Social features, sharing, community posts.

If you're unsure whether an idea fits, open a Discussion before a PR.

---

## Getting set up

Nod is a native SwiftUI iOS app targeting iOS 26+.

**Requirements:**
- macOS with **Xcode 16+** (Xcode 26 recommended for the iOS 26 SDK)
- Apple Developer account (Personal tier is fine for local installs)
- An **iPhone 15 Pro or later** for on-device testing
- Apple Intelligence enabled in Settings → Apple Intelligence & Siri

**Build and run:**

```bash
git clone git@github.com:Speculative-Dynamics/nod.git
cd nod/ios
open Nod.xcodeproj
```

In Xcode: select your iPhone as the destination, pick your Team
under Signing & Capabilities on the `Nod` target, then Cmd+R.

For the full layout, build flags, and architecture tour, see
[`ios/README.md`](ios/README.md). For a repo-wide overview of
`ios/`, `website/`, and `prompts/`, see
[`ARCHITECTURE.md`](ARCHITECTURE.md).

**XcodeGen:** `ios/project.yml` is the source of truth. `Nod.xcodeproj`
is committed so a fresh clone builds without installing XcodeGen.
If you edit `project.yml`, regenerate with `cd ios && xcodegen generate`.

---

## How to submit a change

### 1. Pick or file an issue first

For anything bigger than a typo or a one-line fix, open or claim an
issue before writing code. This avoids wasted work if the scope or
approach needs discussion.

### 2. Branch naming

We use conventional prefixes so the branch name tells you what's in it:

- `feat/short-description` — new feature
- `fix/short-description` — bug fix
- `chore/short-description` — maintenance, deps, cleanup
- `polish/short-description` — small UX/cosmetic improvements
- `refactor/short-description` — restructure without changing behavior
- `docs/short-description` — documentation
- `ci/short-description` — CI config changes

Examples: `fix/keyboard-after-dictation`, `feat/cellular-download-toggle`.

### 3. Write the code

Keep diffs focused. One concern per PR. If you end up touching more
than 8 files, stop and ask whether the work should be split.

**Swift style:**
- Strict concurrency (`SWIFT_STRICT_CONCURRENCY=complete`) is on.
  Respect `@MainActor`, `Sendable`, and actor isolation. Don't add
  `@unchecked Sendable` without a comment explaining why.
- Comments explain **why**, not what. The code already says what.
- ASCII diagrams in code comments for non-trivial state machines or
  pipelines are encouraged. Update them in the same PR when the code
  changes.
- No emojis in source files unless explicitly requested.

**Things to avoid:**
- Force-unwraps (`!`) on user input or network results.
- `try!` outside of previews and "cannot fail" init paths.
- Logging user content. Don't print what the user wrote, ever — not
  in Console.app, not in analytics (we don't have any anyway).
- New third-party SDKs. MLX, GRDB, and swift-transformers are the
  only runtime dependencies. Additions need a strong case.

### 4. Commit messages

Use conventional commits:

```
type: short imperative summary

Optional longer body explaining why (not what) and any tradeoffs.
```

Types match branch prefixes: `feat`, `fix`, `chore`, `polish`,
`refactor`, `docs`, `ci`.

### 5. Open a pull request

The PR template will walk you through what to include. At minimum:

- Summary (1-3 bullets)
- Test plan (how you verified it works)
- Screenshots or screen recordings for UI changes

Our CI runs `xcodebuild` against the iPhone 17 Pro Simulator on
every PR. If your branch doesn't build locally, it won't build in
CI either — run the build before pushing.

### 6. Review

We try to respond within a few days. We don't currently have SLAs,
and this is a small team, so please be patient.

What reviewers look for:

- Does this belong in Nod? (See "What we don't want" above.)
- Is the diff minimal? Could this be simpler?
- Does it preserve the no-data-collection guarantee? (If it touches
  network code, this is the top question.)
- Does it work on-device, not just in Preview?
- Does it respect accessibility (VoiceOver, Dynamic Type)?

If a change needs redirection, we'll say so plainly. Not personal,
just trying to keep the product tight.

---

## Testing

There is no unit-test target in the iOS app yet — documented in the
[V1 audit](CHANGELOG.md) as a known gap. For now, testing means:

- **Build verification:** CI runs `xcodebuild` on every PR. Green
  check means at least it compiles.
- **Manual device testing:** run on your iPhone 15 Pro+. Walk the
  flows your change touches. For UI work, test light + dark mode.
- **Eval fixtures:** prompt changes should be tested against
  [`ios/evals/listening-mode/`](ios/evals/listening-mode/). Add your
  own fixture if your change exercises a pattern we don't cover.

A proper test target is on the roadmap. If you want to contribute
that, open a discussion first — we'll need to decide on Swift Testing
vs XCTest, and what to test first.

---

## Reporting security issues

**Do not file security issues as public GitHub issues.**

See [`SECURITY.md`](SECURITY.md) for the responsible disclosure
process.

---

## Code of conduct

By participating, you agree to follow our
[Code of Conduct](CODE_OF_CONDUCT.md). The short version: be kind,
assume good intent, give feedback on code not people. People share
real, sometimes vulnerable things with apps like this — we take that
seriously when reviewing contributions.

---

## Questions

- **Anything non-confidential:** open a [Discussion](https://github.com/Speculative-Dynamics/nod/discussions).
- **Bug reports / feature requests:** use the [Issue templates](https://github.com/Speculative-Dynamics/nod/issues/new/choose).
- **Security:** [`SECURITY.md`](SECURITY.md).
- **General:** [hello@usenod.app](mailto:hello@usenod.app).

Thank you for reading this far. We're genuinely glad you're here.
