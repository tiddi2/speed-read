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

    /// Kokoro voice-ID prefixes belonging to this language (the prefix is also
    /// the daemon's `lang_code`), empty when the local model cannot speak it.
    ///
    /// Kokoro-82M ships American (`a`) and British (`b`) English plus Spanish,
    /// French, Hindi, Italian, Japanese, Portuguese and Chinese — there is no
    /// Norwegian. Reading Norwegian text with an English voice would be exactly
    /// the language substitution this enum exists to prevent, so Norwegian is
    /// cloud-only (see `isSpeakableLocally`).
    public var kokoroVoicePrefixes: Set<String> {
        switch self {
        case .english: return ["a", "b"]
        case .norwegian: return []
        }
    }

    /// Whether the offline local voice can speak this language at all.
    public var isSpeakableLocally: Bool { !kokoroVoicePrefixes.isEmpty }

    /// Whether `voiceID` is a local voice for this language.
    public func ownsLocalVoice(_ voiceID: String) -> Bool {
        kokoroVoicePrefixes.contains(String(voiceID.prefix(1)))
    }
}
