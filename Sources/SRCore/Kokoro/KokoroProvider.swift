import Foundation

/// Shared runtime for the local stack: one supervisor + installer pair.
public final class KokoroRuntime: Sendable {
    public static let shared = KokoroRuntime()

    public let paths: KokoroPaths
    public let supervisor: KokoroDaemonSupervisor
    public let installer: KokoroInstaller

    public init(paths: KokoroPaths = .standard) {
        self.paths = paths
        self.supervisor = KokoroDaemonSupervisor(paths: paths)
        self.installer = KokoroInstaller(paths: paths)
    }

    public var isInstalled: Bool { installer.isInstalled }
}

/// Local Kokoro provider (F-3). Text never leaves the machine (P-9).
///
/// Error mapping (feeds Auto-mode logic):
///   - not installed / daemon unreachable / protocol failure
///       → .network("kokoro: …")   (transport-level, content-free)
///   - daemon replied {"status":"error"}
///       → .http(status: 500, body: message)   (generation-level)
/// Both are `isFallbackTrigger == true`, which is harmless here: Auto mode
/// falls back cloud→local, never local→cloud (falling "back" to the cloud
/// would silently violate a local-only routing decision, P-8).
public struct KokoroProvider: TTSProvider {
    public let id = "kokoro"
    public let isLocal = true

    /// Cache-key model identifier (there is no user-selectable local model).
    /// The "-t2" suffix invalidates older audio that may contain silent
    /// placeholders for failed fragments. Bump whenever synthesis output
    /// semantics change so an older result is never replayed.
    public static let cacheModelID = "kokoro-82M-t2"

    /// Curated English subset (from the reference; full list in the model's
    /// VOICES.md). First letter encodes language: a=US, b=British.
    public static let presetVoices: [Voice] = [
        Voice(id: "bf_lily", name: "Lily — British, bright"),
        Voice(id: "af_heart", name: "Heart — warm"),
        Voice(id: "af_bella", name: "Bella — soft"),
        Voice(id: "af_nova", name: "Nova — confident"),
        Voice(id: "af_sarah", name: "Sarah — gentle"),
        Voice(id: "af_sky", name: "Sky — bright"),
        Voice(id: "am_adam", name: "Adam — deep"),
        Voice(id: "am_echo", name: "Echo — clear"),
        Voice(id: "am_eric", name: "Eric — steady"),
        Voice(id: "am_michael", name: "Michael — warm"),
        Voice(id: "bf_emma", name: "Emma — British, warm"),
        Voice(id: "bm_george", name: "George — British, deep"),
    ]

    /// Voices for `language`, empty when the local model cannot speak it.
    public static func presetVoices(for language: SpeechLanguage) -> [Voice] {
        presetVoices.filter { language.ownsLocalVoice($0.id) }
    }

    private let runtime: KokoroRuntime
    /// The language this route was built for. Kokoro has no Norwegian, so a
    /// mismatch is refused rather than read aloud in English (see
    /// SpeechLanguage) — routing should never build such a route, this is the
    /// backstop that makes it impossible.
    private let language: SpeechLanguage

    public init(runtime: KokoroRuntime = .shared, language: SpeechLanguage = .english) {
        self.runtime = runtime
        self.language = language
    }

    public func voices() async throws -> [Voice] { Self.presetVoices(for: language) }

    public func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        guard language.ownsLocalVoice(voiceID) else {
            SRLog.error("kokoro.language", ["lang": language.rawValue])
            throw TTSError.network(underlying: "kokoro: language not installed")
        }
        do {
            try await runtime.supervisor.ensureRunning()
        } catch let error as KokoroDaemonSupervisor.SupervisorError {
            if case .notInstalled = error {
                throw TTSError.network(underlying: "kokoro: local TTS not installed")
            }
            SRLog.error("kokoro.daemon", ["error": String(describing: error)])
            throw TTSError.network(underlying: "kokoro: daemon unavailable")
        }

