#!/usr/bin/env bash
# Build and run the listening-mode eval on this Mac.
#
# Needs macOS 26+ with Apple Intelligence turned on. Compiles the
# runner together with the app's own shared listening code, so the
# eval uses exactly what ships.
#
# Usage (from anywhere):
#   ios/evals/runner/run.sh                       # all cases, current prompt
#   ios/evals/runner/run.sh --label new-prompt --prompt /path/to/prompt.md
#   ios/evals/runner/run.sh --case greeting       # cases whose id contains "greeting"
#   ios/evals/runner/run.sh --suite memory        # recall, search, grounding
#   ios/evals/runner/run.sh --engine mlx:/path/to/model   # an MLX model folder
#
# Output: ios/evals/results/<timestamp>-<label>/{report.md,results.json}

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
app="$repo/ios/Nod"
build="$here/.build"
mkdir -p "$build"

case " $* " in
  *" --engine mlx:"*)
    # MLX engines need the Swift package build (Metal shaders).
    (cd "$here" && xcodebuild -quiet -scheme NodEval -destination 'platform=macOS,arch=arm64' \
      -derivedDataPath "$build/xcode" -configuration Release build >&2)
    exec "$build/xcode/Build/Products/Release/nod-eval" --repo "$repo" "$@"
    ;;
esac

swiftc -O -target arm64-apple-macos26.0 -o "$build/nod-eval" \
  "$here/main.swift" \
  "$here/memory.swift" \
  "$here/pipeline.swift" \
  "$app/Storage/Message.swift" \
  "$app/Storage/MemoryGrounding.swift" \
  "$app/Storage/PastMessageRecall.swift" \
  "$app/Storage/ConversationMemory.swift" \
  "$app/Inference/InferenceError.swift" \
  "$app/Inference/ListeningTurns.swift" \
  "$app/Inference/AFMListening.swift" \
  "$app/Inference/AFMMemory.swift" \
  "$app/Inference/ReplyGuard.swift" \
  "$here/backend.swift"

exec "$build/nod-eval" --repo "$repo" "$@"
