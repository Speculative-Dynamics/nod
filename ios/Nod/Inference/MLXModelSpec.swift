// MLXModelSpec.swift
// A "what to run on-device" record: name, release date, R2 delivery URL,
// file manifest (with SHA-256), tagline copy, disk directory.
//
// This is the one place that differs between the supported MLX models.
// MLXEngineClient takes a spec and becomes a running engine; everything
// else (download, hash-verify, MLX load, generate) is model-agnostic and
// lives below.
//
// Why not parse this from config.json or a JSON asset?
//   - Bundling models is strictly pinned-in-code. A user can't opt into an
//     arbitrary third-party model by editing a local file. Keeps the
//     attack surface small.
//   - SHA-256s are compile-time constants. If a future build pushes a
//     different manifest to the same R2 path, existing installs hash-fail
//     and retry cleanly; the on-disk files are verified against the spec
//     the app ships with, not whatever is behind the URL.
//
// Adding a new model later is a one-place edit: write a new static
// `MLXModelSpec`, add a case to `EnginePreference`, and teach
// `EngineHolder.makeEngine(for:)` to route to the new spec.

import Foundation

struct MLXModelSpec: Sendable, Hashable {

    // MARK: - Identity

    /// Stable machine identifier. Used as part of the Application Support
    /// directory name and, downstream, for analytics. Must not change
    /// across builds — users have files on disk keyed by this.
    let identifier: String

    /// What users see in the sidebar. "Qwen 3 Instruct 2507", etc.
    let displayName: String

    /// Short release month for the metadata line. "Jul 2025", "Mar 2026".
    let releaseMonth: String

    /// Short line that describes the model for AFM-style rows where there's
    /// no size/date metadata. Currently unused for MLX specs (date · size
    /// is more informative there); kept for parity with EnginePreference.
    let tagline: String

    /// One-word role relative to the other MLX models in the lineup:
    /// "Latest", "Recent", "Proven". Surfaced as the FIRST token on the
    /// sidebar metadata line ("Latest · Apr 2026 · 2.6 GB · ..."), so a
    /// user picking between models knows which is the newest vs. the
    /// most battle-tested without needing to decode release dates or
    /// model names.
    ///
    /// Relative labels: when we add a 4th model, re-rank existing ones.
    let roleLabel: String

    // MARK: - Delivery

    /// Base URL for the versioned R2 path. Trailing slash implied by
    /// `appending(path:)`. See `MLXR2BackgroundSession.ensureLocalFiles`
    /// for how files are fetched.
    let r2BaseURL: URL

    /// Every file MLX needs: weights, tokenizer bits, chat template,
    /// generation config. Hash-verified on arrival; size-verified on
    /// reopen. Order doesn't matter — the session sorts largest-first
    /// internally.
    let files: [FileSpec]

    // MARK: - Sampling

    typealias Sampling = MLXSampling

    // MARK: - Memory

    /// Peak memory while loaded and generating (weights + KV cache +
    /// activations), measured with the eval runner on a long
    /// conversation. Used to check free memory before loading.
    var peakMemoryBytes: UInt64 {
        switch identifier {
        case "qwen3.5-2b": return 2_100_000_000   // measured 2.04 GB
        default: return 3_600_000_000             // Qwen 3.5 4B: measured 3.54 GB
        }
    }

    /// Smallest iPhone (physical RAM) this model is offered on. iOS lets
    /// an app with the increased-memory-limit entitlement use roughly
    /// half to two-thirds of physical RAM, so this is about twice the
    /// measured peak, rounded to real iPhone memory sizes.
    var minimumDeviceMemory: UInt64 {
        switch identifier {
        case "qwen3.5-2b": return 5_500_000_000   // 6 GB iPhones and up
        default: return 7_500_000_000             // 8 GB iPhones (15 Pro and newer)
        }
    }

    /// On-disk folders of retired models (Qwen 3 4B, Gemma 4 E2B).
    /// Deleted at launch to give users their storage back.
    static let retiredDirectoryNames = ["Qwen3-4B-4bit", "Gemma4-E2B-IT-Text-int4"]

