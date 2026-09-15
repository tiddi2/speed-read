import Testing
@testable import SRCore

/// Language-aware normalization: a Norwegian read must not have English
/// words injected into it.
///
/// Fixtures live in fixtures-no/NN-name.in.txt with expected output in
/// NN-name.out.txt. Unlike the English fixtures these are not golden files
/// from the reference implementation — Speak11 has no Norwegian mode — so
/// they encode sr's own behaviour.
/// No Foundation import here — see FixtureLoader.swift.
@Suite struct NormalizerNorwegianTests {
    static let directory = FixtureLoader.norwegianDirectory

    @Test func fixturesExist() {
        let found = FixtureLoader.names(in: Self.directory).count
        #expect(found >= 4, "expected ≥4 Norwegian fixtures, found \(found)")
    }

    @Test(arguments: FixtureLoader.names(in: FixtureLoader.norwegianDirectory))
    func norwegianFixture(fixture: String) {
        guard let pair = FixtureLoader.pair(named: fixture, in: Self.directory) else {
            Issue.record("fixture \(fixture) not found")
            return
        }
        let got = NormalizerParityTests.trimOneTrailingNewline(
            Normalizer.normalize(pair.input, language: .norwegian))
        let want = NormalizerParityTests.trimOneTrailingNewline(pair.expected)
        #expect(got == want,
                "\(fixture): \(NormalizerParityTests.firstDivergence(got, want))")
    }

    /// The three constructs the Norwegian lexicon exists for.
    @Test func norwegianReadSpeaksNorwegian() {
        let source = "Andelen er 50 %, f.eks. når 3 ∧ 4 er sanne."
        let got = Normalizer.normalize(source, language: .norwegian)
        #expect(got.contains("50 prosent"))
        #expect(got.contains("for eksempel"))
        #expect(got.contains("3 og 4"))
        #expect(!got.contains("percent"))
        #expect(!got.contains("for example"))
    }

    /// Same text, English read: unchanged, and `.english` is the default.
    @Test func englishReadIsUnaffected() {
        let source = "Andelen er 50 %, f.eks. når 3 ∧ 4 er sanne."
        let byDefault = Normalizer.normalize(source)
        #expect(byDefault == Normalizer.normalize(source, language: .english))
        #expect(byDefault.contains("50 percent"))
        #expect(byDefault.contains("3 and 4"))
        // "f.eks." is not an English abbreviation, so an English read leaves
        // it alone rather than borrowing the Norwegian table.
        #expect(byDefault.contains("f.eks."))
    }

    /// The compound percentage forms and the LaTeX escape follow suit.
    @Test func compoundPercentAndLatexEscapeFollowTheLanguage() {
        #expect(Normalizer.normalize("Prøven var 12 wt % vann.", language: .norwegian)
            .contains("12 vektprosent"))
        #expect(Normalizer.normalize("Prøven var 12 wt % vann.")
            .contains("12 percent by weight"))
        let latex = "Andelen \\textbf{økte} med 12 \\% i fjor."
        #expect(Normalizer.detectFrontend(latex) == .latex)
        #expect(Normalizer.normalize(latex, language: .norwegian).contains("12 prosent"))
        #expect(Normalizer.normalize(latex).contains("12 percent"))
    }

    /// phaseB builds a dictionary from the table, which traps on a duplicate
    /// key — a typo in a lexicon must fail here, not in a user's read.
    @Test(arguments: SpeechLanguage.allCases)
    func abbreviationKeysAreUnique(language: SpeechLanguage) {
        let keys = NormalizerLexicon.forLanguage(language).abbreviations.map(\.0)
        #expect(Set(keys).count == keys.count, "duplicate abbreviation in \(language)")
    }
}
