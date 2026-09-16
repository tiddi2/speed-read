import Foundation
import Security

/// Supervises the Kokoro daemon process (P-9).
///
/// Spawns the venv Python running sr_tts_server.py --managed with a fresh
/// per-launch auth token, waits for the Unix socket to appear (cold model
/// load can take tens of seconds), and restarts with exponential backoff
/// (1 s → 30 s cap, reset after 60 s healthy).
public actor KokoroDaemonSupervisor {
    public let paths: KokoroPaths

    private var process: Process?
    private(set) public var token: String = ""
    private var consecutiveFailures = 0
    private var lastSpawnAttempt: Date?
    private var healthySince: Date?

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
    }

    public var socketPath: String { paths.socketPath }

    public enum SupervisorError: Error {
        case notInstalled
        case spawnFailed(String)
        case startupTimeout
        case backingOff(retryAfter: TimeInterval)
    }

    /// Ensure a healthy daemon is running. Returns when the socket is
    /// connectable. Throws SupervisorError on failure.
    public func ensureRunning() async throws {
        // Already healthy? Accept a connectable socket even when we didn't
        // spawn the daemon (another sr process — GUI vs CLI — owns it; the
        // shared token file makes it usable, and the flock guard would make
        // our own spawn exit immediately anyway).
        if Self.socketConnectable(paths.socketPath) {
            if let since = healthySince, Date().timeIntervalSince(since) > 60 {
                consecutiveFailures = 0  // stable — reset backoff
            }
            if healthySince == nil { healthySince = Date() }
            return
        }
        healthySince = nil

        // Actors are reentrant: while one caller awaits inside spawn(), a
        // concurrent synthesize would re-enter here, see no socket, and
        // spawn a second daemon over the first. Share one startup task.
        if let inFlight = startupTask {
            try await inFlight.value
            return
        }

        guard KokoroInstaller(paths: paths).isInstalled
                || F5Runtime.shared.isInstalled else {
            throw SupervisorError.notInstalled
        }

        let task = Task { [self] in
            // Exponential backoff between spawn attempts.
            if let last = lastSpawnAttempt {
                let delay = min(pow(2.0, Double(consecutiveFailures)), 30.0)
                let elapsed = Date().timeIntervalSince(last)
                if consecutiveFailures > 0 && elapsed < delay {
                    try await Task.sleep(for: .seconds(delay - elapsed))
                }
            }
            try await spawn()
        }
        startupTask = task
        defer { startupTask = nil }
        try await task.value
    }

    private var startupTask: Task<Void, Error>?

    private func spawn(retryOnLockConflict: Bool = true) async throws {
        stopProcess()

        lastSpawnAttempt = Date()
        token = Self.generateToken()

        // The token file is written by the DAEMON, after it wins its
        // exclusive lock — never by the supervisor. Writing it here would
        // let a losing contender overwrite the live daemon's token
        // (GUI pre-warm racing a CLI spawn poisons every client).
        try? FileManager.default.createDirectory(at: paths.base,
                                                 withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = paths.venvPython
        p.arguments = [paths.daemonScript.path, "--managed"]
        var env = ["SR_DAEMON_TOKEN": token]
        let fm = FileManager.default

        // P-12: hand the daemon the installer's hash-verified paths so it
        // runs exactly the verified bytes, not whatever a repo id resolves to
        // on the day. Either engine may be absent — a user can install the
        // English voice, the Norwegian one, or both — so each block is
        // conditional and at least one must succeed.
        if let manifest = try? KokoroInstaller(paths: paths).loadValidatedManifest() {
            // Passed via a stable "Kokoro-82M-bf16" symlink — mlx-audio
            // derives the model TYPE from the basename, so the raw snapshot
            // dir (named by revision hash) would not load.
            //
            // `fileExists` follows symlinks and returns false for a dangling
            // one. Ask for the link destination first so stale cache cleanup
            // cannot strand an invisible link that blocks recreation.
            if (try? fm.destinationOfSymbolicLink(atPath: paths.modelLink.path)) != nil {
                try fm.removeItem(at: paths.modelLink)
            } else if fm.fileExists(atPath: paths.modelLink.path) {
                throw SupervisorError.spawnFailed("model link path is not a symlink")
            }
            try fm.createSymbolicLink(
                at: paths.modelLink,
                withDestinationURL: URL(fileURLWithPath: manifest.snapshotPath))
            guard fm.fileExists(atPath: paths.modelLink.path) else {
                throw SupervisorError.spawnFailed("verified model link could not be created")
            }
            env["SR_MODEL_PATH"] = paths.modelLink.path
        }

        let f5 = F5Runtime.shared
        if f5.isInstalled, let arch = f5.arch() {
            try? fm.createDirectory(at: f5.paths.voicesDir, withIntermediateDirectories: true)
            env["SR_F5_MODEL_PATH"] = f5.paths.modelDir.path
            env["SR_F5_VOCODER_PATH"] = f5.paths.vocoderDir.path
            env["SR_F5_VOICES_PATH"] = f5.paths.voicesDir.path
            env["SR_F5_ARCH"] = arch.environmentJSON
        }

        guard env["SR_MODEL_PATH"] != nil || env["SR_F5_MODEL_PATH"] != nil else {
            throw SupervisorError.notInstalled
        }
        p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            consecutiveFailures += 1
            throw SupervisorError.spawnFailed(String(describing: error))
        }
        process = p
        SRLog.event("kokoro.daemon_spawn", ["pid": String(p.processIdentifier)])

        // Wait for the socket (cold start loads the model: allow 60 s).
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if Self.socketConnectable(paths.socketPath) {
                consecutiveFailures = 0
                healthySince = Date()
                SRLog.event("kokoro.daemon_ready", [:])
                return
            }
            if !p.isRunning {
                if p.terminationStatus == 0 {
                    // Exit 0 = flock conflict: another daemon holds the lock
                    // (possibly one that's mid-shutdown, e.g. hotkey pressed
                    // during idle unload). Wait for either its socket or the
                    // lock to free up, then respawn once.
                    SRLog.event("kokoro.daemon_lock_conflict", [:])
                    let conflictDeadline = Date().addingTimeInterval(10)
                    while Date() < conflictDeadline {
                        if Self.socketConnectable(paths.socketPath) {
                            consecutiveFailures = 0
                            healthySince = Date()
                            SRLog.event("kokoro.daemon_ready", ["via": "existing"])
                            return
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                    // Lock holder never produced a socket — likely finished
                    // dying; one respawn attempt. Bounded: a second conflict
                    // means the holder is wedged, and recursing again would
                    // spawn a python process every 10 s forever.
                    consecutiveFailures += 1
                    guard retryOnLockConflict else {
                        throw SupervisorError.startupTimeout
                    }
                    try await spawn(retryOnLockConflict: false)
                    return
                }
                consecutiveFailures += 1
                throw SupervisorError.spawnFailed(
                    "daemon exited during startup (status \(p.terminationStatus))")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        consecutiveFailures += 1
        stopProcess()
        throw SupervisorError.startupTimeout
    }

    public func stop() {
        stopProcess()
        healthySince = nil
    }

    private func stopProcess() {
        if let p = process, p.isRunning {
            p.terminate()  // SIGTERM → daemon cleans up socket/pid and exits
        }
        process = nil
    }

    // MARK: - Static helpers (also used by tests)

    /// 32 random bytes as 64 hex chars.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SystemRandomNumberGenerator is also cryptographically secure.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Health check: can we connect to the Unix socket right now?
    public static func socketConnectable(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(path.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard ok else { return false }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        return result == 0
    }
}
