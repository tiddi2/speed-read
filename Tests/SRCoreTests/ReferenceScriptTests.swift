import Testing
@testable import SRCore

// No Foundation import: this file imports Testing, and the CLT toolchain has
// no _Testing_Foundation overlay (see KokoroTestSupport for the long version).
// Everything here is plain stdlib string work.
@Suite struct ReferenceScriptTests {
    /// Only F5 conditions on a recording. Kokoro's speakers are baked into
    /// the model, so offering an English reader a script would be asking for
    /// something sr has no use for.
    @Test func onlyTheEngineThatNeedsAReferenceOffersScripts() {
        #expect(ReferenceScript.scripts(for: .english).isEmpty)
        #expect(!ReferenceScript.scripts(for: .norwegian).isEmpty)
    }

    @Test func scriptsAreDistinct() {
        let scripts = ReferenceScript.norwegian
        #expect(Set(scripts.map(\.id)).count == scripts.count)
        #expect(Set(scripts.map(\.text)).count == scripts.count)
    }

    /// The script is saved verbatim as the transcript, so stray whitespace
    /// would become part of what the model is told was said.
    @Test func scriptsAreCleanEnoughToStoreAsATranscript() {
        for script in ReferenceScript.norwegian {
            #expect(script.text.first?.isWhitespace == false)
            #expect(script.text.last == "." || script.text.last == "?"
                    || script.text.last == "!")
            #expect(!script.text.contains("\n"))
            #expect(!script.text.contains("  "))
        }
    }

    /// A reference clip wants a few seconds of varied speech. Too short and
    /// the clone has nothing to copy; too long and it is wasted, since the
    /// store trims at 12 s anyway.
    @Test func scriptsAreTheRightLengthToReadAloud() {
        for script in ReferenceScript.norwegian {
            #expect(script.estimatedSeconds >= 5)
            #expect(script.estimatedSeconds <= 12)
        }
    }

    /// The point of a fixed script is to put the language's awkward sounds in
    /// the reader's mouth — a passage with no æ, ø or å teaches the clone
    /// nothing about Norwegian.
    @Test func everyScriptExercisesTheNorwegianVowels() {
        for script in ReferenceScript.norwegian {
            let lowered = script.text.lowercased()
            #expect(lowered.contains("æ") || lowered.contains("ø")
                    || lowered.contains("å"))
        }
        // And across the set, all three appear.
        let all = ReferenceScript.norwegian.map(\.text).joined().lowercased()
        #expect(all.contains("æ"))
        #expect(all.contains("ø"))
        #expect(all.contains("å"))
    }
}
