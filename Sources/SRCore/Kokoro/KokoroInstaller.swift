import Foundation

/// Installs the Kokoro (English) model on top of the shared local runtime,
/// with SHA-256 verification (P-12). The venv, the pinned dependency
/// closure and the daemon script belong to LocalRuntimeInstaller.
public struct KokoroInstaller: Sendable {
    // ── Supply-chain pins (P-12), resolved 2026-07-06 ──
    /// PyPI: latest mlx-audio at pin time.
    public static let mlxAudioVersion = "0.4.4"
    /// Kokoro's English G2P is an *optional* mlx-audio dependency — without
    /// it every generation throws ImportError. Pinned like mlx-audio (P-12).
    public static let misakiVersion = "0.9.4"
    /// misaki's G2P loads a spaCy model and tries to DOWNLOAD it at runtime
    /// if absent (fails in pip-less uv venvs, and unpinned downloads violate
    /// P-12) — so install the exact wheel up front.
    public static let spacyModelWheel =
        "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"
    /// The venv interpreter and dependency lock are shared with the
    /// Norwegian voice; these forward to the runtime installer that owns them
    /// so a manifest written here still records what was actually installed.
    public static var pythonVersion: String { LocalRuntimeInstaller.pythonVersion }
    public static var requirementsLockSHA256: String {
        LocalRuntimeInstaller.requirementsLockSHA256
    }
    /// huggingface.co model repo + immutable revision (main @ pin time).
    public static let modelRepo = "mlx-community/Kokoro-82M-bf16"
    public static let modelRevision = "a71e4d38b236d968966a2002c4c895dbd12b1c3c"
    /// SHA-256 of the files that define model behavior, at the pinned
    /// revision. Verified after download, recorded in manifest.json.
    public static let weightsFile = "kokoro-v1_0.safetensors"
    public static let weightsSHA256 =
        "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8"
    public static let configSHA256 =
        "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f"

    public enum InstallProgress: Sendable {
        case creatingVenv
        case installingPackages
        case downloadingModel   // ~327 MB; huggingface_hub gives no byte callback here
        case verifying
        case done
        case failed(String)
    }

    public struct Manifest: Codable, Sendable {
        public let mlxAudioVersion: String
        public let modelRepo: String
        public let modelRevision: String
        public let weightsSHA256: String
        public let configSHA256: String
        /// Nil only for manifests written before the hashed-lock installer.
        /// Such installs remain decodable so the UI can offer an explicit
        /// update instead of silently pretending the model disappeared.
        public let requirementsLockSHA256: String?
        public let snapshotPath: String
        public let installedAt: Date
    }

