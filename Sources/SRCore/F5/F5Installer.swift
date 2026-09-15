import Foundation

/// Installs the Norwegian offline voice: an F5-TTS checkpoint plus its
/// vocoder, on top of the shared local runtime (P-12).
///
/// How this differs from the Kokoro installer, and why. Kokoro is a curated
/// mlx-community repo whose exact revision and file hashes are compiled in,
/// so its install is a verification of known bytes. The Norwegian voice is a
/// community fine-tune: it names no stable revision, its checkpoint file is
/// not named by convention, and it may or may not ship a reference recording.
/// So this installer resolves all of that at install time, records what it
/// resolved — commit sha, source file names, SHA-256 of everything it wrote —
/// into the manifest, and re-checks that record on every launch. A pinned
/// revision can be supplied to skip the resolution step and get Kokoro's
/// stronger guarantee; `scripts/pin-f5-model.sh` prints one from an install.
public struct F5Installer: Sendable {
    /// The model this ships pointed at. Any F5-TTS repo with a checkpoint and
    /// a vocab.txt works — the fetcher discovers the layout.
    public static let modelRepo = "akhbar/F5_Norwegian"
    /// Nil resolves the repo's default branch and pins whatever it finds.
    public static let modelRevision: String? = nil
    /// Mel vocoder. F5-TTS predicts a mel spectrogram; this turns it into
    /// audio. Shared by every F5 checkpoint.
    public static let vocoderRepo = "lucasnewman/vocos-mel-24khz"
    public static let vocoderRevision: String? = nil

    /// Architecture knobs the daemon needs to interpret the checkpoint.
    /// Field names match the fetcher's JSON and the daemon's `SR_F5_ARCH`.
    public struct Arch: Codable, Sendable, Equatable {
        public var dim: Int
        public var depth: Int
        public var heads: Int
        public var ffMult: Int
        public var textDim: Int
        public var convLayers: Int
        public var textMaskPadding: Bool
        /// Number of attention heads that get rotary embeddings; nil is
        /// "all of them" (F5-TTS v1). F5-TTS Base uses 1.
        public var peAttnHead: Int?

        enum CodingKeys: String, CodingKey {
            case dim, depth, heads
            case ffMult = "ff_mult"
            case textDim = "text_dim"
            case convLayers = "conv_layers"
            case textMaskPadding = "text_mask_padding"
            case peAttnHead = "pe_attn_head"
        }

        public static let f5Base = Arch(
            dim: 1024, depth: 22, heads: 16, ffMult: 2, textDim: 512,
            convLayers: 4, textMaskPadding: false, peAttnHead: 1)

        public var variant: Variant { peAttnHead == nil ? .v1Base : .base }

        public func applying(_ variant: Variant) -> Arch {
            var copy = self
            switch variant {
            case .base:
                copy.textMaskPadding = false
                copy.peAttnHead = 1
            case .v1Base:
                copy.textMaskPadding = true
                copy.peAttnHead = nil
            }
            return copy
        }

        /// Write `pe_attn_head` even when it is nil.
        ///
        /// Synthesized encoding drops a nil optional, and the daemon treats a
        /// missing key as "keep my default" — which is 1. So an omitted key
        /// would silently load a v1 checkpoint with the Base architecture,
        /// the exact failure this field exists to control. Nil means "rotate
        /// every head", and it has to say so.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(dim, forKey: .dim)
            try container.encode(depth, forKey: .depth)
            try container.encode(heads, forKey: .heads)
            try container.encode(ffMult, forKey: .ffMult)
            try container.encode(textDim, forKey: .textDim)
            try container.encode(convLayers, forKey: .convLayers)
            try container.encode(textMaskPadding, forKey: .textMaskPadding)
            if let peAttnHead {
                try container.encode(peAttnHead, forKey: .peAttnHead)
            } else {
                try container.encodeNil(forKey: .peAttnHead)
            }
        }

