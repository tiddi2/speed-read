import Foundation
import Testing
@testable import SRCore

@Suite struct ReaderSentenceTests {
    @Test func splitsOnWhitespaceAndKeepsOffsets() {
        let text = "Alpha beta  gamma"
        let sentence = ReaderSentence.parse(text)
        #expect(sentence.words.map(\.text) == ["Alpha", "beta", "gamma"])
        for word in sentence.words {
            let start = text.index(text.startIndex, offsetBy: word.offset)
            let end = text.index(start, offsetBy: word.length)
            #expect(String(text[start..<end]) == word.text)
        }
    }

    @Test func spansCoverTheWholeSentenceInOrder() {
        let sentence = ReaderSentence.parse("One two three four five six seven.")
        #expect(sentence.words.first?.start == 0)
        #expect(sentence.words.last?.end == 1)
        for (previous, next) in zip(sentence.words, sentence.words.dropFirst()) {
            #expect(previous.end <= next.start + 0.000_001)
            #expect(previous.start < previous.end)
        }
    }

    /// The cursor must advance monotonically and reach every word — a word
    /// that no progress value ever selects would simply never light up.
    @Test func everyWordIsReachableAndTheCursorNeverGoesBackwards() {
        let sentence = ReaderSentence.parse(
            "The quick brown fox jumps over the lazy dog, twice.")
        var seen: Set<Int> = []
        var last = -1
        for step in 0...1_000 {
            guard let index = sentence.index(atProgress: Double(step) / 1_000) else {
                Issue.record("no word at step \(step)")
                return
            }
            #expect(index >= last)
            last = index
            seen.insert(index)
        }
        #expect(seen.count == sentence.words.count)
    }

    @Test func progressOutsideZeroToOneClamps() {
        let sentence = ReaderSentence.parse("First second third.")
        #expect(sentence.index(atProgress: -5) == 0)
        #expect(sentence.index(atProgress: 5) == sentence.words.count - 1)
        // Playback sits in the inter-sentence pause at negative progress; the
        // opening word is the honest thing to show there.
        #expect(sentence.word(atProgress: 0)?.text == "First")
    }

    @Test func longerWordsHoldTheCursorLonger() {
        let sentence = ReaderSentence.parse("I extraordinarily go")
        let spans = sentence.words.map { $0.end - $0.start }
        #expect(spans[1] > spans[0])
        #expect(spans[1] > spans[2])
    }

    /// A comma buys a pause, so the word before it keeps the cursor longer
    /// than the same word without one.
    @Test func trailingPunctuationAddsPause() {
        let withComma = ReaderSentence.parse("alpha, alpha alpha")
        let without = ReaderSentence.parse("alpha alpha alpha")
        #expect(withComma.words[0].end > without.words[0].end)
    }

    @Test func emptyAndWhitespaceOnlySentences() {
        #expect(ReaderSentence.parse("").words.isEmpty)
        #expect(ReaderSentence.parse("   \n ").words.isEmpty)
        #expect(ReaderSentence.parse("").index(atProgress: 0.5) == nil)
        #expect(ReaderSentence.empty.words.isEmpty)
    }

    @Test func singleWordCoversTheWholeSentence() {
        let sentence = ReaderSentence.parse("Hello")
        #expect(sentence.words.count == 1)
        #expect(sentence.words[0].start == 0)
        #expect(sentence.words[0].end == 1)
        #expect(sentence.index(atProgress: 0.5) == 0)
    }

    /// Offsets are Character offsets, so they must survive text the source app
    /// can perfectly well hand us: accents, emoji, non-Latin scripts.
    @Test func offsetsAreCharacterOffsets() {
        let text = "Blåbær 🇳🇴 spises på fjellet"
        let sentence = ReaderSentence.parse(text)
        #expect(sentence.words.count == 5)
        for word in sentence.words {
            let start = text.index(text.startIndex, offsetBy: word.offset)
            let end = text.index(start, offsetBy: word.length)
            #expect(String(text[start..<end]) == word.text)
        }
        #expect(sentence.words.last?.end == 1)
    }
}

@Suite struct ReaderOverlaySettingsTests {
    private func store(_ seed: [String: Any] = [:]) -> SettingsStore {
        let defaults = UserDefaults(suiteName: "sr.tests.\(UUID().uuidString)")!
        for (key, value) in seed { defaults.set(value, forKey: key) }
        return SettingsStore(defaults: defaults)
    }

    /// Seeing the words is the point of the overlay, so a fresh install gets
    /// all three context lines rather than an empty frame to configure.
    @Test func defaultsToFullyVisible() {
        let settings = store()
        #expect(settings.readerOverlayEnabled)
        #expect(settings.readerShowsPreviousSentence)
        #expect(settings.readerShowsCurrentSentence)
        #expect(settings.readerShowsNextSentence)
    }

    @Test func eachSentenceLineTogglesIndependently() {
        let settings = store()
        settings.readerShowsPreviousSentence = false
        settings.readerShowsNextSentence = false
        #expect(!settings.readerShowsPreviousSentence)
        #expect(settings.readerShowsCurrentSentence)
        #expect(!settings.readerShowsNextSentence)
        #expect(settings.readerOverlayEnabled)
    }

    /// `false` must survive the round trip: a plain `bool(forKey:)` on an
    /// unset key is also false, so the store has to distinguish "off" from
    /// "never touched" or every one of these would default to off.
    @Test func explicitOffIsNotMistakenForUnset() {
        let settings = store()
        settings.readerOverlayEnabled = false
        settings.readerShowsCurrentSentence = false
        #expect(!settings.readerOverlayEnabled)
        #expect(!settings.readerShowsCurrentSentence)
    }

    @Test func positionIsStoredRelativeToTheScreenCornerAndResettable() {
        let settings = store()
        #expect(settings.readerOverlayCornerOffset.x == SettingsStore.defaultReaderOverlayOffset.x)
        settings.readerOverlayCornerOffset = (x: -120, y: -300)
        #expect(settings.readerOverlayCornerOffset.x == -120)
        #expect(settings.readerOverlayCornerOffset.y == -300)
        settings.resetReaderOverlayPosition()
        #expect(settings.readerOverlayCornerOffset.x == SettingsStore.defaultReaderOverlayOffset.x)
        #expect(settings.readerOverlayCornerOffset.y == SettingsStore.defaultReaderOverlayOffset.y)
    }

    /// A stored (0, 0) is a real position — the overlay flush to the top-right
    /// corner — and must not read back as "unset".
    @Test func zeroOffsetIsARealPosition() {
        let settings = store()
        settings.readerOverlayCornerOffset = (x: 0, y: 0)
        #expect(settings.readerOverlayCornerOffset.x == 0)
        #expect(settings.readerOverlayCornerOffset.y == 0)
    }
}
