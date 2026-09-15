import Foundation

// LaTeX front-end (normalize.py `_frontend_latex`, rules L1-L6).
extension Normalizer {
    /// Math-internal environments hidden from L3 via \x03 sentinels.
    private static let mathEnvs: [String] = [
        "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "matrix",
        "pmatrix*", "bmatrix*", "cases", "smallmatrix", "array",
    ]

    private static func restoreMathSentinels(_ input: String) -> String {
        var text = input
        for me in mathEnvs {
            text = text.replacingOccurrences(of: "\u{03}BEGIN_" + me + "\u{03}",
                                             with: "\\begin{" + me + "}")
            text = text.replacingOccurrences(of: "\u{03}END_" + me + "\u{03}",
                                             with: "\\end{" + me + "}")
        }
        return text
    }

    /// Where sr looks for a user LaTeX macro cache (reference used
    /// ~/.config/speak11/latex_macros.tex).
    static var latexMacroCacheURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/latex_macros.tex")
    }

    static func frontendLatex(_ input: String,
                              _ lexicon: NormalizerLexicon = .english) -> String {
        var t = input

        // ── L1: Comment and preamble stripping ──
        t = t.sub(#"(?<!\\)%.*$"#, "", [.anchorsMatchLines])
        t = t.sub(#"^.*?\\begin\{document\}"#, "", [.dotMatchesLineSeparators])
        t = t.sub(#"\\end\{document\}.*$"#, "", [.dotMatchesLineSeparators])
        t = t.sub(#"\\(?:documentclass|usepackage|geometry|hypersetup|setlength|setcounter"#
                  + #"|newtheorem|theoremstyle|bibliographystyle|bibliography"#
                  + #"|DeclareMathOperator|pagestyle|thispagestyle)\b(?:\[[^\]]*\])?"#
                  + #"\{[^}]*\}(?:\{[^}]*\})?"#, "")

        // ── L2: Custom macro expansion ──
        // Ordered macro table with dict-overwrite semantics (first-insert
        // position preserved, later definitions override the body).
        var macroNames: [String] = []
        var macroDefs: [String: (nargs: Int, body: String)] = [:]
        func define(_ name: String, _ nargs: Int, _ body: String) {
            if macroDefs[name] == nil { macroNames.append(name) }
            macroDefs[name] = (nargs, body)
        }
        let newcommandPat =
            #"\\newcommand\*?\{\\([a-zA-Z]+)\}(?:\[(\d+)\])?\{((?:[^{}]|\{[^{}]*\})*)\}"#
        let defPat = #"\\def\\([a-zA-Z]+)\{([^{}]*)\}"#
        if let cached = try? String(contentsOf: latexMacroCacheURL, encoding: .utf8) {
            for m in cached.allMatches(newcommandPat) {
                define(m[1] ?? "", m[2].flatMap { Int($0) } ?? 0, m[3] ?? "")
            }
            for m in cached.allMatches(defPat) {
                define(m[1] ?? "", 0, m[2] ?? "")
            }
        }
        // Collect macros from the selection itself (override cache).
        for m in t.allMatches(newcommandPat) {
            define(m[1] ?? "", m[2].flatMap { Int($0) } ?? 0, m[3] ?? "")
        }
        for m in t.allMatches(defPat) {
            define(m[1] ?? "", 0, m[2] ?? "")
        }
        // Strip definitions.
        t = t.sub(#"\\(?:newcommand|renewcommand)\*?\{\\[a-zA-Z]+\}(?:\[\d+\])?\{(?:[^{}]|\{[^{}]*\})*\}"#, "")
        t = t.sub(#"\\def\\[a-zA-Z]+\{[^{}]*\}"#, "")
        // Apply macros (up to 5 rounds for chained expansion).
        for _ in 0..<5 {
            var changed = false
            for name in macroNames {
                guard let def = macroDefs[name] else { continue }
                let escaped = NSRegularExpression.escapedPattern(for: name)
                let newT: String
                switch def.nargs {
                case 0:
                    newT = t.sub("\\\\" + escaped + "(?![a-zA-Z])",
                                 NSRegularExpression.escapedTemplate(for: def.body))
                case 1:
                    newT = t.sub("\\\\" + escaped + #"\{([^{}]*)\}"#) { m in
                        def.body.replacingOccurrences(of: "#1", with: m[1] ?? "")
                    }
                case 2:
                    newT = t.sub("\\\\" + escaped + #"\{([^{}]*)\}\{([^{}]*)\}"#) { m in
                        def.body
                            .replacingOccurrences(of: "#1", with: m[1] ?? "")
                            .replacingOccurrences(of: "#2", with: m[2] ?? "")
                    }
                default:
                    continue
                }
                if newT != t {
                    t = newT
                    changed = true
                }
            }
            if !changed { break }
        }

        // ── L3: Environment handling ──
        // Protect \& and \$ (env handlers call processText which has inline math regex).
        t = t.sub(#"(?<!\\)\\&"#, "\u{01}")
        t = t.sub(#"(?<!\\)\\\$"#, "\u{02}")

        // Hide math-internal environments from L3 so the env pattern can
        // match outer envs; restored for mathToSpeech in L5.
        for me in mathEnvs {
            let esc = NSRegularExpression.escapedPattern(for: me)
            t = t.sub(#"\\begin\{"# + esc + #"\}"#, "\u{03}BEGIN_" + me + "\u{03}")
            t = t.sub(#"\\end\{"# + esc + #"\}"#, "\u{03}END_" + me + "\u{03}")
        }

        typealias EnvHandler = (_ name: String, _ opt: String, _ content: String, _ label: String) -> String

        let envContent: EnvHandler = { _, _, content, _ in
            MathSpeech.processText(content)
        }
        func envPrefixed(_ prefix: String, _ suffix: String = "") -> EnvHandler {
            { _, _, content, _ in prefix + MathSpeech.processText(content) + suffix }
        }
        func envSkip(_ msg: String) -> EnvHandler {
            { _, _, _, _ in msg }
        }
        let envEquation: EnvHandler = { _, _, content, label in
            let spoken = MathSpeech.mathToSpeech(restoreMathSentinels(content))
            if !label.isEmpty {
                return "Equation " + label + ": " + spoken + "."
            }
            return "The equation: " + spoken + "."
        }
        let envAlign: EnvHandler = { _, _, content, _ in
            let lines = restoreMathSentinels(content).splitRegex(#"\\\\"#)
            var parts: [String] = []
            for line in lines {
                let cleaned = line.sub(#"&"#, " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if cleaned.isEmpty { continue }
                parts.append(MathSpeech.mathToSpeech(cleaned))
            }
            return "The aligned equations: " + parts.joined(separator: "; ") + "."
        }
        func envList(numbered: Bool) -> EnvHandler {
            { _, _, content, _ in
                let items = content.splitRegex(#"\\item\b\s*"#)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                var parts: [String] = []
                for (idx, item) in items.enumerated() {
                    let txt = MathSpeech.processText(item)
                    parts.append(numbered ? "\(idx + 1). " + txt : txt)
                }
                return parts.joined(separator: " ")
            }
        }
        let captionPat = #"\\caption(?:\[[^\]]*\])?\{((?:[^{}]|\{[^{}]*\})*)\}"#
        let envFigure: EnvHandler = { _, _, content, label in
            let caption = content.firstMatch(captionPat)
                .map { MathSpeech.processText($0[1] ?? "") } ?? ""
            var parts = ["Figure"]
            parts.append(label.isEmpty ? ":" : label + ":")
            parts.append(caption.isEmpty ? "No caption." : caption)
            return parts.joined(separator: " ")
        }
        let envTable: EnvHandler = { _, _, content, label in
            let caption = content.firstMatch(captionPat)
                .map { MathSpeech.processText($0[1] ?? "") } ?? ""
            var parts = ["Table"]
            parts.append(label.isEmpty ? ":" : label + ":")
            parts.append(caption.isEmpty ? "No caption." : caption)
            return parts.joined(separator: " ")
        }
        func envTheorem(_ kind: String) -> EnvHandler {
            { _, opt, content, _ in
                let title = opt.isEmpty ? kind : kind + " " + opt
                return title + ". " + MathSpeech.processText(content)
            }
        }

        let envHandlers: [String: EnvHandler] = [
            "document": envContent,
            "abstract": envPrefixed("Abstract. "),
            "proof": envPrefixed("Proof. ", " End of proof."),
            "equation": envEquation, "equation*": envEquation,
            "align": envAlign, "align*": envAlign,
            "eqnarray": envAlign, "eqnarray*": envAlign,
            "multline": envEquation, "multline*": envEquation,
            "gather": envAlign, "gather*": envAlign,
            "subequations": envContent,
            "table": envTable, "table*": envTable,
            "tabular": envSkip(""), "tabularx": envSkip(""),
            "longtable": envSkip(""),
            "figure": envFigure, "figure*": envFigure,
            "itemize": envList(numbered: false), "enumerate": envList(numbered: true),
            "tikzpicture": envSkip("Diagram omitted."),
            "pgfpicture": envSkip("Diagram omitted."),
            "verbatim": envSkip("Code block omitted."),
            "lstlisting": envSkip("Code listing omitted."),
            "algorithm": envSkip("Algorithm omitted."),
            "algorithmic": envSkip("Algorithm omitted."),
            "comment": envSkip(""),
            "thebibliography": envSkip("References omitted."),
            "theorem": envTheorem("Theorem"),
            "lemma": envTheorem("Lemma"),
            "corollary": envTheorem("Corollary"),
            "proposition": envTheorem("Proposition"),
            "definition": envTheorem("Definition"),
            "remark": envTheorem("Remark"),
            "example": envTheorem("Example"),
        ]

        let envPat = #"\\begin\{([a-zA-Z*]+)\}(?:\[([^\]]*)\])?((?:(?!\\begin\{)[\s\S])*?)\\end\{\1\}"#
        for _ in 0..<10 {
            let newT = t.sub(envPat) { m in
                let envName = m[1] ?? ""
                let optional = (m[2] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                var content = m[3] ?? ""
                let label = content.firstMatch(#"\\label\{([^}]+)\}"#)
                    .map { ($0[1] ?? "").components(separatedBy: ":").last ?? "" } ?? ""
                content = content.sub(#"\\label\{[^}]+\}"#, "")
                let handler = envHandlers[envName] ?? envContent
                return handler(envName, optional, content, label)
            }
            if newT == t { break }
            t = newT
        }

        // Restore math-internal env markers for L5.
        t = restoreMathSentinels(t)

        // ── L4: Text macro expansion ──
        // Sectioning.
        t = t.sub(#"\\part\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Part: $1. ")
        t = t.sub(#"\\chapter\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Chapter: $1. ")
        t = t.sub(#"\\section\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Section: $1. ")
        t = t.sub(#"\\subsection\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Subsection: $1. ")
        t = t.sub(#"\\subsubsection\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "$1. ")
        t = t.sub(#"\\paragraph\*?\{((?:[^{}]|\{[^{}]*\})*)\}"#, "$1. ")
        // Citations (silent).
        t = t.sub(#"\\cite(?:p|t|alt|alp)?\*?(?:\[[^\]]*\])?\{[^}]*\}"#, "")
        // Cross-references.
        let refPrefix: [String: String] = [
            "fig": "figure", "eq": "equation", "tab": "table",
            "sec": "section", "alg": "algorithm", "thm": "theorem",
            "lem": "lemma", "cor": "corollary", "def": "definition",
        ]
        t = t.sub(#"\\(?:ref|eqref|autoref|cref|Cref|pageref)\{([^}]+)\}"#) { m in
            let label = m[1] ?? ""
            let spaced = label
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            let parts = spaced.components(separatedBy: ":")
            if parts.count == 2 {
                return (refPrefix[parts[0].lowercased()] ?? parts[0]) + " " + parts[1]
            }
            return label.replacingOccurrences(of: "_", with: " ")
        }
        t = t.sub(#"\\label\{[^}]+\}"#, "")
        // mhchem: \ce{} -> plain formula text (replicates the reference's
        // replace order, where "->" is rewritten before "<->" can match).
        t = t.sub(#"\\ce\{([^}]+)\}"#) { m in
            var f = m[1] ?? ""
            f = f.replacingOccurrences(of: "->", with: " to ")
            f = f.replacingOccurrences(of: "<->", with: " is in equilibrium with ")
            f = f.replacingOccurrences(of: "+", with: " plus ")
            f = f.replacingOccurrences(of: "^", with: " ")
            f = f.replacingOccurrences(of: "_", with: "")
            return f
        }
        // siunitx: \SI{value}{unit}, \si{unit}, \num{value}.
        t = t.sub(#"\\SI\{([^}]+)\}\{([^}]+)\}"#) { m in
            let originalVal = m[1] ?? ""
            var val = originalVal.sub(#"(\d+\.?\d*)[eE]([+-]?\d+)"#) { em in
                var exp = em[2] ?? ""
                if exp.hasPrefix("-") {
                    exp = "negative " + exp.dropFirst()
                } else if exp.hasPrefix("+") {
                    exp = String(exp.dropFirst())
                }
                return (em[1] ?? "") + " times 10 to the " + exp
            }
            val = val.replacingOccurrences(of: "\\pm", with: " plus or minus ")
            return val + " " + MathSpeech.siunitxExpand(m[2] ?? "", value: originalVal)
        }
        t = t.sub(#"\\si\{([^}]+)\}"#) { m in MathSpeech.siunitxExpand(m[1] ?? "") }
        t = t.sub(#"\\num\{([^}]+)\}"#) { m in
            (m[1] ?? "").replacingOccurrences(of: "\\pm", with: " plus or minus ")
        }
        // URLs.
        t = t.sub(#"\\url\{[^}]*\}"#, "")
        t = t.sub(#"\\href\{[^}]*\}\{([^}]*)\}"#, "$1")
        // Footnotes.
        t = t.sub(#"\\footnote\{((?:[^{}]|\{[^{}]*\})*)\}"#, " (footnote: $1) ")
        // Title / author.
        t = t.sub(#"\\title\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Title: $1. ")
        t = t.sub(#"\\author\{((?:[^{}]|\{[^{}]*\})*)\}"#, "Authors: $1. ")
        // Special characters (\& and \$ already protected to \x01/\x02).
        t = t.replacingOccurrences(of: "\\%", with: " " + lexicon.percent + " ")
        t = t.replacingOccurrences(of: "\\#", with: "number ")
        t = t.replacingOccurrences(of: "\\{", with: "(")
        t = t.replacingOccurrences(of: "\\}", with: ")")
        t = t.replacingOccurrences(of: "---", with: "\u{2014}")
        t = t.replacingOccurrences(of: "--", with: "\u{2013}")
        t = t.replacingOccurrences(of: "~", with: " ")
        t = t.replacingOccurrences(of: "\\ldots", with: "...")
        t = t.replacingOccurrences(of: "\\dots", with: "...")
        // \input / \include (cannot follow).
        t = t.sub(#"\\(?:input|include|includeonly)\{[^}]+\}"#, "")
        // Text formatting.
        t = t.sub(#"\\(?:textit|emph|textsl|textbf|textsc|texttt|textsf)\{([^{}]*)\}"#, "$1")

        // ── L5: Math to spoken English ──
        t = t.sub(#"\$\$(.*?)\$\$"#, options: [.dotMatchesLineSeparators]) { m in
            " The equation: " + MathSpeech.mathToSpeech(m[1] ?? "") + " . "
        }
        t = t.sub(#"\\\[(.*?)\\\]"#, options: [.dotMatchesLineSeparators]) { m in
            " The equation: " + MathSpeech.mathToSpeech(m[1] ?? "") + " . "
        }
        t = t.sub(#"\$(.*?)\$"#) { m in
            " " + MathSpeech.mathToSpeech(m[1] ?? "") + " "
        }
        t = t.sub(#"\\\((.*?)\\\)"#) { m in
            " " + MathSpeech.mathToSpeech(m[1] ?? "") + " "
        }

        // ── L6: Accents + residual cleanup ──
        // Deviation (documented in Normalizer.swift): always the fallback
        // accent table; the reference prefers pylatexenc when installed.
        let accentFallback: [(String, String)] = [
            ("\\\"o", "ö"), ("\\\"u", "ü"), ("\\\"a", "ä"), ("\\'e", "é"), ("\\'a", "á"),
            ("\\'i", "í"), ("\\'o", "ó"), ("\\'u", "ú"), ("\\v{c}", "č"), ("\\v{s}", "š"),
            ("\\v{z}", "ž"), ("\\v{r}", "ř"), ("\\c{c}", "ç"), ("\\~n", "ñ"), ("\\~a", "ã"),
            ("\\^o", "ô"), ("\\^e", "ê"), ("\\^a", "â"), ("\\`e", "è"), ("\\`a", "à"),
            ("\\ss", "ß"), ("\\o", "ø"), ("\\O", "Ø"), ("\\aa", "å"), ("\\AA", "Å"),
            ("\\ae", "æ"), ("\\AE", "Æ"), ("\\l", "ł"), ("\\L", "Ł"),
        ]
        for (pat, repl) in accentFallback {
            t = t.replacingOccurrences(of: pat, with: repl)
        }
        t = t.replacingOccurrences(of: "\u{a0}", with: " ")
        // Strip residual backslash commands.
        t = t.sub(#"\\[a-zA-Z]+\*?(?:\[[^\]]*\])*(?:\{[^{}]*\})*"#, " ")
        t = t.sub(#"\\[^a-zA-Z\s]"#, " ")
        // Remaining braces.
        t = t.sub(#"[{}]"#, "")
        // Table separators.
        t = t.sub(#"(?<!\d)&(?!\d)"#, ", ")
        // Restore protected special characters.
        t = t.replacingOccurrences(of: "\u{01}", with: "&")
        t = t.replacingOccurrences(of: "\u{02}", with: "$")
        // Line breaks: single newlines are spaces, double are paragraphs.
        t = t.sub(#"\n{2,}"#, "\u{00}")
        t = t.sub(#"\n"#, " ")
        t = t.replacingOccurrences(of: "\u{00}", with: "\n\n")
        return t
    }
}
