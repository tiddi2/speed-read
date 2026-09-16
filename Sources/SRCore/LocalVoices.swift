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

    /// Plain-English reason an offline read failed, or nil when `error` did
    /// not come from a local engine.
    ///
    /// Worth having in one place: a local failure has no network and no
    /// account behind it, so the generic "could not reach the service" and
    /// bare "HTTP 500" that suit a cloud provider are actively misleading
    /// here — they send someone looking at their wifi for a missing file on
    /// their own disk. Every engine error the daemon raises is a fixed string
    /// it authored, so the tail can be shown as-is when it is not one of the
    /// cases named below.
    public static func failureMessage(for error: TTSError) -> String? {
        let detail: String
        switch error {
        case .network(let underlying): detail = underlying
        case .http(500, let body): detail = body ?? ""
        default: return nil
        }
        guard let reason = localReason(detail) else { return nil }

        switch reason {
        // Setup, in the order someone would fix them.
        case "local TTS not installed", "Norwegian voice not installed",
             "f5 engine not installed", "engine not installed":
            return "The offline voice is not installed — install it in Settings → General."
        case "quit and reopen sr to finish enabling the Norwegian voice",
             "incompatible daemon":
            return "The offline voice needs a restart — quit every sr window, then reopen sr."
        case "voice is missing its reference recording",
             "reference voice missing":
            return "That voice has lost its recording — record it again in Settings → Voices."
        case "reference recording is too short":
            return "The voice's recording is too short to read with — record a longer one in Settings → Voices."
        case "reference recording is not 24 kHz",
             "reference recording has no transcript",
             "reference recording could not be read",
             "voice files escape the voices root":
            return "That voice's files are damaged — record it again in Settings → Voices."
        case "language not installed":
            return "The offline voice cannot speak that language — switch to Cloud or Auto."
        case "f5 vocabulary is empty", "verified model path missing",
             "the Norwegian model files are missing or damaged",
             "the mel vocoder is missing or damaged":
            return "The offline model files are damaged — reinstall the voice in Settings → General."
        case "checkpoint does not fit the F5 architecture":
            return "The Norwegian model did not load — switch the F5 variant in Settings → Voices, or reinstall it in Settings → General."

        // Transport and generation. Nothing the user can act on directly, so
        // these name the log rather than pretending to offer a fix.
        case "daemon unavailable", "socket I/O failed":
            return "The offline voice stopped responding. Quit and reopen sr; if it keeps happening, see \(logHint)."
        default:
            // Out of memory carries the phase it ran out in, so it cannot be
            // a case above — but it is as actionable as any of them.
            if reason.hasPrefix("ran out of memory") {
                return "The offline voice ran out of memory — close some apps, or read a shorter selection."
            }
            // Everything else at least says which phase it died in
            // ("RuntimeError while generating Norwegian speech"). Lead with
            // that rather than burying it behind boilerplate: the first line
            // is all a menu row is guaranteed to show.
            return "Offline synthesis failed: \(reason). See \(logHint)."
        }
    }

    /// Where the daemon writes what went wrong. Named in the messages above
    /// because for a local engine it is the only other record there is.
    public static let logHint = "~/Library/Logs/sr/kokoro.log"

    /// The engine-tagged tail of a local error, or nil if not one of ours.
    private static func localReason(_ detail: String) -> String? {
        for prefix in ["f5: ", "kokoro: "] where detail.hasPrefix(prefix) {
            return String(detail.dropFirst(prefix.count))
        }
        return nil
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
