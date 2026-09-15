import Foundation

/// The languages sr will read, and nothing else.
///
/// sr never auto-detects the language of a selection. Every read is started
/// through a language-scoped entry point (a per-language hotkey, a per-language
/// clipboard button, or `--lang` on the CLI), and that language is pinned on
/// the provider request. A selection in a third language is spoken with the
/// chosen language's voice and pronunciation rules rather than silently
/// switching languages.
public enum SpeechLanguage: String, CaseIterable, Sendable, Identifiable, Codable {
    case english = "en"
    case norwegian = "no"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .norwegian: return "Norwegian"
        }
    }

    /// ISO 639-1 code sent as ElevenLabs `language_code`, which pins both the
    /// model and its text normalization to this language.
    public var elevenLabsLanguageCode: String { rawValue }

    /// Which offline model speaks this language.
    ///
    /// Kokoro-82M ships American (`a`) and British (`b`) English plus Spanish,
    /// French, Hindi, Italian, Japanese, Portuguese and Chinese — but no
    /// Norwegian, and reading Norwegian text with an English voice is exactly
    /// the language substitution this enum exists to prevent. So Norwegian has
    /// its own offline model, an F5-TTS checkpoint trained on Norwegian, and
    /// the two are installed separately.
    public var localEngine: LocalVoiceEngine {
        switch self {
        case .english: return .kokoro
        case .norwegian: return .f5
        }
    }

    /// Kokoro voice-ID prefixes belonging to this language (the prefix is also
    /// the daemon's `lang_code`), empty when Kokoro cannot speak it.
    public var kokoroVoicePrefixes: Set<String> {
        switch self {
        case .english: return ["a", "b"]
        case .norwegian: return []
        }
    }

    /// Whether `voiceID` is a Kokoro voice for this language. Every language
    /// has an offline engine now, so "can this be read offline at all?" is
    /// `LocalVoices.isInstalled(for:)` instead.
    public func ownsLocalVoice(_ voiceID: String) -> Bool {
        kokoroVoicePrefixes.contains(String(voiceID.prefix(1)))
    }
}

/// The offline synthesis engines sr ships. Both run in the same supervised
/// daemon; each is downloaded on its own.
public enum LocalVoiceEngine: String, Sendable, Codable, CaseIterable {
    /// Kokoro-82M via mlx-audio. Fixed set of baked-in voices.
    case kokoro
    /// An F5-TTS checkpoint via f5-tts-mlx. Zero-shot, so its voices are
    /// reference recordings the user supplies.
    case f5

    public var displayName: String {
        switch self {
        case .kokoro: return "Kokoro"
        case .f5: return "F5-TTS"
        }
    }
}