        // Token file first: the live daemon may have been spawned by a
        // different sr process (GUI vs CLI) whose supervisor wrote it.
        let fileToken = (try? String(contentsOf: runtime.paths.tokenFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if let fileToken, !fileToken.isEmpty {
            token = fileToken
        } else {
            token = await runtime.supervisor.token
        }
        let started = Date()

        // Daemon protocol: one JSON request line, one JSON response line.
        // Speed is always 1.0 — sr applies rate client-side (F-8).
        let request = LocalTTSRequest(
            token: token,
            text: text,
            voice: voiceID,
            speed: "1.0",
            lang_code: String(voiceID.prefix(1))
        )
        let requestLine: String
        do {
            requestLine = try KokoroWire.encode(request)
        } catch {
            // Map wire errors into TTSError: anything else escapes the
            // pipeline's error handling entirely (the read would hang).
            throw TTSError.http(status: 500, body: "kokoro: request encoding failed")
        }

        let responseLine: String
        do {
            responseLine = try await UnixSocketLineClient.roundTrip(
                socketPath: runtime.paths.socketPath,
                line: requestLine,
                timeout: 120
            )
        } catch is CancellationError {
            throw TTSError.cancelled
        } catch {
            // A sibling chunk's failure cancels this task, which closes the
            // socket mid-read — that's a cancellation, not a daemon problem.
            if Task.isCancelled { throw TTSError.cancelled }
            SRLog.error("kokoro.socket", ["error": String(describing: type(of: error))])
            throw TTSError.network(underlying: "kokoro: socket I/O failed")
        }

        let response: KokoroWire.Response
        do {
            response = try KokoroWire.decodeResponse(responseLine)
        } catch {
            SRLog.error("kokoro.protocol", ["error": String(describing: type(of: error))])
            throw TTSError.http(status: 500, body: "kokoro: malformed daemon response")
        }
        switch response {
        case .error(let message):
            // Tag it: the message is the daemon's own wording, and the
            // error surface tells a local failure from a cloud one by
            // this prefix alone.
            throw TTSError.http(status: 500, body: "kokoro: \(message)")
        case .ok(let audioFilePath), .incompatible(let audioFilePath):
            // Trust boundary: only accept paths inside the daemon's tmp root.
            // We read the file AND delete its parent directory — a stale or
            // hostile daemon must not be able to point that at ~/Documents.
            let tmpRoot = runtime.paths.tmpRoot.resolvingSymlinksInPath().path
            let url = URL(fileURLWithPath: audioFilePath).resolvingSymlinksInPath()
            guard url.path.hasPrefix(tmpRoot + "/") else {
                SRLog.error("kokoro.protocol", ["error": "audio path outside tmp root"])
                throw TTSError.http(status: 500, body: "kokoro: unexpected audio path")
            }
            defer {
                // Client owns the temp dir (see daemon protocol doc).
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            // A GUI-owned daemon may still run the old script after a CLI
            // update. Reject its result before playback/cache, and clean up
            // its temp directory without terminating another process's daemon.
            guard case .ok = response else {
                throw TTSError.network(underlying: "kokoro: incompatible daemon")
            }
            guard let audio = try? Data(contentsOf: url),
                  AudioPayloadValidator.isWAV(audio) else {
                throw TTSError.http(status: 500, body: "kokoro: invalid audio file")
            }
            SRLog.event("kokoro.ok", [
                "chars": String(text.count),
                "bytes": String(audio.count),
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ])
            return SynthesisResult(audio: audio)  // no history ID, no billing
        }
    }
}

// MARK: - Wire format

/// One request line on the daemon socket. `engine` selects Kokoro or F5;
/// it defaults to Kokoro so the field can be omitted, which is what a
/// pre-Norwegian client did.
struct LocalTTSRequest: Codable {
    let token: String
    let text: String
    let voice: String
    let speed: String
    let lang_code: String
    var engine: String = "kokoro"
}

enum KokoroWire {
    enum Response: Equatable {
        case ok(audioFile: String)
        case incompatible(audioFile: String)
        case error(message: String)
    }

    struct WireError: Error {
        let message: String
    }

    static func encode(_ request: LocalTTSRequest) throws -> String {
        let data = try JSONEncoder().encode(request)
        guard let line = String(data: data, encoding: .utf8) else {
            throw WireError(message: "request encoding failed")
        }
        return line
    }

    /// `expected` is the output version this client can use. A daemon
    /// left over from an older sr answers with a different one, and its
    /// audio must never reach playback or the cache.
    static func decodeResponse(
        _ line: String, expecting expected: String = KokoroProvider.cacheModelID
    ) throws -> Response {
        struct Raw: Codable {
            let status: String
            let audio_file: String?
            let output_version: String?
            let message: String?
        }
        let raw = try JSONDecoder().decode(Raw.self, from: Data(line.utf8))
        if raw.status == "ok", let file = raw.audio_file {
            return raw.output_version == expected
                ? .ok(audioFile: file) : .incompatible(audioFile: file)
        }
        return .error(message: raw.message ?? "unknown daemon error")
    }
}

// MARK: - Unix socket client

/// Minimal blocking-I/O Unix socket client run on a utility queue, with
/// cancellation support (task cancellation closes the fd, unblocking I/O).
enum UnixSocketLineClient {
    struct SocketError: Error {
        let message: String
    }

    static func roundTrip(socketPath: String, line: String, timeout: TimeInterval) async throws -> String {
        let fdBox = FDBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        cont.resume(returning: try roundTripBlocking(
                            socketPath: socketPath, line: line,
                            timeout: timeout, fdBox: fdBox))
                    } catch {
                        cont.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            fdBox.cancel()
        }
    }

    /// Thread-safe holder so cancellation can unblock I/O from any thread.
    ///
    /// Cancellation uses shutdown(2), not close(2): closing from a foreign
    /// thread frees the fd NUMBER, which the kernel may immediately reassign
    /// to an unrelated descriptor that the still-running I/O loop would then
    /// read/write. shutdown() wakes blocked I/O but keeps the number reserved;
    /// only the owning thread's `closeIfOpen()` (via defer) actually closes.
    final class FDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var cancelled = false

        /// Returns false if already cancelled (fd should not be used).
        func set(_ newFD: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            fd = newFD
            return true
        }

        /// Called from the cancellation handler (any thread).
        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if fd >= 0 {
                shutdown(fd, SHUT_RDWR)
            }
        }