    static func deleteRetiredModels() {
        for name in retiredDirectoryNames {
            let dir = URL.applicationSupportDirectory.appending(path: "Nod").appending(path: name)
            if FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// Whether this phone has enough RAM to offer this model at all.
    var fitsThisDevice: Bool {
        ProcessInfo.processInfo.physicalMemory >= minimumDeviceMemory
    }

    /// Chat sampling per each model family's recommendation (see
    /// MLXSampling).
    var sampling: MLXSampling { .qwen35 }

    // MARK: - Local storage

    /// Directory basename under `Application Support/Nod/`. Must be
    /// unique per spec so models don't collide. Not user-visible.
    let directoryName: String

    /// Total byte count across all files in the manifest. Computed at
    /// spec construction — used for the sidebar's "3.0 GB" display.
    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    /// Where the verified model files live after a successful download.
    /// Application Support keeps them invisible to Files, out of iCloud
    /// backups, and not evictable like Caches. MLX loads directly from
    /// here via `loadModelContainer(from: URL, using:)`.
    var modelDirectoryURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Nod")
            .appending(path: directoryName)
    }

    /// Per-spec resume-data file. Scoped to the model directory so that
    /// pausing Qwen 3.5 mid-download and switching to Gemma 4 does NOT
    /// clobber Qwen 3.5's resume data — a real bug risk called out in
    /// eng review.
    var resumeDataURL: URL {
        modelDirectoryURL.appending(path: DownloadTuning.resumeDataFilename)
    }

    // MARK: - Status checks

    /// True if every file in the manifest exists at the correct size.
    /// Used by the sidebar to decide between "Downloaded · 2.3 GB" and
    /// "2.3 GB · download on use" rows, and by the session to short-circuit
    /// a no-op `ensureLocalFiles` call.
    var isFullyDownloaded: Bool {
        for file in files {
            let path = modelDirectoryURL.appending(path: file.name).path
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let actualSize = (try? FileManager.default
                .attributesOfItem(atPath: path)[.size] as? Int64) ?? -1
            if actualSize != file.size { return false }
        }
        return true
    }

    /// True if any manifest file is present but not all. Implies the
    /// user started but didn't finish — a later resume picks up where
    /// the session left off. Distinct from `isFullyDownloaded` for the
    /// sidebar's "paused" state detection.
    var hasPartialDownload: Bool {
        guard FileManager.default.fileExists(atPath: resumeDataURL.path) else {
            // No resume blob on disk. Check for any file at any size as
            // a weaker signal — covers the case where a prior install
            // finished some small tokenizer files but not the big
            // safetensors.
            for file in files {
                let path = modelDirectoryURL.appending(path: file.name).path
                if FileManager.default.fileExists(atPath: path) {
                    return !isFullyDownloaded
                }
            }
            return false
        }
        // Resume data present = user paused mid-download.
        return !isFullyDownloaded
    }

    /// Wipe every file in the model directory. Used by the sidebar's
    /// Delete affordance to reclaim ~2.3-3 GB of disk space. Idempotent
    /// — safe to call on a never-downloaded model.
    func deleteDownloadedFiles() {
        try? FileManager.default.removeItem(at: modelDirectoryURL)
    }
}

// MARK: - Concrete specs

extension MLXModelSpec {

