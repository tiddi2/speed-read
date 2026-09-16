import Foundation

/// A passage to read aloud when recording a reference voice.
///
/// F5-TTS conditions on a recording *and* its transcript, and the two have to
/// agree word for word. Handing the reader a script instead of asking them to
/// transcribe what they said is what makes that agreement free: sr already
/// knows the text, so the usual failure — a transcript that drifts from the
/// recording and quietly degrades every read afterwards — cannot happen.
///
/// Each one is chosen to be about six to ten seconds at an unhurried pace and
/// to put the language's awkward sounds in the reader's mouth: for Norwegian
/// that means æ/ø/å, the *kj* and *skj* clusters, and enough vowel length
/// contrast that the clone has something to copy.
public struct ReferenceScript: Identifiable, Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }

    /// Roughly how long this takes to read aloud, for the recording timer.
    /// Norwegian read speech runs about 2.5 syllables a second unhurried;
    /// characters are a coarse but stable proxy at this length.
    public var estimatedSeconds: Double {
        max(4, Double(text.count) / 14.0)
    }

    public static let norwegian: [ReferenceScript] = [
        ReferenceScript(
            id: "no-weather",
            text: "Været i dag er kjølig og klart, med en frisk vind fra "
                + "nordøst. Jeg går en tur langs sjøen før kvelden kommer."),
        ReferenceScript(
            id: "no-market",
            text: "Han kjøpte åtte ferske brød og en pose epler på torget "
                + "i går ettermiddag, akkurat før butikkene stengte."),
        ReferenceScript(
            id: "no-reading",
            text: "Å lese høyt er en fin måte å øve på, særlig når teksten "
                + "er ny og ukjent for deg."),
    ]

    /// Scripts for `language`, empty when its offline voice needs no
    /// reference recording at all — Kokoro's speakers are baked into the
    /// model, so there is nothing for a reader to contribute.
    public static func scripts(for language: SpeechLanguage) -> [ReferenceScript] {
        switch language.localEngine {
        case .kokoro: return []
        case .f5: return norwegian
        }
    }
}
