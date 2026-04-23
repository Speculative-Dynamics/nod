// EntityEmbedder.swift
// Wraps Apple's `NLEmbedding.sentenceEmbedding(for:)` so we can convert
// an entity's descriptive text into a fixed-dimensional vector, and a
// user message into the same space for similarity search.
//
// Why NLEmbedding and not an MLX-loaded model:
//   - Zero SPM deps (everything else in Storage/ is also zero-dep).
//   - Apple ships the model; no weights in our IPA, no download, no
//     memory cost in our app process.
//   - ANE-accelerated where supported.
//   - Good-enough quality for matching "my manager just apologized"
//     against an entity stored with role="manager". Not state of the
//     art — wouldn't use it for cross-lingual or fine-grained semantic
//     search — but fine for the paraphrase-recall use case in Nod.
//
// Storage format: `Float32` little-endian, contiguous blob. Decode by
// reinterpreting the Data's bytes. No versioning today; if NLEmbedding's
// model changes across iOS versions and embeddings become incompatible,
// we'll need to re-embed all entities on upgrade. Deferred until we see
// it happen.
//
// Failure behavior: every method returns nil / empty on failure rather
// than throwing. Embedding is a best-effort accelerator for retrieval —
// keyword match still works when it's absent. A throw here would cascade
// into extraction failures, which is worse than a degraded retrieval.

import Foundation
import NaturalLanguage

/// Encodes sentence-level embeddings via `NLEmbedding`.
///
/// Marked `@unchecked Sendable` so embedding computation can move off
/// the main actor. `NLEmbedding` isn't Sendable-annotated by Apple, but
/// is effectively read-only after load (initialisation reads the weights
/// once, then every subsequent `.vector(for:)` call is a pure function
/// of its input). EntityStore runs `embed(...)` inside a `Task.detached`
/// during `ingest(_:)` so the ~30 ms NLEmbedding work doesn't block main
/// at the 6x-amplified trigger cadence introduced by incremental entity
/// extraction. Same rationale iOS apps routinely apply to Apple frameworks
/// that are thread-safe but haven't been marked Sendable yet.
struct EntityEmbedder: @unchecked Sendable {

    /// Underlying Apple model. Nil means NLEmbedding has no sentence
    /// model for the current locale — we still construct the embedder
    /// but all operations return nil, keeping call sites uniform.
    private let model: NLEmbedding?

    /// The dimensionality of the vectors this embedder produces. Zero
    /// when the model is nil.
    var dimension: Int { model?.dimension ?? 0 }

    /// Convenience: true when embeddings will work. False when the
    /// platform / locale combination isn't supported and callers should
    /// fall through to pure keyword retrieval.
    var isAvailable: Bool { model != nil && dimension > 0 }

    init(locale: Locale = .current) {
        self.model = NLEmbedding.sentenceEmbedding(for: .english)
        // Hard-coding English: Nod is English-first today. When we add
        // multilingual support, derive the language from `locale` and
        // fall back to English if the locale's model doesn't exist.
        _ = locale
    }

    /// Return the embedding vector for `text` as a BLOB of Float32
    /// values, suitable for direct storage in the `embedding` column
    /// of the `entities` table. Nil on any failure (empty string,
    /// unsupported model, no vector produced).
    func embed(_ text: String) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let model else { return nil }
        guard let doubles = model.vector(for: trimmed), !doubles.isEmpty else {
            return nil
        }
        // NLEmbedding returns [Double]; we persist as Float32 to halve
        // storage without meaningfully hurting similarity quality at
        // these magnitudes. Also keeps on-disk footprint predictable
        // for the backup-excluded SQLite file.
        let floats = doubles.map { Float32($0) }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Decode a BLOB back to `[Float]`. Returns nil on byte-count
    /// misalignment (blob wasn't produced by this embedder or the
    /// model dimension has changed).
    func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float32>.stride
        guard data.count % stride == 0 else { return nil }
        let count = data.count / stride
        return data.withUnsafeBytes { buffer -> [Float] in
            let typed = buffer.bindMemory(to: Float32.self)
            return Array(typed.prefix(count))
        }
    }

    /// Cosine similarity between two equal-length vectors. Returns 0
    /// on length mismatch or either side being all zeros, so unknown
    /// vs known never scores high by accident.
    func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var aMag: Float = 0
        var bMag: Float = 0
        for i in 0..<a.count {
            dot  += a[i] * b[i]
            aMag += a[i] * a[i]
            bMag += b[i] * b[i]
        }
        guard aMag > 0, bMag > 0 else { return 0 }
        return dot / (sqrt(aMag) * sqrt(bMag))
    }
}
