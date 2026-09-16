import Foundation
@testable import SRCore

// Foundation-touching helpers for DiagnosticsTests, isolated in a file that
// does NOT import Testing — same cross-import-overlay reason as
// KokoroTestSupport.
enum DiagnosticsTestSupport {
    static func withTempFile(
        _ contents: String?, _ body: (URL) throws -> Void
    ) rethrows {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-log-test-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        if let contents {
            try? Data(contents.utf8).write(to: url)
        }
        try body(url)
    }

    /// `tail` of a file that was never created.
    static func tailOfMissingFile() -> String {
        Diagnostics.tail(FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-log-test-absent-\(UUID().uuidString).log"))
    }

    static func tail(of contents: String, maxBytes: Int) -> String {
        var result = ""
        withTempFile(contents) { url in
            result = Diagnostics.tail(url, maxBytes: maxBytes)
        }
        return result
    }

    /// A log long enough to be cut, as (tail, lastLineWritten).
    static func tailOfOversizedLog(maxBytes: Int) -> (tail: String, lastLine: String) {
        let lines = (0..<4000).map { "2026-09-16T00:00:00Z line \($0) padding padding" }
        let last = lines[lines.count - 1]
        return (tail(of: lines.joined(separator: "\n") + "\n", maxBytes: maxBytes), last)
    }

    static func reportContains(selfTestOutput: String?) -> String {
        Diagnostics.report(selfTestOutput: selfTestOutput)
    }

    static func logFileIDs() -> [String] { Diagnostics.logFiles.map(\.id) }

    static func logFileNames() -> [String] {
        Diagnostics.logFiles.map(\.url.lastPathComponent)
    }
}
