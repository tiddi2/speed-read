import Foundation

/// ElevenLabs cloud provider (F-3).
///
/// Network endpoints (P-11 allowlist): api.elevenlabs.io only.
/// API speed is pinned at 1.0 — playback rate is client-side (F-8).
public struct ElevenLabsProvider: TTSProvider {
    public let id = "elevenlabs"
    public let isLocal = false

    public static let defaultModelID = "eleven_flash_v2_5"
    public static let outputFormat = "mp3_44100_128"

    public static let models: [(name: String, id: String)] = [
        ("Flash v2.5 — fastest", "eleven_flash_v2_5"),
        ("Turbo v2.5 — fast, ½ cost", "eleven_turbo_v2_5"),
        ("Multilingual v2 — max quality", "eleven_multilingual_v2"),
        ("v3 — most expressive", "eleven_v3"),
    ]

    /// Models that accept `language_code` and will therefore stay in one
    /// language instead of detecting it from the text. The v2.5 pair are also
    /// the only models that speak Norwegian at all (added alongside Hungarian
    /// and Vietnamese in the 32-language v2.5 release); Multilingual v2 covers
    /// 29 languages without it, and v3 rejects the parameter outright.
    ///
    /// Sending `language_code` to any other model is an API error, so the
    /// language is dropped rather than sent — see `lockedLanguageCode`.
    public static let languageLockedModelIDs: Set<String> = [
        "eleven_flash_v2_5",
        "eleven_turbo_v2_5",
    ]

    public static func supportsLanguageLock(_ modelID: String) -> Bool {
        languageLockedModelIDs.contains(modelID)
    }

    /// The language code that will actually be sent for `language` on
    /// `modelID` — nil when the model cannot be pinned to a language.
    ///
    /// Callers use this for both the request and the cache key, so cached
    /// audio is never replayed as if it had been language-locked.
    public static func lockedLanguageCode(
        for language: SpeechLanguage?,
        modelID: String
    ) -> String? {
        guard let language, supportsLanguageLock(modelID) else { return nil }
        return language.elevenLabsLanguageCode
    }

    /// Bootstrap fallback only — the picker fetches the account's real voice
    /// list (F-10). The reference repo's wider preset list included library
    /// voices that 402 on free plans ("paid_plan_required"); these three are
    /// standard premade voices present on every account.
    public static let presetVoices: [Voice] = [
        Voice(id: "pFZP5JQG7iQjIQuC4Bku", name: "Lily — velvety actress"),
        Voice(id: "Xb7hH8MSUJpSbSDYk0k2", name: "Alice — clear educator"),
        Voice(id: "pNInz6obpgDQGcFmaJgB", name: "Adam — dominant, firm"),
    ]

    public var modelID: String
    /// ISO 639-1 language to pin this provider to, already filtered down to
    /// what `modelID` accepts (nil = let the model detect the language).
    public let languageCode: String?

    public init(modelID: String = ElevenLabsProvider.defaultModelID,
                language: SpeechLanguage? = nil) {
        self.modelID = modelID
        self.languageCode = Self.lockedLanguageCode(for: language, modelID: modelID)
    }

