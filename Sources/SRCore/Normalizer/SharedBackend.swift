import Foundation

// Shared back-end (normalize.py `_phase0` … `_phaseD`). Source-agnostic.
extension Normalizer {
    // MARK: - Phase 0: universal typographic normalization

    static func phase0(_ input: String) -> String {
        var t = input
        t = t.replacingOccurrences(of: "\u{2212}", with: "-")     // minus sign
        t = t.replacingOccurrences(of: "\u{2026}", with: "...")   // ellipsis
        t = t.replacingOccurrences(of: "\u{201c}", with: "\"")
        t = t.replacingOccurrences(of: "\u{201d}", with: "\"")
        t = t.replacingOccurrences(of: "\u{2018}", with: "'")
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
        t = t.replacingOccurrences(of: "\u{00b7}", with: " ")     // middle dot
        // Exotic whitespace to regular space.
        t = t.sub("[\u{00a0}\u{2007}\u{2009}\u{200a}\u{202f}\u{205f}]", " ")
        return t
    }

    // MARK: - Phase A: noise removal (URLs, DOIs, chemicals, citations)

    static func phaseA(_ input: String) -> String {
        var t = input
        t = t.sub(NormalizerData.chemPattern) { m in
            NormalizerData.chem[m.matched] ?? m.matched
        }
        // Bare URLs (no protocol): go.nature.com/4rzrnyx → "go dot nature dot com slash 4rzrnyx"
        let tlds = #"(?:com|org|net|edu|io|gov|co|uk|de|fr|jp|au|ca|nl|ch|it|es|info|me|dev|app|ai)"#
        t = t.sub(#"(?<!//)(?<!/)(?<!@)\b(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"# + tlds + #"\b(?:/\S*)?"#,
                  options: [.caseInsensitive]) { m in
            var s = m.matched
            var trail = ""
            while let last = s.last, ".,;:?!)]\"'".contains(last) {
                trail = String(last) + trail
                s = String(s.dropLast())
            }
            s = s.replacingOccurrences(of: "/", with: " slash ")
            s = s.replacingOccurrences(of: ".", with: " dot ")
            return s + trail
        }
        // URLs and DOIs.
        t = t.sub(#"https?://\S+"#, "")
        t = t.sub(#"(?i)\bdoi:\s*\S+"#, "")
        // Citation references (scientific papers).
        t = t.sub("(?<=[a-z]{4})\\d+(?:\\s*[,\u{2013}\u{2014}-]\\s*\\d+)+(?=[\\s.,;:?!'\")\\]]|$)", "")
        t = t.sub("(?<=et al\\.)\\d+(?:\\s*[,\u{2013}\u{2014}-]\\s*\\d+)*", "")
        t = t.sub(#"\s*\[\d+(?:\s*[,;"# + "\u{2013}\u{2014}" + #"-]\s*\d+)*\]\s*"#, " ")
        // Mid-sentence superscript citations: "study 4 that" → "study that".
        t = t.sub(NormalizerData.citePattern) { m in
            let prev = (m[1] ?? "").lowercased()
            if NormalizerData.numContextWords.contains(prev)
                || (m[1] ?? "").allSatisfy({ $0.isNumber }) && !(m[1] ?? "").isEmpty {
                return m.matched
            }
            return (m[1] ?? "") + " "
        }
        // Author-year citations: "(Smith et al., 2020; Lee and Kim, 2021)".
        let months = #"(?:January|February|March|April|May|June|July|August|September|October|November|December)"#
        t = t.sub(#"\s*\((?:(?!"# + months + #")[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+(?!"# + months
                  + #")[A-Z][a-z]+))?(?:,?\s*\d{4})\s*(?:;\s*(?!"# + months + #")[A-Z][a-z]+(?:\s+(?:et\s+al\.|and\s+(?!"#
                  + months + #")[A-Z][a-z]+))?(?:,?\s*\d{4})\s*)*)\)\s*"#, " ")
        return t
    }

    // MARK: - Phase B: punctuation, abbreviations, Miller indices, currency

    static func phaseB(_ input: String,
                       _ lexicon: NormalizerLexicon = .english) -> String {
        var t = input
        // Arc-minutes/seconds in DMS notation.
        t = t.sub("(\\d+)\u{2032}\\s*(\\d+)\u{2033}", "$1 arc minutes $2 arc seconds")
        t = t.sub("(\\d+\u{00b0}\\s*)(\\d+)\u{2032}") { m in
            (m[1] ?? "") + (m[2] ?? "") + " arc minutes"
        }
        t = t.replacingOccurrences(of: "\u{2032}", with: "'")
        t = t.replacingOccurrences(of: "\u{2033}", with: "\"")
        // Miller indices: parenthesized digit groups read digit-by-digit.
        t = t.sub(#"\(0(\d{1,2})\)"#) { m in
            "(" + ("0" + (m[1] ?? "")).map(String.init).joined(separator: " ") + ")"
        }
        let millerContext = #"planes?|reflections?|peaks?|indexed|facets?|diffraction|surfaces?|Miller|directions?"#
        t = t.sub(#"\b("# + millerContext + #")\s+\((\d{3})\)"#) { m in
            (m[1] ?? "") + " (" + (m[2] ?? "").map(String.init).joined(separator: " ") + ")"
        }
        t = t.sub(#"\((\d{3})\)\s+("# + millerContext + #")\b"#) { m in
            "(" + (m[1] ?? "").map(String.init).joined(separator: " ") + ") " + (m[2] ?? "")
        }
        let millParen = #"\(\d(?:\s?\d){0,2}\)"#
        t = t.sub(millParen + #"(?:\s*,\s*(?:and\s+)?"# + millParen + #"){1,}"#) { m in
            m.matched.sub(#"\((\d{1,3})\)"#) { inner in
                "(" + (inner[1] ?? "").map(String.init).joined(separator: " ") + ")"
            }
        }
        // Punctuation collapse.
        t = t.sub(#"\.{4,}"#, "...")
        t = t.sub(#"\?{2,}"#, "?")
        t = t.sub(#"!{2,}"#, "!")
        // Common academic abbreviations.
        t = t.sub(#"\bFigs?\."#) { m in m.matched.hasPrefix("Figs") ? "Figures" : "Figure" }
        t = t.sub(#"\bfigs?\."#) { m in m.matched.hasPrefix("figs") ? "figures" : "figure" }
        t = t.sub(#"\bEqs?\."#) { m in m.matched.hasPrefix("Eqs") ? "Equations" : "Equation" }
        t = t.sub(#"\beqs?\."#) { m in m.matched.hasPrefix("eqs") ? "equations" : "equation" }
        t = t.sub(#"\bRefs?\."#) { m in m.matched.hasPrefix("Refs") ? "References" : "Reference" }
        t = t.sub(#"\brefs?\."#) { m in m.matched.hasPrefix("refs") ? "references" : "reference" }
        t = t.sub(#"\bNo\.(?=\s*\d)"#, "Number")
        t = t.sub(#"\bno\.(?=\s*\d)"#, "number")
        let abbrOrder = lexicon.abbreviations
        let abbrMap = Dictionary(uniqueKeysWithValues: abbrOrder)
        let abbrAlt = lengthDescending(abbrOrder.map(\.0))
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        t = t.sub(#"\b("# + abbrAlt + ")") { m in abbrMap[m.matched] ?? m.matched }
        // Journal abbreviation chains (2+ in sequence lose their periods).
        let jour = ["Nat", "Commun", "Phys", "Rev", "Lett", "Proc", "Natl", "Acad",
                    "Sci", "Chem", "Soc", "Am", "Biol", "Med", "Eng", "Mater", "Appl", "Opt",
                    "Mech", "Res", "Math", "Stat", "Astron", "Astrophys", "Geophys", "Nucl",
                    "Mol", "Cell", "Genet", "Biochem", "Biophys", "Environ", "Technol", "Pharmacol"]
        t = t.sub(#"(?:(?:"# + jour.joined(separator: "|") + #")\.(?:\s+|$)){2,}"#) { m in
            m.matched.replacingOccurrences(of: ".", with: "")
        }
        // Abbreviation+citation ranges: Figures 1–3 → Figures 1 through 3.
        let plurals: [String: String] = [
            "Figure": "Figures", "Equation": "Equations", "Reference": "References",
            "Section": "Sections", "Chapter": "Chapters", "Number": "Numbers",
            "figure": "figures", "equation": "equations", "reference": "references",
            "section": "sections", "chapter": "chapters", "number": "numbers",
        ]
        t = t.sub("\\b(Figures?|Equations?|References?|Sections?|Chapters?|Numbers?|figures?|equations?|references?|sections?|chapters?|numbers?)\\s*(\\d+)\\s*[-\u{2013}\u{2014}]\\s*(\\d+)") { m in
            let label = plurals[m[1] ?? ""] ?? (m[1] ?? "")
            return label + " " + (m[2] ?? "") + " through " + (m[3] ?? "")
        }
        // Currency: US$10-million → 10 million US dollars.
        let currSym: [String: (String, String)] = [
            "$": ("dollar", "dollars"), "€": ("euro", "euros"),
            "£": ("pound", "pounds"), "¥": ("yen", "yen"), "₹": ("rupee", "rupees"),
        ]
        let currPfx: [String: String] = [
            "US": "US", "A": "Australian", "AU": "Australian",
            "C": "Canadian", "CA": "Canadian", "NZ": "New Zealand",
            "HK": "Hong Kong", "S": "Singapore",
        ]
        let pfxAlt = lengthDescending(["US", "A", "AU", "C", "CA", "NZ", "HK", "S"]).joined(separator: "|")
        let symAlt = ["$", "€", "£", "¥", "₹"]
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        t = t.sub(#"(?<![A-Za-z])(?:("# + pfxAlt + #")\s*)?("# + symAlt
                  + #")\s*(\d[\d,]*(?:\.\d+)?)(?:(?:[-"# + "\u{2010}\u{2011}\u{2013}"
                  + #"]\s*|\s+)([Mm]illion|[Bb]illion|[Tt]rillion|[Tt]housand))?"#) { m in
            let pfx = m[1]
            let sym = m[2] ?? "$"
            let amt = m[3] ?? ""
            let mult = m[4]
            let (singular, plural) = currSym[sym] ?? ("dollar", "dollars")
            let isOne = ["1", "1.0", "1.00"].contains(amt)
            let word = (isOne && mult == nil) ? singular : plural
            var parts = [amt]
            if let mult { parts.append(mult.lowercased()) }
            if let pfx { parts.append(currPfx[pfx] ?? pfx) }
            parts.append(word)
            return parts.joined(separator: " ")
        }
        // Numeric ranges: en/em-dash between digits → X to Y.
        t = t.sub("(\\d[\\d.,]*)\\s*[\u{2013}\u{2014}]\\s*(\\d[\\d.,]*)", "$1 to $2")
        // Remaining en/em-dash (pauses, asides).
        t = t.sub(" ?[\u{2014}\u{2013}] ?", " -- ")
        t = t.sub(#" ?-{2,3} ?"#, " -- ")
        // Math operators.
        t = t.sub(#" <= "#, " less than or equal to ")
        t = t.sub(#" >= "#, " greater than or equal to ")
        t = t.sub(#" != "#, " not equal to ")
        t = t.sub(#" = "#, " equals ")
        t = t.sub(#" << "#, " much less than ")
        t = t.sub(#" >> "#, " much greater than ")
        t = t.sub(#"\s*~(?=\s?\d)"#, " approximately ")
        t = t.sub(#"~(?!/)"#, " ")
        // Compound percentage forms (before bare % rule).
        let pct = lexicon.compoundPercent
        t = t.sub(#"(\d+(?:\.\d+)?)\s*(wt|vol|at|mol)\s*%"#) { m in
            (m[1] ?? "") + " " + (pct[m[2] ?? ""] ?? "")
        }
        t = t.sub(#"(\d+(?:\.\d+)?)\s*%"#) { m in (m[1] ?? "") + " " + lexicon.percent }
        // DNA prime notation.
        t = t.sub(#"\b([53])'"#, "$1 prime")
        return t
    }

    // MARK: - Phase C: scientific symbols and units

    private static let symbolTable: [(String, String)] = [
        ("\u{00c5}", " angstroms "), ("\u{212b}", " angstroms "),
        ("\u{00b1}", " plus or minus "), ("\u{00d7}", " times "),
        ("\u{2248}", " approximately "),
        ("\u{2264}", " less than or equal to "), ("\u{2265}", " greater than or equal to "),
        ("\u{221e}", " infinity "), ("\u{221a}", " square root of "),
        ("\u{2192}", " to "), ("\u{2190}", " from "), ("\u{2194}", " to and from "),
        ("\u{21cc}", " is in equilibrium with "),
        ("\u{2260}", " not equal to "), ("\u{2261}", " equivalent to "),
        ("\u{221d}", " proportional to "),
        ("\u{2202}", " partial "), ("\u{2211}", " sum of "), ("\u{220f}", " product of "),
        ("\u{222b}", " integral of "), ("\u{2207}", " del "), ("\u{2205}", " empty set "),
        ("\u{2103}", " degrees Celsius "), ("\u{2109}", " degrees Fahrenheit "),
        ("\u{210f}", " h-bar "), ("\u{2113}", " liters "), ("\u{2030}", " per mille "),
        ("\u{2220}", " angle "), ("\u{2225}", " parallel to "),
        ("\u{22a5}", " perpendicular to "),
        ("\u{2208}", " in "), ("\u{2209}", " not in "),
        ("\u{2282}", " subset of "), ("\u{2283}", " superset of "),
        ("\u{2286}", " subset of "), ("\u{2287}", " superset of "),
        ("\u{2229}", " intersection "), ("\u{222a}", " union "),
        ("\u{2234}", " therefore "), ("\u{2235}", " because "),
        ("\u{2200}", "for all "), ("\u{2203}", "there exists "), ("\u{2204}", "there does not exist "),
        ("\u{00ac}", " not "), ("\u{2227}", " and "), ("\u{2228}", " or "), ("\u{22bb}", " xor "),
        ("\u{2295}", " direct sum "), ("\u{2297}", " tensor product "),
        ("\u{22c5}", " dot "), ("\u{22c6}", " star "),
        ("\u{2020}", " dagger "), ("\u{2021}", " double dagger "),
        ("\u{21d2}", " implies "), ("\u{21d0}", " is implied by "), ("\u{21d4}", " if and only if "),
        ("\u{27f9}", " implies "), ("\u{27fa}", " if and only if "),
        ("\u{21a6}", " maps to "),
        ("\u{2191}", " up "), ("\u{2193}", " down "), ("\u{2195}", " up and down "),
        ("\u{2609}", " solar "),
    ]

    /// _UUNIT (µ-prefixed units).
    private static let microUnits: [(String, String)] = [
        ("m", "meters"), ("L", "liters"), ("l", "liters"), ("g", "grams"), ("s", "seconds"),
        ("A", "amperes"), ("V", "volts"), ("W", "watts"), ("F", "farads"), ("H", "henrys"),
        ("S", "siemens"), ("T", "teslas"), ("Pa", "pascals"), ("J", "joules"), ("N", "newtons"),
        ("K", "kelvins"), ("mol", "moles"), ("Hz", "hertz"), ("Ohm", "ohms"),
        ("\u{03a9}", "ohms"), ("M", "molar"),
    ]

    /// _SI (insertion order preserved for alternation parity).
    private static let siOrder: [(String, String)] = [
        ("GPa", "gigapascals"), ("MPa", "megapascals"), ("kPa", "kilopascals"), ("hPa", "hectopascals"),
        ("GHz", "gigahertz"), ("MHz", "megahertz"), ("kHz", "kilohertz"),
        ("GW", "gigawatts"), ("MW", "megawatts"), ("kW", "kilowatts"), ("mW", "milliwatts"),
        ("MeV", "megaelectronvolts"), ("keV", "kiloelectronvolts"), ("GeV", "gigaelectronvolts"),
        ("kV", "kilovolts"), ("mV", "millivolts"),
        ("mL", "milliliters"), ("dL", "deciliters"),
        ("nm", "nanometers"), ("mm", "millimeters"), ("cm", "centimeters"), ("km", "kilometers"),
        ("mg", "milligrams"), ("kg", "kilograms"), ("ng", "nanograms"), ("pg", "picograms"),
        ("ns", "nanoseconds"), ("ms", "milliseconds"), ("ps", "picoseconds"), ("fs", "femtoseconds"),
        ("kJ", "kilojoules"), ("MJ", "megajoules"),
        ("mM", "millimolar"), ("nM", "nanomolar"), ("pM", "picomolar"),
        ("kDa", "kilodaltons"), ("MDa", "megadaltons"),
        ("mA", "milliamperes"),
        ("TeV", "teraelectronvolts"), ("meV", "millielectronvolts"), ("eV", "electron volts"),
        ("Hz", "hertz"), ("Pa", "pascals"), ("dB", "decibels"), ("mol", "moles"),
        ("Wb", "webers"), ("Gy", "grays"), ("Sv", "sieverts"), ("Bq", "becquerels"),
        ("ppmv", "parts per million by volume"), ("ppbv", "parts per billion by volume"),
        ("ppm", "parts per million"), ("ppb", "parts per billion"), ("ppt", "parts per trillion"),
        ("Gpc", "gigaparsecs"), ("Mpc", "megaparsecs"), ("kpc", "kiloparsecs"), ("pc", "parsecs"),
        ("AU", "astronomical units"),
        ("Gbp", "gigabase pairs"), ("Mbp", "megabase pairs"), ("kbp", "kilobase pairs"),
        ("bp", "base pairs"), ("nt", "nucleotides"), ("Da", "daltons"),
        ("rpm", "revolutions per minute"),
        ("kcal", "kilocalories"), ("cal", "calories"),
        ("atm", "atmospheres"), ("mbar", "millibars"), ("bar", "bars"),
        ("Torr", "torr"), ("mmHg", "millimeters of mercury"),
        ("K", "kelvins"), ("V", "volts"), ("W", "watts"), ("J", "joules"),
        ("L", "liters"),
    ]

    static func phaseC(_ input: String,
                       _ lexicon: NormalizerLexicon = .english) -> String {
        var t = input
        // Bra-ket notation.
        t = t.sub("\u{27e8}([^\u{27e9}]*)\u{27e9}") { m in
            (m[1] ?? "").replacingOccurrences(of: "|", with: " ")
        }
        // Single-character symbols to spoken form.
        for (sym, word) in symbolTable {
            t = t.replacingOccurrences(of: sym, with: lexicon.symbolOverrides[sym] ?? word)
        }
        // Degree+letter units (must precede bare degree).
        t = t.sub("(?<=\\d)\\s*\u{00b0}C\\b", " degrees Celsius")
        t = t.sub("(?<=\\d)\\s*\u{00b0}F\\b", " degrees Fahrenheit")
        t = t.sub("(?<=\\d)\\s*\u{00b0}K\\b", " degrees Kelvin")
        t = t.sub("(?<=\\d)\\s*\u{00b0}(?=\\s|$|[.,;:?!])", " degrees")
        // Micro prefix: both µ (U+00B5) and μ (U+03BC).
        let microSorted = microUnits.enumerated()
            .sorted { ($0.element.0.count, $1.offset) > ($1.element.0.count, $0.offset) }
            .map(\.element)
        for prefix in ["\u{00b5}", "\u{03bc}"] {
            for (u, w) in microSorted {
                t = t.replacingOccurrences(of: prefix + u, with: "micro" + w)
            }
            if t.contains(prefix) {
                t = t.sub(NSRegularExpression.escapedPattern(for: prefix) + #"(\w)"#, "micro-$1")
            }
        }
        // SI prefix+unit abbreviations after numbers.
        let si = Dictionary(uniqueKeysWithValues: siOrder)
        let siAlt = lengthDescending(siOrder.map(\.0)).joined(separator: "|")
        t = t.sub(#"(?<=\d)\s*("# + siAlt + #")\b"#) { m in
            " " + (si[m[1] ?? ""] ?? "")
        }
        // Unit separator: slash -> per.
        let unitEnds = Set(si.values.map { $0.components(separatedBy: " ").last! })
            .union(microUnits.map { "micro" + $0.1 })
        let unitEndsAlt = lengthDescending(Array(unitEnds))
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        t = t.sub(#"\b("# + unitEndsAlt + #")/([a-zA-Z])"#, "$1 per $2")
        t = t.sub(#"(?<=\d)(\s*)(m|s|g|A|N)/([a-zA-Z])"#, "$1$2 per $3")
        // Expand denominator units after "per" (singular form).
        let siSingular = si.mapValues { v in
            v.hasSuffix("s") && v != "siemens" ? String(v.dropLast()) : v
        }
        t = t.sub(#"(?<=per )("# + siAlt + #")\b"#) { m in
            siSingular[m[1] ?? ""] ?? (m[1] ?? "")
        }
        // Ohm: number + Ω.
        t = t.sub("(?<=\\d)\\s*[\u{2126}\u{03a9}](?=\\s|$|[.,;:?!)])", " ohms")
        // Greek letters (α → " alpha " etc.; final sigma and accented forms
        // fold to their base letter, matching unicodedata-name derivation).
        t = t.sub("[\u{0391}-\u{03c9}]") { m in
            guard let word = greekLetterNames[m.matched] else { return m.matched }
            return " " + word + " "
        }
        // Greek compound fix: alpha -helix -> alpha-helix.
        let gk = "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega"
        t = t.sub(#"(\b(?:"# + gk + #"))\s+-\s*([a-z])"#, "$1-$2", [.caseInsensitive])
        // Roman numerals after labels.
        t = t.sub(#"\b(Section|Chapter|Part|Article|Item|Figure|Table|Act|Vol|No)(\s+)((?:X{0,3})(?:IX|IV|V?I{0,3}))\b"#) { m in
            (m[1] ?? "") + (m[2] ?? "") + (romanValues[m[3] ?? ""] ?? (m[3] ?? ""))
        }
        // Oxidation states.
        let rvAlt = lengthDescending(Array(romanValues.keys)).joined(separator: "|")
        t = t.sub(#"\(("# + rvAlt + #")\)"#) { m in
            "(" + (romanValues[m[1] ?? ""] ?? (m[1] ?? "")) + ")"
        }
        // Numbered protein complexes.
        t = t.sub(#"\b(Complex|Subunit|Chain|Type|Class)\s+("# + rvAlt + #")\b"#) { m in
            (m[1] ?? "") + " " + (romanValues[m[2] ?? ""] ?? (m[2] ?? ""))
        }
        return t
    }

    /// Roman numeral → digit string (I…XX).
    private static let romanValues: [String: String] = {
        let numerals = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X",
                        "XI", "XII", "XIII", "XIV", "XV", "XVI", "XVII", "XVIII", "XIX", "XX"]
        var map: [String: String] = [:]
        for (i, r) in numerals.enumerated() { map[r] = String(i + 1) }
        return map
    }()

    /// U+0391–U+03C9 → spoken base-letter name (unicodedata.name derivation:
    /// last word before WITH, lowercased, LAMDA→lambda; U+03A2 is unassigned).
    private static let greekLetterNames: [String: String] = [
        "\u{0391}": "alpha", "\u{0392}": "beta", "\u{0393}": "gamma", "\u{0394}": "delta",
        "\u{0395}": "epsilon", "\u{0396}": "zeta", "\u{0397}": "eta", "\u{0398}": "theta",
        "\u{0399}": "iota", "\u{039a}": "kappa", "\u{039b}": "lambda", "\u{039c}": "mu",
        "\u{039d}": "nu", "\u{039e}": "xi", "\u{039f}": "omicron", "\u{03a0}": "pi",
        "\u{03a1}": "rho", "\u{03a3}": "sigma", "\u{03a4}": "tau", "\u{03a5}": "upsilon",
        "\u{03a6}": "phi", "\u{03a7}": "chi", "\u{03a8}": "psi", "\u{03a9}": "omega",
        "\u{03aa}": "iota", "\u{03ab}": "upsilon", "\u{03ac}": "alpha", "\u{03ad}": "epsilon",
        "\u{03ae}": "eta", "\u{03af}": "iota", "\u{03b0}": "upsilon",
        "\u{03b1}": "alpha", "\u{03b2}": "beta", "\u{03b3}": "gamma", "\u{03b4}": "delta",
        "\u{03b5}": "epsilon", "\u{03b6}": "zeta", "\u{03b7}": "eta", "\u{03b8}": "theta",
        "\u{03b9}": "iota", "\u{03ba}": "kappa", "\u{03bb}": "lambda", "\u{03bc}": "mu",
        "\u{03bd}": "nu", "\u{03be}": "xi", "\u{03bf}": "omicron", "\u{03c0}": "pi",
        "\u{03c1}": "rho", "\u{03c2}": "sigma", "\u{03c3}": "sigma", "\u{03c4}": "tau",
        "\u{03c5}": "upsilon", "\u{03c6}": "phi", "\u{03c7}": "chi", "\u{03c8}": "psi",
        "\u{03c9}": "omega",
    ]

    // MARK: - Phase D: final cleanup

    static func phaseD(_ input: String) -> String {
        var t = input
        t = t.sub(#" {2,}"#, " ")
        t = t.sub(#" +([.,;:?!)\]])"#, "$1")
        t = t.sub(#"([\(\[]) +"#, "$1")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
