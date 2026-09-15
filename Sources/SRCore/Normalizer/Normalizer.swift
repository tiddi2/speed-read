import Foundation

/// Text normalization for TTS (F-4).
///
/// Swift port of Speak11's normalize.py (reference/normalize.py):
/// source detection → format-specific front-end → shared back-end.
/// Parity-tested against the reference implementation (T-4).
///
/// Intentional deviations from the reference (documented per T-4):
/// - No ftfy mojibake repair in the PDF front-end (clipboard text on
///   modern macOS is valid UTF-8; ftfy has no Swift equivalent).
/// - LaTeX accent handling uses the reference's fallback table rather
///   than pylatexenc.
public enum Normalizer {
    public enum Frontend: String {
        case latex, markdown, pdf
    }

    public static func detectFrontend(_ text: String) -> Frontend {
        if isLatex(text) { return .latex }
        if isMarkdown(text) { return .markdown }
        return .pdf
    }

    /// Full pipeline: front-end + shared back-end phases 0/A/B/C/D.
    ///
    /// `language` selects the words the pipeline injects (percent, logic
    /// connectives, abbreviation expansions — see `NormalizerLexicon`).
    /// It defaults to `.english`, which is the T-4 parity baseline.
    public static func normalize(_ text: String,
                                 language: SpeechLanguage = .english) -> String {
        let lexicon = NormalizerLexicon.forLanguage(language)
        let frontend = detectFrontend(text)
        var t: String
        switch frontend {
        case .latex: t = frontendLatex(text, lexicon)
        case .markdown: t = frontendMarkdown(text)
        case .pdf: t = frontendPDF(text)
        }
        t = phase0(t)
        t = phaseA(t)
        t = phaseB(t, lexicon)
        t = phaseC(t, lexicon)
        t = phaseD(t)
        return t
    }
}
