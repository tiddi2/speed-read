import Foundation
import Testing
@testable import SRCore

@Suite struct PronunciationTests {
    private func makeStore() -> PronunciationStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-pronunciation-tests/\(UUID().uuidString)",
                                    isDirectory: true)
        let defaults = UserDefaults(suiteName: "sr.tests.\(UUID().uuidString)")!
        return PronunciationStore(
            fileURL: directory.appendingPathComponent("pronunciations.json"),
            defaults: defaults)
    }

    private func alias(_ from: String, _ to: String,
                       matchCase: Bool = false) -> PronunciationRule {
        PronunciationRule(stringToReplace: from, kind: .alias, alias: to,
                          matchCase: matchCase)
    }

    // MARK: - Alias rewriting

    @Test func respellsWholeWordsOnly() {
        let rules = [alias("ion", "eye on")]
        #expect(PronunciationStore.applyAliases(to: "an ion", rules: rules) == "an eye on")
        // The substring inside another word is not a match.
        #expect(PronunciationStore.applyAliases(to: "a station", rules: rules) == "a station")
    }

    @Test func matchesCaseInsensitivelyUnlessAsked() {
        #expect(PronunciationStore.applyAliases(
            to: "NATO and nato", rules: [alias("nato", "nay toe")])
            == "nay toe and nay toe")
        #expect(PronunciationStore.applyAliases(
            to: "US and us", rules: [alias("US", "you ess", matchCase: true)])
            == "you ess and us")
    }

    /// "New York City" must win over "New York", or the longer entry could
    /// never fire.
    @Test func longerPhrasesWinOverShorterOnes() {
        let rules = [alias("New York", "Noo York"),
                     alias("New York City", "the Big Apple")]
        #expect(PronunciationStore.applyAliases(to: "New York City", rules: rules)
            == "the Big Apple")
    }

    /// Entries are a dictionary, not a rewrite pipeline: one entry's output
    /// must never be fed to the next.
    @Test func rulesDoNotCascade() {
        #expect(PronunciationStore.applyAliases(
            to: "a b", rules: [alias("a", "b"), alias("b", "c")]) == "b c")
    }

    @Test func nonWordEdgesStillMatch() {
        #expect(PronunciationStore.applyAliases(
            to: "written in C++ today", rules: [alias("C++", "see plus plus")])
            == "written in see plus plus today")
    }

    /// A replacement containing regex-template syntax is literal text, not a
    /// capture-group reference.
    @Test func replacementIsLiteralText() {
        #expect(PronunciationStore.applyAliases(
            to: "the cost", rules: [alias("cost", "$1 dollars")])
            == "the $1 dollars")
    }

    @Test func incompleteOrDisabledRulesDoNothing() {
        var disabled = alias("hei", "hay")
        disabled.isEnabled = false
        #expect(PronunciationStore.applyAliases(to: "hei", rules: [disabled]) == "hei")
        #expect(PronunciationStore.applyAliases(
            to: "hei", rules: [alias("hei", "   ")]) == "hei")
        #expect(PronunciationStore.applyAliases(
            to: "hei", rules: [alias("", "hay")]) == "hei")
    }

    @Test func norwegianLettersAreWordCharacters() {
        #expect(PronunciationStore.applyAliases(
            to: "en ål i vann", rules: [alias("ål", "awl")]) == "en awl i vann")
        #expect(PronunciationStore.applyAliases(
            to: "målet", rules: [alias("ål", "awl")]) == "målet")
    }

    // MARK: - Inline markup (used by the editor's audition buttons)

    @Test func phonemeRuleBecomesInlineMarkup() {
        let rule = PronunciationRule(stringToReplace: "Nguyen", kind: .phoneme,
                                     phoneme: "ŋwɪn", alphabet: .ipa)
        #expect(PronunciationStore.applyInline(rule, to: "Hello Nguyen.")
            == "Hello <phoneme alphabet=\"ipa\" ph=\"ŋwɪn\">Nguyen</phoneme>.")
    }

    @Test func inlineMarkupEscapesItsPayload() {
        let rule = PronunciationRule(stringToReplace: "AT&T", kind: .phoneme,
                                     phoneme: "eɪ \"ti\"", alphabet: .ipa)
        let output = PronunciationStore.applyInline(rule, to: "call AT&T now")
        #expect(output.contains("ph=\"eɪ &quot;ti&quot;\""))
        #expect(output.contains(">AT&amp;T</phoneme>"))
    }

    @Test func inlineMarkupOfAnAliasIsJustTheRespelling() {
        #expect(PronunciationStore.applyInline(alias("sr", "ess arr"), to: "open sr")
            == "open ess arr")
    }

    // MARK: - Per-language storage

    @Test func rulesArePerLanguageAndSurviveAReload() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sr-pronunciation-tests/\(UUID().uuidString)",
                                    isDirectory: true)
        let fileURL = directory.appendingPathComponent("pronunciations.json")
        let suite = "sr.tests.\(UUID().uuidString)"
        let first = PronunciationStore(fileURL: fileURL,
                                       defaults: UserDefaults(suiteName: suite)!)
        first.setRules([alias("Anne", "Ann")], for: .english)
        first.setRules([alias("Anne", "Ah-neh")], for: .norwegian)

        let reloaded = PronunciationStore(fileURL: fileURL,
                                          defaults: UserDefaults(suiteName: suite)!)
        #expect(reloaded.rules(for: .english).first?.alias == "Ann")
        #expect(reloaded.rules(for: .norwegian).first?.alias == "Ah-neh")
        #expect(reloaded.applyAliases(to: "Anne", language: .english) == "Ann")
        #expect(reloaded.applyAliases(to: "Anne", language: .norwegian) == "Ah-neh")
    }

    // MARK: - Dictionary locators

    /// The locator is only usable while it still describes the rules that are
    /// configured; otherwise an edited phoneme would be read with the
    /// previous dictionary.
    @Test func editingAPhonemeRuleInvalidatesTheStoredLocator() {
        let store = makeStore()
        var rule = PronunciationRule(stringToReplace: "Nguyen", kind: .phoneme,
                                     phoneme: "ŋwɪn", alphabet: .ipa)
        store.setRules([rule], for: .english)
        let fingerprint = store.phonemeFingerprint(for: .english)
        #expect(!fingerprint.isEmpty)
        #expect(store.needsPhonemeSync(for: .english))

        store.storeLocator(
            PronunciationDictionaryLocator(dictionaryID: "d1", versionID: "v1"),
            fingerprint: fingerprint, for: .english)
        #expect(store.locator(for: .english)?.versionID == "v1")
        #expect(!store.needsPhonemeSync(for: .english))

        rule.phoneme = "nujən"
        store.setRules([rule], for: .english)
        #expect(store.locator(for: .english) == nil)
        #expect(store.needsPhonemeSync(for: .english))
    }

    /// Respellings never need a dictionary — they are applied on this Mac —
    /// so a book of only respellings must not trigger an upload.
    @Test func respellingsNeverNeedAnUpload() {
        let store = makeStore()
        store.setRules([alias("sr", "ess arr")], for: .english)
        #expect(store.phonemeFingerprint(for: .english).isEmpty)
        #expect(!store.needsPhonemeSync(for: .english))
        #expect(store.locator(for: .english) == nil)
    }

    // MARK: - Cache keying

    /// Two dictionary versions are two different recordings of the same
    /// sentence; sharing a cache entry would replay the old pronunciation.
    @Test func cacheKeySeparatesDictionaryVersions() {
        let none = AudioCache.key(text: "Nguyen", provider: "elevenlabs",
                                  voiceID: "v", modelID: "m", languageCode: "en",
                                  settings: VoiceSettings())
        let first = AudioCache.key(text: "Nguyen", provider: "elevenlabs",
                                   voiceID: "v", modelID: "m", languageCode: "en",
                                   variant: "ver1", settings: VoiceSettings())
        let second = AudioCache.key(text: "Nguyen", provider: "elevenlabs",
                                    voiceID: "v", modelID: "m", languageCode: "en",
                                    variant: "ver2", settings: VoiceSettings())
        #expect(none != first)
        #expect(first != second)
        // An empty variant hashes exactly as it did before variants existed,
        // so audio cached by an older build is still a hit.
        #expect(none == AudioCache.key(text: "Nguyen", provider: "elevenlabs",
                                       voiceID: "v", modelID: "m",
                                       languageCode: "en", variant: "",
                                       settings: VoiceSettings()))
    }

    // MARK: - Model capability

    /// Phoneme rules are silently ignored by most models, including the two
    /// sr language-locks with — Settings warns about exactly this set.
    @Test func phonemeSupportIsNarrowerThanLanguageLock() {
        #expect(ElevenLabsProvider.supportsPhonemeRules("eleven_v3"))
        #expect(!ElevenLabsProvider.supportsPhonemeRules("eleven_flash_v2_5"))
        #expect(!ElevenLabsProvider.supportsPhonemeRules("eleven_turbo_v2_5"))
        #expect(!ElevenLabsProvider.supportsPhonemeRules("eleven_multilingual_v2"))
    }

    /// A locator handed to a model that cannot act on it is dropped rather
    /// than sent, so the cache key never claims a dictionary was applied.
    @Test func locatorIsDroppedForModelsThatIgnoreIt() {
        let locator = PronunciationDictionaryLocator(dictionaryID: "d", versionID: "v")
        #expect(ElevenLabsProvider(modelID: "eleven_v3", language: .english,
                                   pronunciationLocator: locator)
            .pronunciationLocators.count == 1)
        #expect(ElevenLabsProvider(modelID: "eleven_flash_v2_5", language: .english,
                                   pronunciationLocator: locator)
            .pronunciationLocators.isEmpty)
    }
}
