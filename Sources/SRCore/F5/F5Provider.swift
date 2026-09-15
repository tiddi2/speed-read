import Foundation

/// Shared runtime for the Norwegian offline voice.
///
/// It has its own installer, model directory and voice store, but no daemon
/// of its own: one supervised process serves both local engines over the same
/// socket, so a user with both voices installed pays for one Python process.
public final class F5Runtime: Sendable {
    public static let shared = F5Runtime()

    public let paths: F5Paths
    /// The shared local-runtime tree: venv, daemon script, socket and token.
    public let runtimePaths: KokoroPaths
    public let installer: F5Installer
    public let voices: F5VoiceStore

    public init(paths: F5Paths = .standard, runtimePaths: KokoroPaths = .standard) {
        self.paths = paths
        self.runtimePaths = runtimePaths
        self.installer = F5Installer(paths: paths, runtimePaths: runtimePaths)
        self.voices = F5VoiceStore(paths: paths)
    }

    /// The daemon supervisor, shared with Kokoro.
    public var supervisor: KokoroDaemonSupervisor { KokoroRuntime.shared.supervisor }

    public var isInstalled: Bool { installer.isInstalled }

    /// The architecture the daemon should load the checkpoint with: what the
    /// repo's config said, unless Settings overrides it.
    public func arch(settings: SettingsStore = SettingsStore()) -> F5Installer.Arch? {
        guard let manifest = try? installer.loadValidatedManifest() else { return nil }
        guard let override = settings.f5Variant else { return manifest.arch }
        return manifest.arch.applying(override)
    }

    /// Effective variant, for display and for the audio cache key.
    public func variant(settings: SettingsStore = SettingsStore()) -> F5Installer.Variant {
        settings.f5Variant
            ?? (try? installer.loadValidatedManifest())?.arch.variant
            ?? .base
    }
}

/// Norwegian offline provider (F-3). Text never leaves the machine (P-9).
///
/// Errors map exactly as Kokoro's do — transport problems to `.network`,
/// daemon-reported generation failures to `.http(500)` — so Auto mode's
/// fallback logic needs no special case for which local engine is in play.
public struct F5Provider: TTSProvider {
    public let id = "f5"
    public let isLocal = true

    /// Cache-key model identifier. Must match the daemon's
    /// OUTPUT_VERSIONS["f5"]; bump both when synthesis output changes.
    public static let cacheModelID = "f5-tts-no-t1"

    private let runtime: F5Runtime
    /// F5 is installed for Norwegian only. A mismatch is refused rather than
    /// read aloud in the wrong language (see SpeechLanguage) — routing should
    /// never build such a route; this is the backstop that makes it impossible.
    private let language: SpeechLanguage

    public init(runtime: F5Runtime = .shared, language: SpeechLanguage = .norwegian) {
        self.runtime = runtime
        self.language = language
    }

    public func voices() async throws -> [Voice] {
        runtime.voices.voices().map(\.asVoice)
    }

    public func synthesize(text: String, voiceID: String,
                           settings: VoiceSettings) async throws -> SynthesisResult {
        guard language.localEngine == .f5 else {
            SRLog.error("f5.language", ["lang": language.rawValue])
            throw TTSError.network(underlying: "f5: language not installed")
        }
        guard runtime.voices.voice(id: voiceID) != nil else {
            throw TTSError.network(underlying: "f5: reference voice missing")
        }
        do {
            try await runtime.supervisor.ensureRunning()
        } catch let error as KokoroDaemonSupervisor.SupervisorError {
            if case .notInstalled = error {
                throw TTSError.network(underlying: "f5: Norwegian voice not installed")
            }
            SRLog.error("f5.daemon", ["error": String(describing: error)])
            throw TTSError.network(underlying: "f5: daemon unavailable")
        }

        // Token file first: the live daemon may have been spawned by a
        // different sr process (GUI vs CLI) whose supervisor wrote it.
        let fileToken = (try? String(contentsOf: runtime.runtimePaths.tokenFile,
                                     encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if let fileToken, !fileToken.isEmpty {
            token = fileToken
        } else {
            token = await runtime.supervisor.token
        }
        let started = Date()

        // Speed is always 1.0 — sr applies rate client-side (F-8). lang_code
        // is unused by F5 (the checkpoint is the language) but the daemon
        // validates the field for every engine, so send the real one.
        let request = LocalTTSRequest(
            token: token,
            text: text,
            voice: voiceID,
            speed: "1.0",
            lang_code: String(language.rawValue.prefix(1)),
            engine: "f5")
        let requestLine: String
        do {
            requestLine = try KokoroWire.encode(request)
        } catch {
            throw TTSError.http(status: 500, body: "f5: request encoding failed")
        }

        let responseLine: String
        do {
            responseLine = try await UnixSocketLineClient.roundTrip(
                socketPath: runtime.runtimePaths.socketPath,
                line: requestLine,
                // Flow-matching sampling is slower than Kokoro's forward
                // pass, and the first Norwegian request also loads 1.4 GB
                // of weights. 240 s covers a cold start on a slow disk.
                timeout: 240
            )
        } catch is CancellationError {
            throw TTSError.cancelled
        } catch {
            if Task.isCancelled { throw TTSError.cancelled }
            SRLog.error("f5.socket", ["error": String(describing: type(of: error))])
            throw TTSError.network(underlying: "f5: socket I/O failed")
        }

        let response: KokoroWire.Response
        do {
            response = try KokoroWire.decodeResponse(
                responseLine, expecting: Self.cacheModelID)
        } catch {
            SRLog.error("f5.protocol", ["error": String(describing: type(of: error))])
            throw TTSError.http(status: 500, body: "f5: malformed daemon response")
        }
        switch response {
        case .error(let message):
            // A daemon that started before the Norwegian voice was installed
            // has no F5 configuration. Say what fixes it instead of the
            // daemon's bare word.
            if message == "engine not installed" {
                throw TTSError.network(underlying:
                    "f5: quit and reopen sr to finish enabling the Norwegian voice")
            }
            throw TTSError.http(status: 500, body: message)
        case .ok(let audioFilePath), .incompatible(let audioFilePath):
            // Trust boundary: only accept paths inside the daemon's tmp root.
            let tmpRoot = runtime.runtimePaths.tmpRoot.resolvingSymlinksInPath().path
            let url = URL(fileURLWithPath: audioFilePath).resolvingSymlinksInPath()
            guard url.path.hasPrefix(tmpRoot + "/") else {
                SRLog.error("f5.protocol", ["error": "audio path outside tmp root"])
                throw TTSError.http(status: 500, body: "f5: unexpected audio path")
            }
            defer {
                // Client owns the temp dir (see daemon protocol doc).
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
            guard case .ok = response else {
                throw TTSError.network(underlying: "f5: incompatible daemon")
            }
            guard let audio = try? Data(contentsOf: url),
                  AudioPayloadValidator.isWAV(audio) else {
                throw TTSError.http(status: 500, body: "f5: invalid audio file")
            }
            SRLog.event("f5.ok", [
                "chars": String(text.count),
                "bytes": String(audio.count),
                "latency_ms": String(Int(Date().timeIntervalSince(started) * 1000)),
            ])
            return SynthesisResult(audio: audio)  // no history ID, no billing
        }
    }
}
