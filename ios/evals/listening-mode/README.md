# Listening-mode eval fixtures

This directory holds real vent transcripts used as regression tests for the
listening-mode system prompt. Every prompt change gets run against these and
the outputs diffed.

## Format

One markdown file per fixture, named `NN-short-description.md`:

```markdown
---
title: "Interview frustration"
date: 2026-04-19
tags: [work, interview, technical]
---

## User

[exact text or paraphrased vent, redacted as needed]

## Good response looks like

[1-3 sentences describing what a 10/10 listening-mode reply would do]

## Bad response would

[1-3 sentences describing the failure modes for this specific input]
```

## When to add fixtures

Add one whenever you vent something real to Nod and the reply either delights
you or disappoints you. Hand-label what a good reply looks like. Over time this
becomes your taste codified.

Target: 5-10 fixtures before Phase 2. Grow to 20-30 by Phase 3.

## When to run

Before shipping any change to `prompts/listening_mode.md` at the repo root, or
swapping which inference engine handles listening. Manually for now; scripted
later.