        /// JSON for the daemon's `SR_F5_ARCH`.
        public var environmentJSON: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(self),
                  let json = String(data: data, encoding: .utf8) else { return "" }
            return json
        }
    }

    /// The two F5-TTS architectures in the wild. They share every tensor
    /// shape, so a checkpoint cannot say which it is and loading it the wrong
    /// way produces babble rather than an error — which is why this is a
    /// one-click switch in Settings rather than a compile-time constant.
    public enum Variant: String, Codable, Sendable, CaseIterable, Identifiable {
        case base = "f5tts_base"
        case v1Base = "f5tts_v1_base"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .base: return "F5-TTS Base"
            case .v1Base: return "F5-TTS v1 Base"
            }
        }
    }

    public struct Manifest: Codable, Sendable {
        public let modelRepo: String
        public let modelRevision: String
        public let weightsSource: String
        public let weightsSHA256: String
        public let weightsBytes: Int
        public let vocabSHA256: String
        public let vocoderRepo: String
        public let vocoderSHA256: String
        public let requirementsLockSHA256: String
        /// What the repo's own config said, or the shipped default. The
        /// effective variant can be overridden in Settings without
        /// reinstalling, so this is the starting point, not the last word.
        public let arch: Arch
        /// Repo file the architecture came from; nil means the default.
        public let archSource: String?
        public let installedAt: Date
    }

    public enum InstallProgress: Sendable {
        case creatingVenv
        case installingPackages
        /// Human-readable stage of the model fetch (it runs for minutes).
        case downloading(String)
        case verifying
        case done
        case failed(String)
    }

    public let paths: F5Paths
    public let runtimePaths: KokoroPaths

    public init(paths: F5Paths = .standard, runtimePaths: KokoroPaths = .standard) {
        self.paths = paths
        self.runtimePaths = runtimePaths
    }

    private var runtime: LocalRuntimeInstaller {
        LocalRuntimeInstaller(paths: runtimePaths)
    }

    /// Installed = shared runtime + a manifest whose files are still there.
    public var isInstalled: Bool {
        runtime.isInstalled && (try? loadValidatedManifest()) != nil
    }

    /// An install exists but no longer satisfies the current pins — a new
    /// dependency lock, or a different model repo shipped in an app update.
    public var needsUpdate: Bool {
        runtime.isInstalled
            && FileManager.default.fileExists(atPath: paths.manifest.path)
            && !isInstalled
    }

    public func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: paths.manifest)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Cheap per-launch validation. The weights are gigabytes, so they are
    /// hashed once at install and only checked for presence and exact size
    /// afterwards — enough to catch a truncated, deleted or swapped file
    /// without reading 1.4 GB every time sr starts.
    public func loadValidatedManifest() throws -> Manifest {
        let manifest = try loadManifest()
        guard manifest.modelRepo == Self.modelRepo,
              manifest.vocoderRepo == Self.vocoderRepo,
              manifest.requirementsLockSHA256 == LocalRuntimeInstaller.requirementsLockSHA256
        else {
            throw InstallError(message: "installed manifest does not match bundled pins")
        }
        if let revision = Self.modelRevision, manifest.modelRevision != revision {
            throw InstallError(message: "installed model is not the pinned revision")
        }
        let fm = FileManager.default
        for file in [paths.weights, paths.vocab, paths.vocoderWeights, paths.vocoderConfig]
        where !fm.fileExists(atPath: file.path) {
            throw InstallError(message: "verified model files are missing")
        }
        let attributes = try? fm.attributesOfItem(atPath: paths.weights.path)
        guard attributes?[.size] as? Int == manifest.weightsBytes else {
            throw InstallError(message: "model weights changed size since install")
        }
        return manifest
    }

    /// Run the full install. `fetchSourceURL` is sr_f5_fetch.py, run straight
    /// from the app bundle — unlike the daemon it is only needed while this
    /// install is running, so there is nothing to copy or keep in sync.
    public func install(
        daemonSourceURL: URL,
        requirementsLockURL: URL,
        fetchSourceURL: URL
    ) -> AsyncStream<InstallProgress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await runInstall(
                        daemonSourceURL: daemonSourceURL,
                        requirementsLockURL: requirementsLockURL,
                        fetchSourceURL: fetchSourceURL) {
                        continuation.yield($0)
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    SRLog.event("f5.install_cancelled", [:])
                } catch {
                    let message = (error as? InstallError)?.message
                        ?? error.localizedDescription
                    SRLog.error("f5.install", ["error": message])
                    continuation.yield(.failed(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Remove the model, vocoder and manifest. Reference voices are kept:
    /// they are the user's own recordings, not part of the download.
    public func uninstall() {
        let fm = FileManager.default
        for url in [paths.modelDir, paths.vocoderDir, paths.manifest,
                    paths.fetchReport, paths.progressFile] {
            try? fm.removeItem(at: url)
        }
        SRLog.event("f5.uninstalled", [:])
    }

    // MARK: - Install steps

    private func runInstall(
        daemonSourceURL: URL,
        requirementsLockURL: URL,
        fetchSourceURL: URL,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.base, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.voicesDir, withIntermediateDirectories: true)

        try await runtime.install(
            daemonSourceURL: daemonSourceURL,
            requirementsLockURL: requirementsLockURL
        ) { step in
            switch step {
            case .creatingVenv: progress(.creatingVenv)
            case .installingPackages: progress(.installingPackages)
            }
        }
        try Task.checkCancellation()

        // An app update that only bumps the dependency lock invalidates the
        // manifest, and re-downloading gigabytes to rewrite one field of it
        // would be absurd. If the model on disk is still exactly the one the
        // old manifest describes, re-stamp it and stop.
        if let existing = try? loadManifest(),
           existing.modelRepo == Self.modelRepo,
           existing.vocoderRepo == Self.vocoderRepo,
           Self.modelRevision.map({ $0 == existing.modelRevision }) ?? true,
           fm.fileExists(atPath: paths.weights.path) {
            progress(.verifying)
            if (try? LocalRuntimeInstaller.sha256(of: paths.weights)) == existing.weightsSHA256,
               (try? LocalRuntimeInstaller.sha256(of: paths.vocab)) == existing.vocabSHA256,
               (try? LocalRuntimeInstaller.sha256(of: paths.vocoderWeights))
                == existing.vocoderSHA256 {
                try write(Manifest(
                    modelRepo: existing.modelRepo,
                    modelRevision: existing.modelRevision,
                    weightsSource: existing.weightsSource,
                    weightsSHA256: existing.weightsSHA256,
                    weightsBytes: existing.weightsBytes,
                    vocabSHA256: existing.vocabSHA256,
                    vocoderRepo: existing.vocoderRepo,
                    vocoderSHA256: existing.vocoderSHA256,
                    requirementsLockSHA256: LocalRuntimeInstaller.requirementsLockSHA256,
                    arch: existing.arch,
                    archSource: existing.archSource,
                    installedAt: existing.installedAt))
                SRLog.event("f5.revalidated", [
                    "revision": String(existing.modelRevision.prefix(12)),
                ])
                return
            }
        }

        // The fetcher writes its stage here as it goes; this download is
        // gigabytes over an unknown link, so a static spinner would be
        // indistinguishable from a hang.
        try? fm.removeItem(at: paths.progressFile)
        progress(.downloading("Resolving model…"))
        let watcher = Task.detached(priority: .utility) { [paths] in
            var last = ""
            while !Task.isCancelled {
                if let stage = Self.readProgress(at: paths.progressFile), stage != last {
                    last = stage
                    progress(.downloading(stage))
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { watcher.cancel() }

        var arguments = [
            fetchSourceURL.path,
            "--repo", Self.modelRepo,
            "--dest", paths.modelDir.path,
            "--vocoder-repo", Self.vocoderRepo,
            "--vocoder-dest", paths.vocoderDir.path,
            "--report", paths.fetchReport.path,
            "--progress", paths.progressFile.path,
        ]
        if let revision = Self.modelRevision {
            arguments += ["--revision", revision]
        }
        if let revision = Self.vocoderRevision {
            arguments += ["--vocoder-revision", revision]
        }
        // Long enough for a multi-gigabyte download on a slow link; the
        // watchdog inside `run` still kills a genuinely wedged fetch.
        try await runtime.run(runtimePaths.venvPython, arguments, timeout: 7200,
                              environment: ["HF_HUB_DISABLE_TELEMETRY": "1"])
        watcher.cancel()
        try Task.checkCancellation()

        progress(.verifying)
        let report = try FetchReport.load(from: paths.fetchReport)

        // Re-hash in Swift rather than trusting the fetcher's own numbers:
        // this is what proves the files on disk are the ones it verified
        // against huggingface.co, and catches a truncated write.
        let weightsHash = try LocalRuntimeInstaller.sha256(of: paths.weights)
        guard weightsHash == report.modelSHA256 else {
            throw InstallError(message: "model weights hash mismatch after download")
        }
        let vocabHash = try LocalRuntimeInstaller.sha256(of: paths.vocab)
        guard vocabHash == report.vocabSHA256 else {
            throw InstallError(message: "vocabulary hash mismatch after download")
        }
        let vocoderHash = try LocalRuntimeInstaller.sha256(of: paths.vocoderWeights)
        guard vocoderHash == report.vocoderSHA256 else {
            throw InstallError(message: "vocoder hash mismatch after download")
        }

        // A repo that ships a reference recording gives a working voice out
        // of the box; one that does not leaves the user to add their own.
        if let reference = report.reference {
            do {
                try F5VoiceStore(paths: paths).importVoice(
                    name: "Model sample",
                    audio: URL(fileURLWithPath: reference.audio),
                    transcript: reference.text,
                    id: "model-sample")
            } catch {
                SRLog.error("f5.reference_import",
                            ["error": String(describing: type(of: error))])
            }
        }

        let weightsAttributes = try? fm.attributesOfItem(atPath: paths.weights.path)
        let manifest = Manifest(
            modelRepo: Self.modelRepo,
            modelRevision: report.revision,
            weightsSource: report.weightsSource,
            weightsSHA256: weightsHash,
            weightsBytes: weightsAttributes?[.size] as? Int ?? 0,
            vocabSHA256: vocabHash,
            vocoderRepo: Self.vocoderRepo,
            vocoderSHA256: vocoderHash,
            requirementsLockSHA256: LocalRuntimeInstaller.requirementsLockSHA256,
            arch: report.arch ?? .f5Base,
            archSource: report.archSource,
            installedAt: Date()
        )
        try write(manifest)
        try? fm.removeItem(at: paths.progressFile)
        SRLog.event("f5.installed", [
            "revision": String(report.revision.prefix(12)),
            "variant": (report.arch ?? .f5Base).variant.rawValue,
        ])
    }

    private func write(_ manifest: Manifest) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest, options: .atomic)
    }

    /// One human-readable line from the fetcher's progress file.
    private static func readProgress(at url: URL) -> String? {
        struct Raw: Decodable {
            let stage: String
            let detail: String?
        }
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        let detail = (raw.detail?.isEmpty == false) ? " (\(raw.detail!))" : ""
        switch raw.stage {
        case "resolving": return "Resolving model…"
        case "config": return "Reading model config…"
        case "downloading": return "Downloading Norwegian model\(detail)…"
        case "vocab": return "Downloading vocabulary…"
        case "reference": return "Downloading voice sample…"
        case "normalizing": return "Preparing checkpoint…"
        case "vocoder": return "Downloading vocoder…"
        case "verifying", "done": return "Verifying checksums…"
        default: return nil
        }
    }
}

/// What sr_f5_fetch.py reports back about the install it just did.
struct FetchReport: Decodable {
    struct Reference: Decodable {
        let audio: String
        let text: String
    }

    let revision: String
    let weightsSource: String
    let arch: F5Installer.Arch?
    let archSource: String?
    let reference: Reference?
    let modelSHA256: String
    let vocabSHA256: String
    let vocoderSHA256: String

    enum CodingKeys: String, CodingKey {
        case revision
        case weightsSource = "weights_source"
        case arch
        case archSource = "arch_source"
        case reference
        case modelSHA256 = "model_sha256"
        case vocabSHA256 = "vocab_sha256"
        case vocoderSHA256 = "vocoder_sha256"
    }

    static func load(from url: URL) throws -> FetchReport {
        guard let data = try? Data(contentsOf: url) else {
            throw InstallError(message: "the model fetcher produced no report")
        }
        do {
            return try JSONDecoder().decode(FetchReport.self, from: data)
        } catch {
            throw InstallError(message: "the model fetcher's report was unreadable")
        }
    }
}