    // ==========================================================================
    // Qwen 3.5 4B — March 2, 2026
    // ==========================================================================
    // The Mar 2026 release is a unified vision-language foundation
    // (model_type: qwen3_5). Although the HF repo ships vision weights,
    // mlx-swift-lm's `Qwen35Model.sanitize(weights:)` explicitly strips
    // `vision_tower` and `model.visual` keys at load time — so on-device
    // RAM usage is text-only, we just pay the disk cost of the vision
    // bytes included in the download.
    //
    // Thinking mode: Qwen 3.5's chat_template.jinja defaults
    // `enable_thinking=true` and prepends `<think>\n` to every reply.
    // For a listening-mode chat app that burns token budget on reasoning
    // nobody sees, so `MLXEngineClient.generate` passes
    // `additionalContext: ["enable_thinking": false]` to flip the
    // template's else branch and skip thinking entirely.
    //
    // Source: mlx-community/Qwen3.5-4B-4bit (a re-quantization of
    // Qwen/Qwen3.5-4B). Hashes computed directly from the HF source;
    // user uploads these exact bytes to our R2 bucket.
    static let qwen35_4b = MLXModelSpec(
        identifier: "qwen3.5-4b",
        displayName: "Qwen 3.5 4B",
        releaseMonth: "Mar 2026",
        tagline: "Multimodal arch · text-only use",
        roleLabel: "Best",
        r2BaseURL: URL(
            string: "https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/qwen3.5-4b-4bit/v1"
        )!,
        files: [
            .init(name: "chat_template.jinja",
                  sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715",
                  size: 7_756),
            .init(name: "config.json",
                  sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa",
                  size: 3_366),
            .init(name: "model.safetensors",
                  sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db",
                  size: 3_034_300_695),
            .init(name: "model.safetensors.index.json",
                  sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a",
                  size: 101_944),
            .init(name: "preprocessor_config.json",
                  sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
                  size: 390),
            .init(name: "processor_config.json",
                  sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b",
                  size: 1_300),
            .init(name: "tokenizer.json",
                  sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
                  size: 19_989_343),
            .init(name: "tokenizer_config.json",
                  sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182",
                  size: 1_139),
            .init(name: "video_preprocessor_config.json",
                  sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
                  size: 385),
            .init(name: "vocab.json",
                  sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
                  size: 6_722_759),
        ],
        directoryName: "Qwen3.5-4B-4bit"
    )

    // ==========================================================================
    // Qwen 3.5 2B — March 2026
    // ==========================================================================
    // The light option: about half the download and memory of the 4B
    // models (~2.0 GB peak in evals vs ~3.5 GB), so it fits 6 GB
    // iPhones that can't run Apple Intelligence. Evals: 4/4 recall,
    // 11/63 flagged replies (Qwen 3.5 4B: 4/4, 3/63).
    //
    // Source: mlx-community/Qwen3.5-2B-4bit. Hashes computed from the
    // Hugging Face files; upload with
    // `ios/scripts/upload_models_to_r2.sh qwen35_2b`.
    static let qwen35_2b = MLXModelSpec(
        identifier: "qwen3.5-2b",
        displayName: "Qwen 3.5 2B",
        releaseMonth: "Mar 2026",
        tagline: "Lighter · smaller download",
        roleLabel: "Light",
        r2BaseURL: URL(
            string: "https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/qwen3.5-2b-4bit/v1"
        )!,
        files: [
            .init(name: "chat_template.jinja",
                  sha256: "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80",
                  size: 7_755),
            .init(name: "config.json",
                  sha256: "beb7fc5a6e0405fe332821cf1a8ef7b69bb390a8c8933171647de5579debf949",
                  size: 3_113),
            .init(name: "model.safetensors",
                  sha256: "713fe7e5d3c3965f7106b0d0ee17615f7869c23c8d327996df8c1196fbcf07d5",
                  size: 1_722_271_785),
            .init(name: "model.safetensors.index.json",
                  sha256: "8294c05cca7d53a6c33e3db2b379539bd296d054e0b689711b16b6ac93c7e49d",
                  size: 81_722),
            .init(name: "preprocessor_config.json",
                  sha256: "27225450ac9c6529872ee1924fcb0962ff5634834f817040f444118116f4e516",
                  size: 390),
            .init(name: "processor_config.json",
                  sha256: "14932921ca485d458a04dafd8069fbb0a4505622a48208d19ed247115801385b",
                  size: 1_300),
            .init(name: "tokenizer.json",
                  sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
                  size: 19_989_343),
            .init(name: "tokenizer_config.json",
                  sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182",
                  size: 1_139),
            .init(name: "video_preprocessor_config.json",
                  sha256: "7768af27c1fafa9cc9011c1dc20067e03f8915e03b63504550e11d5066986d13",
                  size: 385),
            .init(name: "vocab.json",
                  sha256: "ce99b4cb2983d118806ce0a8b777a35b093e2000a503ebde25853284c9dfa003",
                  size: 6_722_759),
        ],
        directoryName: "Qwen3.5-2B-4bit"
    )

}
