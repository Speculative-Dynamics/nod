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
    /// `appending(path:)`. See `QwenR2BackgroundSession`-now-renamed-
    /// `MLXR2BackgroundSession.ensureLocalFiles` for how files are fetched.
    let r2BaseURL: URL

    /// Every file MLX needs: weights, tokenizer bits, chat template,
    /// generation config. Hash-verified on arrival; size-verified on
    /// reopen. Order doesn't matter — the session sorts largest-first
    /// internally.
    let files: [FileSpec]

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
    // Qwen 3 4B Instruct 2507 — July 2025
    // ==========================================================================
    // Alibaba's Jul 2025 instruct refresh of Qwen 3 4B. Text-only
    // (model_type: qwen3) — the newest pure-text Qwen release as of
    // April 2026. Our original shipped model; kept as the default MLX
    // option for its smaller size and proven performance on iPhone 15
    // Pro.
    //
    // Hashes + sizes inherited from the pre-refactor QwenClient.r2Files
    // manifest; bit-identical to what existing users have on disk, so
    // the upgrade preserves their download.
    static let qwen3_instruct_2507 = MLXModelSpec(
        identifier: "qwen3-instruct-2507",
        displayName: "Qwen 3 Instruct 2507",
        releaseMonth: "Jul 2025",
        tagline: "Text-only · tuned for chat",
        roleLabel: "Proven",
        r2BaseURL: URL(
            string: "https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/qwen3-4b-instruct-2507/v1"
        )!,
        files: [
            .init(name: "config.json",
                  sha256: "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849",
                  size: 938),
            .init(name: "merges.txt",
                  sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5",
                  size: 1_671_853),
            .init(name: "model.safetensors",
                  sha256: "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f",
                  size: 2_263_022_417),
            .init(name: "model.safetensors.index.json",
                  sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777",
                  size: 63_964),
            .init(name: "tokenizer.json",
                  sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4",
                  size: 11_422_654),
            .init(name: "tokenizer_config.json",
                  sha256: "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9",
                  size: 5_440),
            .init(name: "vocab.json",
                  sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
                  size: 2_776_833),
            .init(name: "added_tokens.json",
                  sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680",
                  size: 707),
            .init(name: "special_tokens_map.json",
                  sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd",
                  size: 613),
            .init(name: "chat_template.jinja",
                  sha256: "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541",
                  size: 4_040),
            .init(name: "generation_config.json",
                  sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48",
                  size: 238),
        ],
        directoryName: "Qwen3-4B-4bit"  // unchanged — preserves existing on-disk files
    )

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
    // Source: mlx-community/Qwen3.5-4B-4bit (a re-quantization of
    // Qwen/Qwen3.5-4B). Hashes computed directly from the HF source;
    // user uploads these exact bytes to our R2 bucket.
    static let qwen35_4b = MLXModelSpec(
        identifier: "qwen3.5-4b",
        displayName: "Qwen 3.5 4B",
        releaseMonth: "Mar 2026",
        tagline: "Multimodal arch · text-only use",
        roleLabel: "Recent",
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
    // Gemma 4 E2B Text — April 2, 2026
    // ==========================================================================
    // Google DeepMind's Apr 2026 release. "E2B" = Effective 2B parameters
    // via matformer sparse activation. Training cutoff January 2025.
    // This is the true text-only MLX variant (model_type: gemma4_text),
    // distinct from the full multimodal `gemma4` repos which are 3.6-5 GB.
    //
    // Source: mlx-community/Gemma4-E2B-IT-Text-int4. Hashes computed
    // directly from the HF source; user uploads these exact bytes to
    // our R2 bucket.
    static let gemma4_e2b_text = MLXModelSpec(
        identifier: "gemma4-e2b-text",
        displayName: "Gemma 4 E2B Text",
        releaseMonth: "Apr 2026",
        tagline: "Text-only · fresh training data",
        roleLabel: "Latest",
        r2BaseURL: URL(
            string: "https://pub-6cf269f2cf044828b0b016d58295da25.r2.dev/gemma4-e2b-text-int4/v1"
        )!,
        files: [
            .init(name: "chat_template.jinja",
                  sha256: "781d10940fbc44be40064b5d43a056fc486c84ceaa55538226368b57314132bf",
                  size: 16_317),
            .init(name: "config.json",
                  sha256: "6520ef3831fd604aaca8c1f7796ca392f071843be8fd797aa7b029b06dc3086b",
                  size: 2_774),
            .init(name: "generation_config.json",
                  sha256: "f59b6fa8fb6cf135f525fd203cd70c54016174fb0c3c78d1e40890f2f51395b3",
                  size: 207),
            .init(name: "model.safetensors",
                  sha256: "12fd23751e57dbe38fc9f69e2e7eea247e207b203ee27ea9fff0b1b56e1d621b",
                  size: 2_634_535_262),
            .init(name: "model.safetensors.index.json",
                  sha256: "da9f33c151eff339ee0f66a2485e757af4aeb10ba3d551bf69bc8cad0110ae54",
                  size: 84_084),
            .init(name: "tokenizer.json",
                  sha256: "12499b770c7ac2057affc48617f65ede6f1a7b849574967c177998691027afc6",
                  size: 36_459_693),
            .init(name: "tokenizer_config.json",
                  sha256: "bbf66f6258a0e597b9f35b87db524a042bf208541731fcc6c4b60f19dc10c958",
                  size: 1_837),
        ],
        directoryName: "Gemma4-E2B-IT-Text-int4"
    )
}
