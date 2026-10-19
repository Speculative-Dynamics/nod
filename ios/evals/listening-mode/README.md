# Listening-mode evals

Scripted conversations used to check how Nod replies. Run them before
shipping any change to `prompts/`, to how turns are assembled, or to which
model handles listening.

## Run

Needs a Mac on macOS 26+ with Apple Intelligence turned on.

```bash
ios/evals/runner/run.sh                    # reply quality (this folder)
ios/evals/runner/run.sh --suite memory     # memory (../memory/cases)
```

The runner compiles the app's own shared code (`ListeningTurns`,
`AFMListening`, `ReplyGuard`, `ConversationMemory` and friends) and plays
every case through Apple's on-device model, one turn at a time, with
chapter notes and past-message recall exactly as the app does them. Output goes to
`ios/evals/results/<timestamp>-<label>/`:

- `report.md` — every reply, with automatic flags
- `results.json` — the same, machine-readable

Useful flags:

- `--case greeting` runs only cases whose id contains `greeting`
- `--prompt /path/to/prompt.md --label try-x` compares a candidate prompt

## What the flags mean

- `banned: …` — a phrase from `prompts/banned_phrases.txt` appeared in the
  raw reply. The app's reply guard removes that sentence; the report shows
  both versions.
- `advice/cheer: …` — fixing or cheerleading language ("have you tried",
  "you should", "proud of you").
- `long`, `questions` — more than 5 sentences, or more than one question.
- `sympathy opener` — the reply starts with "I'm sorry".
- `error: …` — generation failed (context overflow, refusal, …).

Flags catch the mechanical failures. Whether a reply is warm, specific and
matches the moment is a judgment call: read `report.md` against each
case's `expect` note.

## Cases

One JSON file per case in `cases/`:

```json
{
  "id": "vent-manager-email",
  "category": "venting",
  "context": {
    "personalization": "HOW THIS PERSON LIKES TO BE HEARD: …",
    "chapter": "a chapter note the conversation starts from",
    "pastMessages": ["(last week) \"a past message, as the app recalls it\""]
  },
  "turns": ["first user message", "second user message"],
  "expect": "what a good reply does, and what it must not do",
  "maxTokens": 300
}
```

`context` and `maxTokens` are optional. `personalization` is the literal
block the app builds from the sidebar settings
(`PersonalizationStore.promptBlock`).

Add a case whenever Nod replies in a way that delights or disappoints you.
