import CryptoKit
import Foundation

/// The Python runtime both local voices share: a uv-managed venv holding the
/// pinned dependency closure, plus the daemon script (P-12).
///
/// Kokoro (English) and F5 (Norwegian) are separate downloads a user can
/// install independently, but they run in one venv, under one daemon, behind
/// one socket. That is what this type owns; each voice's installer owns only
/// its own model.
public struct LocalRuntimeInstaller: Sendable {
    /// Python interpreter for the venv (uv downloads a standalone build
    /// if the system lacks it — deterministic across machines).
    public static let pythonVersion = "3.12.11"
    /// Checksum of the bundled, fully-hashed dependency lock. The lock pins
    /// mlx-audio and misaki (Kokoro) and f5-tts-mlx (Norwegian) together, so
    /// one hash covers the whole local stack.
    public static let requirementsLockSHA256 =
        "208aa4818853ac41ef2789482568d43c213b71bc247ac50d1f8d0f96390a2412"

    public enum RuntimeProgress: Sendable {
        case creatingVenv
        case installingPackages
    }

    public let paths: KokoroPaths

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
    }

    /// The venv and daemon script exist. Says nothing about which models are
    /// installed — that is each voice installer's own question.
    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: paths.venvPython.path)
            && fm.fileExists(atPath: paths.daemonScript.path)
    }

    /// Create the venv, install the hashed dependency closure, and place the
    /// daemon script. Idempotent in effect: `uv venv --clear` rebuilds from
    /// scratch, which is also the repair path for a damaged runtime.
    public func install(
        daemonSourceURL: URL,
        requirementsLockURL: URL,
        progress: @Sendable (RuntimeProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.base, withIntermediateDirectories: true)

        guard let uv = Self.findUV() else {
            throw InstallError(message:
                "uv not found. Install it first: curl -LsSf https://astral.sh/uv/install.sh | sh")
        }

        // 1. venv (pinned interpreter; uv fetches a standalone build if needed)
        progress(.creatingVenv)
        try await run(uv, [
            "venv", "--no-config", "--clear",
            "--python", Self.pythonVersion, paths.venvDir.path,
        ])
        try Task.checkCancellation()

        // 2. Fully resolved + hashed dependency closure. Refuse a modified
        // bundled lock before letting uv execute any package code.
        progress(.installingPackages)
        let lockHash = try Self.sha256(of: requirementsLockURL)
        guard lockHash == Self.requirementsLockSHA256 else {
            throw InstallError(message: "requirements lock checksum mismatch")
        }
        try await run(uv, [
            "pip", "install", "--no-config",
            "--python", paths.venvPython.path,
            "--require-hashes",
            "--requirements", requirementsLockURL.path,
        ], timeout: 900)

        try Task.checkCancellation()

        // 3. daemon script
        if fm.fileExists(atPath: paths.daemonScript.path) {
            try fm.removeItem(at: paths.daemonScript)
        }
        try fm.copyItem(at: daemonSourceURL, to: paths.daemonScript)
    }

    /// Refresh the installed daemon script when the bundled one changed.
    /// The daemon runs from the App Support copy made at install time —
    /// without this, daemon fixes shipped in app updates never reach
    /// existing installs.
    public func syncDaemonScript(from source: URL) {
        guard isInstalled,
              let bundled = try? Data(contentsOf: source) else { return }
        let installed = try? Data(contentsOf: paths.daemonScript)
        guard bundled != installed else { return }
        do {
            try bundled.write(to: paths.daemonScript, options: .atomic)
            SRLog.event("kokoro.daemon_script_synced", [:])
        } catch {
            SRLog.error("kokoro.daemon_script_sync", ["error": String(describing: error)])
        }
    }

    /// The environment a child process gets: the caller's additions, minus
    /// anything that would let ambient configuration change what is installed.
    ///
    /// uv reads `UV_*` from the environment as well as from `uv.toml`, and
    /// `--no-config` only covers the files. That split is not academic: a
    /// stray `UV_EXCLUDE_NEWER` in a login shell makes `uv venv` refuse to
    /// start at all, which is how this was found. A stray `UV_INDEX_URL`
    /// would be quieter and worse, resolving the pinned closure from
    /// somewhere else — `--require-hashes` would still catch the bytes, but
    /// sr's local stack is meant to build the same way on every machine, so
    /// ambient uv settings get no say. Nothing else here reads `UV_*`, so
    /// stripping it for every child costs nothing.
    static func scrubbed(_ environment: [String: String],
                         adding extras: [String: String]) -> [String: String] {
        var scrubbed = environment.filter { !$0.key.hasPrefix("UV_") }
        scrubbed.merge(extras) { _, new in new }
        return scrubbed
    }

    /// Locate the uv binary (PATH, then the usual install locations).
    public static func findUV() -> URL? {
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/uv" }
        candidates += [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Streaming SHA-256 (weights run to gigabytes — never load whole into RAM).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Run a subprocess, returning stdout. Throws with the stderr tail on
    /// failure (package-manager output — content-free by nature).
    @discardableResult
    func run(
        _ executable: URL,
        _ arguments: [String],
        timeout: TimeInterval = 300,
        environment: [String: String] = [:]
    ) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = Self.scrubbed(
            ProcessInfo.processInfo.environment, adding: environment)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Arm the termination signal BEFORE run(): a handler assigned after
        // an instant exec failure never fires, hanging the install forever.
        // AsyncStream buffers the yield, so termination-before-await is safe.
        let terminated = AsyncStream<Void> { cont in
            process.terminationHandler = { _ in
                cont.yield()
                cont.finish()
            }
        }

        try process.run()

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            guard process.isRunning else { return }
            process.terminate()
            // SIGTERM escalation: a child ignoring it would hang the install.
            try await Task.sleep(for: .seconds(5))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }

        // Drain pipes off the calling task so big outputs can't deadlock.
        async let stdoutData = out.fileHandleForReading.readToEndAsync()
        async let stderrData = err.fileHandleForReading.readToEndAsync()

        // Cancelling the install (user quits mid-download) must kill the
        // subprocess — uv/pip/python otherwise keep running to completion.
        await withTaskCancellationHandler {
            for await _ in terminated { break }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
            // Cancellation has its own short escalation deadline. Reusing
            // the install timeout could keep AppKit in terminateLater for up
            // to an hour if uv/python ignores SIGTERM.
            Task.detached {
                try? await Task.sleep(for: .seconds(5))
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        try Task.checkCancellation()

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
            throw InstallError(message:
                "\(executable.lastPathComponent) \(arguments.first ?? "") failed (exit \(process.terminationStatus)): \(stderr.suffix(400))")
        }
        return stdout
    }
}

/// A failed install step, carrying the message the UI shows.
public struct InstallError: Error, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

extension FileHandle {
    /// Non-blocking full read for subprocess pipes.
    func readToEndAsync() async -> Data {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: (try? self.readToEnd()) ?? Data())
            }
        }
    }
}
