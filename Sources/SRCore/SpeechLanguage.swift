import Foundation

/// The language a read is spoken in.
///
/// Normalization injects spoken words into the text handed to the TTS
/// provider ("50 %" → "50 percent"), so those words have to follow the
/// read's language rather than being fixed to English — see
/// `NormalizerLexicon`.
///
/// Raw values are BCP-47 language subtags, so they double as the stored
/// preference and as the `--language` CLI argument.
public enum SpeechLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case norwegian = "nb"

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .norwegian: return "Norwegian"
        }
    }
}
