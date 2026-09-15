import Foundation

/// Non-secret preferences in UserDefaults (com.patrickellis.sr).
/// Secrets live in the Keychain only (P-1).
public struct SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        /// Pre-language-profile keys, still read as the seed for English (and
        /// as the voice seed for every language — an ElevenLabs voice is not
        /// language-specific). Never written to any more.
        static let legacyVoiceID = "voiceID"
        static let legacyModelID = "modelID"
        static let legacyLocalVoiceID = "localVoiceID"
        static func voiceID(_ language: SpeechLanguage) -> String {
            "voiceID.\(language.rawValue)"
        }
        static func modelID(_ language: SpeechLanguage) -> String {
            "modelID.\(language.rawValue)"
        }
        static func localVoiceID(_ language: SpeechLanguage) -> String {
            "localVoiceID.\(language.rawValue)"
        }
        static let playbackRate = "playbackRate"
        static let sentencePauseMS = "sentencePauseMS"
        static let stability = "stability"
        static let similarityBoost = "similarityBoost"
        static let style = "style"
        static let useSpeakerBoost = "useSpeakerBoost"
        static let autoDeleteHistory = "autoDeleteHistory"
        static let cacheEnabled = "cacheEnabled"
        static let backendMode = "backendMode"
        static let readerOverlayEnabled = "readerOverlayEnabled"
        static let readerShowsPreviousSentence = "readerShowsPreviousSentence"
        static let readerShowsCurrentSentence = "readerShowsCurrentSentence"
        static let readerShowsNextSentence = "readerShowsNextSentence"
        static let readerOverlayOffsetX = "readerOverlayOffsetX"
        static let readerOverlayOffsetY = "readerOverlayOffsetY"
    }

    /// Backend modes (F-3): Auto = cloud with local fallback.
    public enum BackendMode: String, CaseIterable, Sendable {
        case auto, cloud, local
    }

    // MARK: - Per-language voice profiles

    /// Cloud voice for `language`. Falls through to the pre-profile key so an
    /// existing voice choice is inherited rather than reset.
    public func voiceID(for language: SpeechLanguage) -> String {
        defaults.string(forKey: Key.voiceID(language))
            ?? defaults.string(forKey: Key.legacyVoiceID)
            ?? ElevenLabsProvider.presetVoices[0].id
    }

    public func setVoiceID(_ voiceID: String, for language: SpeechLanguage) {
        defaults.set(voiceID, forKey: Key.voiceID(language))
    }

    /// Cloud model for `language`. Defaults (and downgrades an inherited
    /// choice) to a model that accepts `language_code`: a model that cannot be
    /// pinned to a language would detect it from the text instead, which is
    /// the one thing language profiles exist to prevent.
    public func modelID(for language: SpeechLanguage) -> String {
        if let stored = defaults.string(forKey: Key.modelID(language)) {
            return stored
        }
        if let legacy = defaults.string(forKey: Key.legacyModelID),
           ElevenLabsProvider.supportsLanguageLock(legacy) {
            return legacy
        }
        return ElevenLabsProvider.defaultModelID
    }

    public func setModelID(_ modelID: String, for language: SpeechLanguage) {
        defaults.set(modelID, forKey: Key.modelID(language))
    }

    /// Local (Kokoro) voice for `language`, or nil when the local model has no
    /// voices for it (Norwegian). A stored voice from another language is
    /// ignored rather than used.
    public func localVoiceID(for language: SpeechLanguage) -> String? {
        let candidates = [
            defaults.string(forKey: Key.localVoiceID(language)),
            defaults.string(forKey: Key.legacyLocalVoiceID),
        ]
        for candidate in candidates {
            if let candidate, language.ownsLocalVoice(candidate) { return candidate }
        }
        return KokoroProvider.presetVoices(for: language).first?.id
    }

    public func setLocalVoiceID(_ voiceID: String, for language: SpeechLanguage) {
        defaults.set(voiceID, forKey: Key.localVoiceID(language))
    }

    /// Client-side playback rate, 0.5–3.0 (F-8).
    public var playbackRate: Double {
        get {
            let v = defaults.double(forKey: Key.playbackRate)
            return v == 0 ? 1.0 : min(max(v, 0.5), 3.0)
        }
        nonmutating set { defaults.set(min(max(newValue, 0.5), 3.0), forKey: Key.playbackRate) }
    }

    /// Inter-sentence pause in ms at 1.0× (scales inversely with rate, F-5).
    public var sentencePauseMS: Int {
        get {
            defaults.object(forKey: Key.sentencePauseMS) == nil
                ? 400 : defaults.integer(forKey: Key.sentencePauseMS)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.sentencePauseMS) }
    }

    /// ElevenLabs history auto-delete (P-6). ON by default.
    public var autoDeleteHistory: Bool {
        get {
            defaults.object(forKey: Key.autoDeleteHistory) == nil
                ? true : defaults.bool(forKey: Key.autoDeleteHistory)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.autoDeleteHistory) }
    }

    /// Audio cache toggle; off = "sensitive session" mode (P-10).
    public var cacheEnabled: Bool {
        get {
            defaults.object(forKey: Key.cacheEnabled) == nil
                ? true : defaults.bool(forKey: Key.cacheEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.cacheEnabled) }
    }

    /// Backend mode; `local` doubles as the Local-Only master switch (P-8).
    public var backendMode: BackendMode {
        get {
            BackendMode(rawValue: defaults.string(forKey: Key.backendMode) ?? "") ?? .auto
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.backendMode) }
    }

    // MARK: - Reader overlay

    /// Show the floating reader while sr is speaking. ON by default: seeing
    /// the words is the point of the feature, and the overlay only ever
    /// renders text that is already being read on this Mac.
    public var readerOverlayEnabled: Bool {
        get { bool(Key.readerOverlayEnabled, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.readerOverlayEnabled) }
    }

    /// Which of the three context lines the overlay shows. All three off is a
    /// legitimate choice — it leaves the transport, speed and language readout.
    public var readerShowsPreviousSentence: Bool {
        get { bool(Key.readerShowsPreviousSentence, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.readerShowsPreviousSentence) }
    }

    public var readerShowsCurrentSentence: Bool {
        get { bool(Key.readerShowsCurrentSentence, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.readerShowsCurrentSentence) }
    }

    public var readerShowsNextSentence: Bool {
        get { bool(Key.readerShowsNextSentence, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.readerShowsNextSentence) }
    }

    /// Where the user dragged the overlay, stored as the offset of its
    /// top-right corner from the top-right corner of the screen it is on —
    /// not as an absolute point. A relative offset keeps the window in the
    /// same visual spot when the selection is on a different display, or when
    /// the display's resolution changes, instead of stranding it off-screen.
    public var readerOverlayCornerOffset: (x: Double, y: Double) {
        get {
            guard defaults.object(forKey: Key.readerOverlayOffsetX) != nil,
                  defaults.object(forKey: Key.readerOverlayOffsetY) != nil else {
                return Self.defaultReaderOverlayOffset
            }
            return (defaults.double(forKey: Key.readerOverlayOffsetX),
                    defaults.double(forKey: Key.readerOverlayOffsetY))
        }
        nonmutating set {
            defaults.set(newValue.x, forKey: Key.readerOverlayOffsetX)
            defaults.set(newValue.y, forKey: Key.readerOverlayOffsetY)
        }
    }

    /// Top-right of the screen, inset by the standard window margin.
    /// Computed rather than stored: a stored tuple is not `Sendable`.
    public static var defaultReaderOverlayOffset: (x: Double, y: Double) { (-16, -16) }

    public func resetReaderOverlayPosition() {
        defaults.removeObject(forKey: Key.readerOverlayOffsetX)
        defaults.removeObject(forKey: Key.readerOverlayOffsetY)
    }

    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    public var voiceSettings: VoiceSettings {
        get {
            VoiceSettings(
                stability: defaults.object(forKey: Key.stability) == nil
                    ? 0.5 : defaults.double(forKey: Key.stability),
                similarityBoost: defaults.object(forKey: Key.similarityBoost) == nil
                    ? 0.75 : defaults.double(forKey: Key.similarityBoost),
                style: defaults.double(forKey: Key.style),
                useSpeakerBoost: defaults.object(forKey: Key.useSpeakerBoost) == nil
                    ? true : defaults.bool(forKey: Key.useSpeakerBoost)
            )
        }
        nonmutating set {
            defaults.set(newValue.stability, forKey: Key.stability)
            defaults.set(newValue.similarityBoost, forKey: Key.similarityBoost)
            defaults.set(newValue.style, forKey: Key.style)
            defaults.set(newValue.useSpeakerBoost, forKey: Key.useSpeakerBoost)
        }
    }
}