    public let paths: KokoroPaths

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
    }

    /// The venv + daemon script Kokoro shares with the Norwegian voice.
    private var runtime: LocalRuntimeInstaller { LocalRuntimeInstaller(paths: paths) }

    /// Installed = shared runtime + verified Kokoro manifest present.
    public var isInstalled: Bool {
        runtime.isInstalled && (try? loadValidatedManifest()) != nil
    }

    /// A prior or damaged install exists but does not satisfy current pins.
    public var needsUpdate: Bool {
        runtime.isInstalled
            && FileManager.default.fileExists(atPath: paths.manifest.path)
            && !isInstalled
    }

    public func loadManifest() throws -> Manifest {
        let data = try Data(contentsOf: paths.manifest)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Validate the cheap, immutable install invariants on every launch. The
    /// large weights were hashed during install; here we make sure the manifest
    /// still names those pins and its verified snapshot still exists.
    public func loadValidatedManifest() throws -> Manifest {
        let manifest = try loadManifest()
        guard manifest.mlxAudioVersion == Self.mlxAudioVersion,
              manifest.modelRepo == Self.modelRepo,
              manifest.modelRevision == Self.modelRevision,
              manifest.weightsSHA256 == Self.weightsSHA256,
              manifest.configSHA256 == Self.configSHA256,
              manifest.requirementsLockSHA256 == Self.requirementsLockSHA256 else {
            throw InstallError(message: "installed manifest does not match bundled pins")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: manifest.snapshotPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: manifest.snapshotPath)
                    .appendingPathComponent(Self.weightsFile).path),
              FileManager.default.fileExists(atPath:
                URL(fileURLWithPath: manifest.snapshotPath)
                    .appendingPathComponent("config.json").path) else {
            throw InstallError(message: "verified model snapshot is missing")
        }
        return manifest
    }

    /// Refresh the installed daemon script when the bundled one changed.
    public func syncDaemonScript(from source: URL) {
        runtime.syncDaemonScript(from: source)
    }

    /// Locate the uv binary (PATH, then the usual install locations).
    public static func findUV() -> URL? { LocalRuntimeInstaller.findUV() }

    /// Run the full install. `daemonSourceURL` is the sr_tts_server.py to
    /// copy in (from the app bundle's resources or the repo's daemon/ dir).
    public func install(
        daemonSourceURL: URL,
        requirementsLockURL: URL
    ) -> AsyncStream<InstallProgress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await runInstall(
                        daemonSourceURL: daemonSourceURL,
                        requirementsLockURL: requirementsLockURL) {
                        continuation.yield($0)
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    SRLog.event("kokoro.install_cancelled", [:])
                } catch {
                    let message = (error as? InstallError)?.message
                        ?? error.localizedDescription
                    SRLog.error("kokoro.install", ["error": message])
                    continuation.yield(.failed(message))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runInstall(
        daemonSourceURL: URL,
        requirementsLockURL: URL,
        progress: @Sendable (InstallProgress) -> Void
    ) async throws {
        let fm = FileManager.default

        // 1-3. shared venv, pinned dependency closure, daemon script
        try await runtime.install(
            daemonSourceURL: daemonSourceURL,
            requirementsLockURL: requirementsLockURL
        ) { step in
            switch step {
            case .creatingVenv: progress(.creatingVenv)
            case .installingPackages: progress(.installingPackages)
            }
        }
        let lockHash = try Self.sha256(of: requirementsLockURL)

        try Task.checkCancellation()

        // 4. model download at the pinned revision (huggingface.co — the
        // only network fetch, per the P-11 allowlist; explicit user action)
        progress(.downloadingModel)
        let snippet = """
        import os, sys
        os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
        from huggingface_hub import snapshot_download
        print(snapshot_download("\(Self.modelRepo)", revision="\(Self.modelRevision)"))
        """
        let snapshotPath = try await run(
            paths.venvPython, ["-c", snippet], timeout: 3600
        ).trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n").last ?? ""
        guard !snapshotPath.isEmpty, fm.fileExists(atPath: snapshotPath) else {
            throw InstallError(message: "model download did not produce a snapshot path")
        }

        // 5. verify hashes (P-12)
        progress(.verifying)
        let snapshot = URL(fileURLWithPath: snapshotPath)
        let weightsHash = try Self.sha256(of: snapshot.appendingPathComponent(Self.weightsFile))
        guard weightsHash == Self.weightsSHA256 else {
            throw InstallError(message:
                "weights hash mismatch: expected \(Self.weightsSHA256), got \(weightsHash)")
        }
        let configHash = try Self.sha256(of: snapshot.appendingPathComponent("config.json"))
        guard configHash == Self.configSHA256 else {
            throw InstallError(message:
                "config hash mismatch: expected \(Self.configSHA256), got \(configHash)")
        }

        // 6. manifest
        let manifest = Manifest(
            mlxAudioVersion: Self.mlxAudioVersion,
            modelRepo: Self.modelRepo,
            modelRevision: Self.modelRevision,
            weightsSHA256: weightsHash,
            configSHA256: configHash,
            requirementsLockSHA256: lockHash,
            snapshotPath: snapshotPath,
            installedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: paths.manifest)
        SRLog.event("kokoro.installed", [
            "mlx_audio": Self.mlxAudioVersion,
            "revision": String(Self.modelRevision.prefix(12)),
        ])
    }

    /// Streaming SHA-256, shared with the runtime installer.
    public static func sha256(of url: URL) throws -> String {
        try LocalRuntimeInstaller.sha256(of: url)
    }

    private func run(
        _ executable: URL, _ arguments: [String], timeout: TimeInterval = 300
    ) async throws -> String {
        try await runtime.run(executable, arguments, timeout: timeout)
    }
}
