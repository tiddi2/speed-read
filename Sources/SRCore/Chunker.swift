import Foundation
import NaturalLanguage

/// A sentence chunk with its position in the normalized text (F-5).
public struct Chunk: Sendable, Identifiable {
    public let id: Int          // 0-based sentence index
    public let text: String
    public let offset: Int      // character offset in the normalized text

    public init(id: Int, text: String, offset: Int) {
        self.id = id
        self.text = text
        self.offset = offset
    }
}

/// Sentence segmentation via NLTokenizer, with merging of very short
/// fragments (initials, list numbers) into their successor so we don't
/// pay per-request overhead on 3-character chunks.
public enum Chunker {
    public static let minChunkLength = 8
    public static let maxChunkLength = 5_000
    public static let maxReadCharacters = 250_000

    public static func split(_ text: String) -> [Chunk] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var raw: [(text: String, offset: Int)] = []
        // Accumulate offsets from the previous sentence boundary: measuring
        // each from startIndex is an O(n) walk per sentence (O(n²) on
        // book-length input — seconds of CPU before synthesis starts).
        var cursor = text.startIndex
        var cursorOffset = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            // A line break is a boundary even without punctuation (headings,
            // list items, verse): NLTokenizer would otherwise run such lines
            // together into one sentence.
            var lineStart = range.lowerBound
            while lineStart < range.upperBound {
                let lineEnd = text[lineStart..<range.upperBound]
                    .firstIndex(where: { $0.isNewline }) ?? range.upperBound
                let line = String(text[lineStart..<lineEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    let leading = text[lineStart..<lineEnd].prefix(while: { $0.isWhitespace }).count
                    cursorOffset += text.distance(from: cursor, to: lineStart) + leading
                    cursor = text.index(lineStart, offsetBy: leading)
                    raw.append((line, cursorOffset))
                }
                lineStart = lineEnd < range.upperBound ? text.index(after: lineEnd) : lineEnd
            }
            return true
        }

        // Bound pathological sentences (minified text, giant URLs, OCR without
        // punctuation) before they reach provider/request-size limits.
        let bounded = raw.flatMap(splitLongPiece)

        // Merge fragments shorter than minChunkLength into the next sentence.
        var merged: [(text: String, offset: Int)] = []
        for piece in bounded {
            if let last = merged.last, last.text.count < minChunkLength,
               last.text.count + 1 + piece.text.count <= maxChunkLength {
                merged[merged.count - 1] = (last.text + " " + piece.text, last.offset)
            } else {
                merged.append(piece)
            }
        }

        return merged.enumerated().map { index, piece in
            Chunk(id: index, text: piece.text, offset: piece.offset)
        }
    }

    private static func splitLongPiece(
        _ piece: (text: String, offset: Int)
    ) -> [(text: String, offset: Int)] {
        guard piece.text.count > maxChunkLength else { return [piece] }

        var result: [(text: String, offset: Int)] = []
        var remainder = piece.text[...]
        var consumed = 0

        while remainder.count > maxChunkLength {
            let hardEnd = remainder.index(remainder.startIndex, offsetBy: maxChunkLength)
            let candidate = remainder[..<hardEnd]
            let cut = candidate.lastIndex(where: { $0.isWhitespace }) ?? hardEnd
            let rawPart = remainder[..<cut]
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            if !part.isEmpty {
                let leading = rawPart.prefix(while: { $0.isWhitespace }).count
                result.append((part, piece.offset + consumed + leading))
            }

            let cutDistance = remainder.distance(from: remainder.startIndex, to: cut)
            remainder = remainder[cut...]
            let whitespace = remainder.prefix(while: { $0.isWhitespace }).count
            remainder = remainder.dropFirst(whitespace)
            consumed += cutDistance + whitespace
        }

        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            let leading = remainder.prefix(while: { $0.isWhitespace }).count
            result.append((tail, piece.offset + consumed + leading))
        }
        return result
    }
}