    public func voices() async throws -> [Voice] {
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw TTSError.http(status: status, body: nil)
        }
        struct VoiceList: Decodable {
            struct V: Decodable {
                let voice_id: String
                let name: String
            }
            let voices: [V]
        }
        let list = try JSONDecoder().decode(VoiceList.self, from: data)
        return list.voices.map { Voice(id: $0.voice_id, name: $0.name) }
    }

    public func synthesize(text: String, voiceID: String, settings: VoiceSettings) async throws -> SynthesisResult {
        // Test seam for T-7 (fallback verification): behave exactly like a
        // quota-exhausted account without touching the network.
        if ProcessInfo.processInfo.environment["SR_SIMULATE_CLOUD_FAILURE"] == "1" {
            throw TTSError.http(status: 429, body: nil)
        }
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }

        // Voice IDs come from settings / the voices API — encode rather than
        // trust, and fail cleanly instead of force-unwrapping.
        guard let encodedVoice = voiceID.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
              var components = URLComponents(
                string: "https://api.elevenlabs.io/v1/text-to-speech/\(encodedVoice)/stream")
        else {
            throw TTSError.http(status: 400, body: "invalid voice ID")
        }
        components.queryItems = [URLQueryItem(name: "output_format", value: Self.outputFormat)]
        guard let url = components.url else {
            throw TTSError.http(status: 400, body: "invalid voice ID")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            struct Settings: Encodable {
                let stability: Double
                let similarity_boost: Double
                let style: Double
                let use_speaker_boost: Bool
                let speed: Double
            }
            let text: String
            let model_id: String
            /// Omitted entirely when nil — models outside
            /// `languageLockedModelIDs` reject the field.
            let language_code: String?
            let voice_settings: Settings
        }
        request.httpBody = try JSONEncoder().encode(Body(
            text: text,
            model_id: modelID,
            language_code: languageCode,
            voice_settings: .init(
                stability: settings.stability,
                similarity_boost: settings.similarityBoost,
                style: settings.style,
                use_speaker_boost: settings.useSpeakerBoost,
                speed: 1.0  // F-8: cached audio stays speed-agnostic
            )
        ))

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw TTSError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            // URLSession reports task cancellation as URLError, not Swift
            // CancellationError — without this it's mislogged as a network
            // failure (and would count as a fallback trigger).
            throw TTSError.cancelled
        } catch {
            SRLog.error("elevenlabs.network", ["error": String(describing: type(of: error))])
            throw TTSError.network(underlying: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TTSError.network(underlying: "non-HTTP response")
        }
        let latencyMS = Int(Date().timeIntervalSince(started) * 1000)

        guard http.statusCode == 200 else {
            // Error bodies are provider JSON (quota messages etc.), safe to log
            // truncated — they never echo the input text for auth/quota errors,
            // but cap and strip to be safe.
            let body = String(data: data.prefix(300), encoding: .utf8)
            SRLog.error("elevenlabs.http", [
                "status": String(http.statusCode),
                "chars": String(text.count),
                "latency_ms": String(latencyMS),
                "model": modelID,
                "lang": languageCode ?? "auto",
            ])
            throw TTSError.http(status: http.statusCode, body: body)
        }

        let historyID = http.value(forHTTPHeaderField: "history-item-id")
        let billed = http.value(forHTTPHeaderField: "character-cost").flatMap(Int.init)
        guard AudioPayloadValidator.isMP3(data) else {
            SRLog.error("elevenlabs.invalid_audio", [
                "bytes": String(data.count),
                "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? "missing",
                "history_id_present": historyID == nil ? "0" : "1",
            ])
            throw TTSError.invalidAudio(
                historyItemID: historyID,
                billedCharacters: billed)
        }

        SRLog.event("elevenlabs.ok", [
            "chars": String(text.count),
            "billed": String(billed ?? -1),
            "bytes": String(data.count),
            "latency_ms": String(latencyMS),
            "model": modelID,
            "lang": languageCode ?? "auto",
            "history_id_present": historyID == nil ? "0" : "1",
        ])
        return SynthesisResult(audio: data, remoteHistoryItemID: historyID, billedCharacters: billed)
    }

    // MARK: - Account info (C-1)

    public struct Subscription: Sendable {
        public let characterCount: Int
        public let characterLimit: Int
        public var remaining: Int { max(characterLimit - characterCount, 0) }
    }

    public func subscription() async throws -> Subscription {
        guard let key = KeychainStore.readAPIKey() else { throw TTSError.missingAPIKey }
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TTSError.http(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: nil)
        }
        struct Sub: Decodable {
            let character_count: Int
            let character_limit: Int
        }
        let sub = try JSONDecoder().decode(Sub.self, from: data)
        return Subscription(characterCount: sub.character_count, characterLimit: sub.character_limit)
    }

    /// Delete a generation from account history (P-6). Best-effort.
    /// Returns the HTTP status, or nil on network failure — callers need to
    /// distinguish 404 (item not materialized yet, or already gone) from
    /// transient failures.
    public func deleteHistoryItem(_ historyItemID: String) async -> Int? {
        guard let key = KeychainStore.readAPIKey() else { return nil }
        // History IDs come from a response header — encode, don't trust.
        guard let encodedID = historyItemID.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://api.elevenlabs.io/v1/history/\(encodedID)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 15
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        SRLog.event("history.delete", ["status": String(http.statusCode)])
        return http.statusCode
    }
}
