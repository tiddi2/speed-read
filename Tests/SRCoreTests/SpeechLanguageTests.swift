import Foundation
import Testing
@testable import SRCore

@Suite struct SpeechLanguageTests {
    /// Each language has exactly one offline engine, and Kokoro is not
    /// Norwegian's — reading Norwegian with an English voice is the
    /// substitution this whole type exists to prevent.
    @Test func eachLanguageHasItsOwnOfflineEngine() {
        #expect(SpeechLanguage.english.localEngine == .kokoro)
        #expect(SpeechLanguage.norwegian.localEngine == .f5)
        #expect(KokoroProvider.presetVoices(for: .norwegian).isEmpty)
        #expect(!KokoroProvider.presetVoices(for: .english).isEmpty)
    }

    @Test func englishOwnsBothKokoroAccents() {
        #expect(SpeechLanguage.english.ownsLocalVoice("af_heart"))
        #expect(SpeechLanguage.english.ownsLocalVoice("bf_lily"))
        #expect(!SpeechLanguage.norwegian.ownsLocalVoice("af_heart"))
        // Kokoro's other locales are not English either.
        #expect(!SpeechLanguage.english.ownsLocalVoice("jf_alpha"))
    }

    /// `language_code` is only accepted by the v2.5 models; sending it to the
    /// others is an API error, so it must be dropped rather than sent.
    @Test func languageLockOnlyOnModelsThatAcceptIt() {
        #expect(ElevenLabsProvider.supportsLanguageLock("eleven_flash_v2_5"))
        #expect(ElevenLabsProvider.supportsLanguageLock("eleven_turbo_v2_5"))
        #expect(!ElevenLabsProvider.supportsLanguageLock("eleven_multilingual_v2"))
        #expect(!ElevenLabsProvider.supportsLanguageLock("eleven_v3"))

        #expect(ElevenLabsProvider.lockedLanguageCode(
            for: .norwegian, modelID: "eleven_flash_v2_5") == "no")
        #expect(ElevenLabsProvider.lockedLanguageCode(
            for: .english, modelID: "eleven_turbo_v2_5") == "en")
        #expect(ElevenLabsProvider.lockedLanguageCode(
            for: .norwegian, modelID: "eleven_v3") == nil)
        #expect(ElevenLabsProvider.lockedLanguageCode(
            for: nil, modelID: "eleven_flash_v2_5") == nil)
    }

    @Test func providerDropsAnUnsupportedLanguageInsteadOfSendingIt() {
        #expect(ElevenLabsProvider(modelID: "eleven_flash_v2_5", language: .norwegian)
            .languageCode == "no")
        #expect(ElevenLabsProvider(modelID: "eleven_multilingual_v2", language: .norwegian)
            .languageCode == nil)
        #expect(ElevenLabsProvider(modelID: "eleven_flash_v2_5").languageCode == nil)
    }

    /// Kokoro must refuse a voice from another language rather than read the
    /// text with it.
    @Test func kokoroRefusesAVoiceFromAnotherLanguage() async {
        do {
            _ = try await KokoroProvider(language: .norwegian)
                .synthesize(text: "hei", voiceID: "af_heart", settings: VoiceSettings())
            Issue.record("Kokoro spoke Norwegian with an English voice")
        } catch let error as TTSError {
            guard case .network(let detail) = error else {
                Issue.record("unexpected TTSError: \(error)")
                return
            }
            #expect(detail == "kokoro: language not installed")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite struct LanguageSettingsTests {
    /// A throwaway defaults domain per test, so profiles never leak between
    /// cases or into the developer's own preferences.
    private func store(_ seed: [String: Any] = [:]) -> SettingsStore {
        let defaults = UserDefaults(suiteName: "sr.tests.\(UUID().uuidString)")!
        for (key, value) in seed { defaults.set(value, forKey: key) }
        return SettingsStore(defaults: defaults)
    }

    @Test func languagesKeepIndependentVoices() {
        let settings = store()
        settings.setVoiceID("voice-no", for: .norwegian)
        settings.setVoiceID("voice-en", for: .english)
        #expect(settings.voiceID(for: .norwegian) == "voice-no")
        #expect(settings.voiceID(for: .english) == "voice-en")
    }

    /// An existing pre-profile voice choice is inherited, not reset.
    @Test func inheritsTheLegacyVoice() {
        let settings = store(["voiceID": "legacy-voice"])
        #expect(settings.voiceID(for: .english) == "legacy-voice")
        #expect(settings.voiceID(for: .norwegian) == "legacy-voice")
        settings.setVoiceID("chosen", for: .norwegian)
        #expect(settings.voiceID(for: .norwegian) == "chosen")
        #expect(settings.voiceID(for: .english) == "legacy-voice")
    }

    /// A model that cannot be pinned to a language must not be inherited as a
    /// default — that would silently reintroduce language detection.
    @Test func doesNotInheritAModelThatCannotLockTheLanguage() {
        let locked = store(["modelID": "eleven_turbo_v2_5"])
        #expect(locked.modelID(for: .norwegian) == "eleven_turbo_v2_5")

        let unlocked = store(["modelID": "eleven_v3"])
        #expect(unlocked.modelID(for: .norwegian) == ElevenLabsProvider.defaultModelID)
        #expect(ElevenLabsProvider.supportsLanguageLock(unlocked.modelID(for: .english)))

        // An explicit per-language choice is still honoured, warning and all.
        unlocked.setModelID("eleven_v3", for: .norwegian)
        #expect(unlocked.modelID(for: .norwegian) == "eleven_v3")
    }

    /// Asserted as "not that voice" rather than "nil": Norwegian does have an
    /// offline engine now, so on a machine with a reference recording
    /// installed the fallback is that recording — never the English voice.
    @Test func localVoiceIsNeverBorrowedFromAnotherLanguage() {
        let settings = store(["localVoiceID": "af_heart"])
        #expect(settings.localVoiceID(for: .english) == "af_heart")
        #expect(settings.localVoiceID(for: .norwegian) != "af_heart")

        // A stored value that does not belong to the language is ignored.
        settings.setLocalVoiceID("af_heart", for: .norwegian)
        #expect(settings.localVoiceID(for: .norwegian) != "af_heart")
    }
}
