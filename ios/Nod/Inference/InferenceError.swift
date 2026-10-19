// InferenceError.swift
// Errors any InferenceEngine may throw. Its own Foundation-only file so
// the eval runner (ios/evals/runner) can compile it alongside the
// shared listening code.

import Foundation

/// Errors any InferenceEngine may throw. Clients should handle these with
/// user-visible messaging — never silent failures.
enum InferenceError: Error {
    case modelNotReady
    case promptNotFound          // system prompt file missing from bundle (build bug)
    case guardrailViolation      // AFM refused emotional content
    case outOfMemory
    case interrupted             // phone call, app suspension, etc.
    // MLX-model download failures. Mapped from URLError in MLXEngineClient
    // so ChatView / the readiness bar can show typed copy.
    case downloadFailedNoNetwork
    case downloadFailedDiskFull
    case downloadFailedServer
}
