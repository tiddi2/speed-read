import Foundation

/// The spoken words the normalizer injects, per language.
///
/// The shared back-end rewrites symbols and abbreviations into words the
/// TTS voice can read ("50 %" → "50 percent", "e.g." → "for example").
/// Those words belong to a language, so every phase that injects one takes
/// them from here instead of hard-coding English.
///
/// `.english` is the parity baseline (T-4): its tables reproduce
/// reference/normalize.py exactly, so neither their contents nor their
/// order may change — the fixture outputs in Tests/SRCoreTests/fixtures
/// are byte-compared against them.
struct NormalizerLexicon {
    /// The bare percent sign, and LaTeX `\%`.
    let percent: String
    /// Compound percentage forms, keyed by the qualifier before `%`
    /// ("12 wt %"). Keys are notation, not words, so they are shared.
    let compoundPercent: [String: String]
    /// Abbreviation → expansion, in table order. The alternation built from
    /// it is sorted length-descending, so this order only breaks ties.
    /// Keys must be unique.
    let abbreviations: [(String, String)]
    /// Overrides for phase C's symbol table, keyed by the symbol. A symbol
    /// absent here keeps its English reading (most are notation — "±", "→"
    /// — whose English wording is what the voice needs anyway; the logic
    /// connectives are the ones that read as ordinary words).
    let symbolOverrides: [String: String]

    static func forLanguage(_ language: SpeechLanguage) -> NormalizerLexicon {
        switch language {
        case .english: return english
        case .norwegian: return norwegian
        }
    }

    // MARK: - English (parity baseline — do not edit)

    static let english = NormalizerLexicon(
        percent: "percent",
        compoundPercent: [
            "wt": "percent by weight", "vol": "percent by volume",
            "at": "atomic percent", "mol": "mole percent",
        ],
        abbreviations: [
            ("Sect.", "Section"), ("sect.", "section"), ("Ch.", "Chapter"), ("ch.", "chapter"),
            ("Vol.", "Volume"), ("vol.", "volume"), ("Suppl.", "Supplementary"),
            ("suppl.", "supplementary"), ("approx.", "approximately"), ("vs.", "versus"),
            ("e.g.", "for example"), ("i.e.", "that is"), ("et al.", "et al"),
            ("etc.", "et cetera"), ("cf.", "compare"), ("viz.", "namely"),
            ("Dr.", "Doctor"), ("Prof.", "Professor"), ("Mr.", "Mister"), ("Mrs.", "Misses"),
            ("Ms.", "Ms"), ("Sr.", "Senior"), ("Jr.", "Junior"), ("St.", "Saint"), ("Mt.", "Mount"),
        ],
        symbolOverrides: [:]
    )

    // MARK: - Norwegian (bokmål)

    static let norwegian = NormalizerLexicon(
        percent: "prosent",
        compoundPercent: [
            "wt": "vektprosent", "vol": "volumprosent",
            "at": "atomprosent", "mol": "molprosent",
        ],
        abbreviations: [
            // Norwegian abbreviations. Sentence-initial forms are listed
            // separately because the back-end's alternation is case-sensitive.
            ("f.eks.", "for eksempel"), ("F.eks.", "For eksempel"),
            ("bl.a.", "blant annet"), ("Bl.a.", "Blant annet"),
            ("dvs.", "det vil si"), ("Dvs.", "Det vil si"),
            ("osv.", "og så videre"),
            ("jf.", "jamfør"), ("Jf.", "Jamfør"),
            ("ca.", "cirka"), ("Ca.", "Cirka"),
            ("pga.", "på grunn av"), ("Pga.", "På grunn av"),
            ("iht.", "i henhold til"), ("Iht.", "I henhold til"),
            ("mfl.", "med flere"), ("m.m.", "med mer"),
            ("evt.", "eventuelt"), ("Evt.", "Eventuelt"),
            ("nr.", "nummer"), ("Nr.", "Nummer"),
            ("kap.", "kapittel"), ("Kap.", "Kapittel"),
            ("bd.", "bind"), ("Bd.", "Bind"),
            // Latin forms that survive in Norwegian text, read in Norwegian.
            ("e.g.", "for eksempel"), ("i.e.", "det vil si"), ("et al.", "et al"),
            ("etc.", "og så videre"), ("cf.", "jamfør"), ("viz.", "nemlig"),
            ("approx.", "omtrent"), ("vs.", "mot"),
            ("Dr.", "doktor"), ("Prof.", "professor"),
            ("Sr.", "senior"), ("Jr.", "junior"), ("St.", "Sankt"),
        ],
        symbolOverrides: [
            "\u{2227}": " og ",     // ∧
            "\u{2228}": " eller ",  // ∨
            "\u{00ac}": " ikke ",   // ¬
        ]
    )
}