        /// Called only by the owning I/O thread, in its defer.
        func closeIfOpen() {
            lock.lock()
            defer { lock.unlock() }
            if fd >= 0 {
                close(fd)
                fd = -1
            }
        }
    }

    private static func roundTripBlocking(
        socketPath: String, line: String, timeout: TimeInterval, fdBox: FDBox
    ) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError(message: "socket() failed") }
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(fd)
            throw SocketError(message: "SO_NOSIGPIPE failed")
        }
        guard fdBox.set(fd) else {
            close(fd)
            throw CancellationError()
        }
        defer { fdBox.closeIfOpen() }

        // I/O timeouts so a hung daemon can't wedge us past `timeout`.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let fits = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
            let bytes = Array(socketPath.utf8)
            guard bytes.count < raw.count else { return false }
            raw.copyBytes(from: bytes)
            return true
        }
        guard fits else { throw SocketError(message: "socket path too long") }

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SocketError(message: "connect failed") }

        let payload = Array((line + "\n").utf8)
        var sent = 0
        while sent < payload.count {
            let n = payload.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: sent), payload.count - sent)
            }
            guard n > 0 else { throw SocketError(message: "write failed") }
            sent += n
        }

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !received.contains(0x0A) {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { throw SocketError(message: "read failed or timed out") }
            if n == 0 { break }  // daemon closed
            received.append(contentsOf: buffer[0..<n])
            if received.count > 1 << 20 {
                throw SocketError(message: "oversized response")
            }
        }
        guard let newline = received.firstIndex(of: 0x0A) else {
            throw SocketError(message: "connection closed before response")
        }
        guard let response = String(data: received[..<newline], encoding: .utf8) else {
            throw SocketError(message: "non-UTF8 response")
        }
        return response
    }
}
