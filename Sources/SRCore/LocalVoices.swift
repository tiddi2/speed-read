import Foundation

/// One place to ask "what can this language do offline?".
///
/// Two offline engines with different shapes — Kokoro's fixed voice list and
/// F5's user-supplied reference recordings — would otherwise leak `if
/// language == .norwegian` into routing, settings, the CLI and the voice
/// picker alike. Everything above SRCore asks here instead, and adding a
/// third engine means adding a case in this file.
public enum LocalVoices {
    /// Is this language's offline model downloaded and verified?
    public static func isInstalled(for language: SpeechLanguage) -> Bool {
        switch language.localEngine {
        case .kokoro: return KokoroRuntime.shared.isInstalled
        case .f5: return F5Runtime.shared.isInstalled
        }
    }

    /// Provider for an offline read in `language`.
    public static func provider(for language: SpeechLanguage) -> any TTSProvider {
        switch language.localEngine {
        case .kokoro: return KokoroProvider(language: language)
        case .f5: return F5Provider(language: language)
        }
    }

    /// Cache namespace for this language's offline audio.
    public static func cacheModelID(for language: SpeechLanguage) -> String {
        switch language.localEngine {
        case .kokoro: return KokoroProvider.cacheModelID
        case .f5: return F5Provider.cacheModelID
        }
    }

    /// The offline voices to choose from.
    public static func available(for language: SpeechLanguage) -> [Voice] {
        switch language.localEngine {
        case .kokoro: return KokoroProvider.presetVoices(for: language)
        case .f5: return F5Runtime.shared.voices.voices().map(\.asVoice)
        }
    }

    /// Whether `voiceID` is a voice this language can actually read with.
    public static func owns(voiceID: String, language: SpeechLanguage) -> Bool {
        switch language.localEngine {
        case .kokoro: return language.ownsLocalVoice(voiceID)
        case .f5: return F5Runtime.shared.voices.voice(id: voiceID) != nil
        }
    }

    /// What to fall back to when nothing is chosen, or the choice is gone.
    public static func defaultVoiceID(for language: SpeechLanguage) -> String? {
        available(for: language).first?.id
    }

    /// Anything beyond voice and model that changes the audio, for the cache
    /// key. Kokoro has none. F5's output depends on the reference recording
    /// behind the voice id and on which architecture the checkpoint is loaded
    /// with, and neither is visible in the voice id alone.
    public static func cacheVariant(for language: SpeechLanguage,
                                    voiceID: String,
                                    settings: SettingsStore = SettingsStore()) -> String {
        switch language.localEngine {
        case .kokoro:
            return ""
        case .f5:
            let runtime = F5Runtime.shared
            let fingerprint = runtime.voices.voice(id: voiceID)?.fingerprint ?? ""
            return "\(runtime.variant(settings: settings).rawValue):\(fingerprint)"
        }
    }

    /// Why an offline read is not possible right now, phrased for the user.
    public static func unavailableMessage(for language: SpeechLanguage) -> String {
        switch language.localEngine {
        case .kokoro:
            return "Local voice not installed — install it in Settings → General."
        case .f5:
            guard isInstalled(for: language) else {
                return "Norwegian offline voice not installed — install it in Settings → General."
            }
            return "The Norwegian offline voice has no reference recording yet — add one in Settings → Voices."
        }
    }
}
