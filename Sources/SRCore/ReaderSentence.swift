import Foundation

/// A sentence as the reader overlay shows it: the words a listener hears,
/// each with the slice of the sentence's speaking time it is estimated to
/// occupy.
///
/// **Why estimated.** Neither backend hands sr word timings. The cloud
/// endpoint sr calls returns audio only, the local daemon returns audio only,
/// and a cache hit returns audio generated days ago. So the word cursor is
/// derived from playback position *inside the current sentence*: every word
/// gets a weight — a fixed cost for saying it at all, a cost per character,
/// and the pause its trailing punctuation buys — and the weights are
/// normalized into a 0…1 span.
///
/// **Why the error stays small.** PlaybackEngine reports progress within the
/// current sentence, so the estimate is re-anchored at every sentence
/// boundary. Drift cannot accumulate across a read: the worst case is landing
/// a word early or late inside one sentence, never paragraphs away. The
/// sentence-level cue (the current sentence is the one rendered in full
/// contrast) is exact regardless.
public struct ReaderSentence: Sendable, Equatable {
    /// One spoken word plus where it sits in the sentence, in Characters, and
    /// when it is spoken, as a fraction of the sentence.
    public struct Word: Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
        /// Character offset of `text` within `ReaderSentence.text`.
        public let offset: Int
        /// Start of this word's span within the sentence, 0…1.
        public let start: Double
        /// End of this word's span within the sentence, 0…1.
        public let end: Double

        public init(id: Int, text: String, offset: Int, start: Double, end: Double) {
            self.id = id
            self.text = text
            self.offset = offset
            self.start = start
            self.end = end
        }

        public var length: Int { text.count }
    }

    public let text: String
    public let words: [Word]

    public static let empty = ReaderSentence(text: "", words: [])

    public init(text: String, words: [Word]) {
        self.text = text
        self.words = words
    }

    // MARK: - Weights
    //
    // Speech duration for a word is roughly affine in its length: a fixed cost
    // for producing it at all, plus a per-character cost. Punctuation adds the
    // pause that follows it — a comma is worth about three characters of
    // silence, a full stop rather less in mid-sentence use (abbreviations,
    // ellipses) but it also covers the decay at the end of a sentence.

    /// Cost of saying a word at all, in character-equivalents.
    static let wordOverhead = 1.5
    /// Cost of one spoken character.
    static let characterCost = 1.0

    static func pauseCost(after word: some StringProtocol) -> Double {
        guard let last = word.last else { return 0 }
        switch last {
        case ",", ";", ":", "—", "–": return 3.0
        case ".", "!", "?", "…": return 2.0
        default: return 0
        }
    }

    static func weight(of word: some StringProtocol) -> Double {
        // Punctuation is silent — it buys a pause, it is not itself spoken —
        // so it feeds `pauseCost` rather than the per-character cost.
        let spoken = word.reduce(into: 0) { count, character in
            if character.isLetter || character.isNumber { count += 1 }
        }
        return wordOverhead + characterCost * Double(spoken) + pauseCost(after: word)
    }

    // MARK: - Parsing

    /// Split `text` on whitespace and assign each word its span.
    ///
    /// `text` is the *normalized* sentence — the exact string that was sent to
    /// the synthesizer — so what the overlay highlights is always what is
    /// being said, not the raw source with its LaTeX, hyphenation and PDF line
    /// breaks still in it.
    public static func parse(_ text: String) -> ReaderSentence {
        var pieces: [(text: String, offset: Int)] = []
        var current = ""
        var currentOffset = 0
        for (offset, character) in text.enumerated() {
            if character.isWhitespace {
                if !current.isEmpty {
                    pieces.append((current, currentOffset))
                    current = ""
                }
            } else {
                if current.isEmpty { currentOffset = offset }
                current.append(character)
            }
        }
        if !current.isEmpty { pieces.append((current, currentOffset)) }
        guard !pieces.isEmpty else { return ReaderSentence(text: text, words: []) }

        let weights = pieces.map { weight(of: $0.text) }
        let total = weights.reduce(0, +)
        var words: [Word] = []
        words.reserveCapacity(pieces.count)
        var cursor = 0.0
        for (index, piece) in pieces.enumerated() {
            let start = min(cursor, 1.0)
            // `total` is always > 0 (wordOverhead alone guarantees it), but an
            // equal split is the right degenerate answer if that ever changes.
            cursor += total > 0 ? weights[index] / total : 1.0 / Double(pieces.count)
            let isLast = index == pieces.count - 1
            words.append(Word(id: index,
                              text: piece.text,
                              offset: piece.offset,
                              start: start,
                              end: isLast ? 1.0 : min(cursor, 1.0)))
        }
        return ReaderSentence(text: text, words: words)
    }

    // MARK: - Lookup

    /// The word being spoken at `progress` (0…1 through this sentence), or nil
    /// when the sentence has no words. Out-of-range progress clamps, so a
    /// position inside the inter-sentence pause highlights the first word
    /// rather than nothing.
    public func index(atProgress progress: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        let clamped = min(max(progress, 0), 1)
        for word in words where clamped < word.end { return word.id }
        return words.count - 1
    }

    public func word(atProgress progress: Double) -> Word? {
        index(atProgress: progress).map { words[$0] }
    }
}
