import Testing
@testable import SRCore

// No Foundation import — see KokoroTestSupport for why the CLT toolchain
// cannot take the _Testing_Foundation overlay.

/// Settings → Logs is where someone goes when a read failed and the app has
/// already told them everything it is allowed to. It has to survive the state
/// the logs are actually in: absent, empty, or larger than the window.
@Suite struct DiagnosticsTests {
    @Test func aMissingLogSaysSoRatherThanShowingNothing() {
        #expect(DiagnosticsTestSupport.tailOfMissingFile() == "(nothing logged yet)")
    }

    @Test func anEmptyLogSaysSoToo() {
        #expect(DiagnosticsTestSupport.tail(of: "", maxBytes: 1024)
            == "(nothing logged yet)")
    }

    @Test func aShortLogIsShownWhole() {
        let tail = DiagnosticsTestSupport.tail(
            of: "first\nsecond\nthird\n", maxBytes: 1024)
        #expect(tail.contains("first"))
        #expect(tail.contains("third"))
        #expect(!tail.contains("omitted"))
    }

    /// The end is the part that matters: a failure is the last thing that
    /// happened, and a 5 MB file must not be loaded to reach it.
    @Test func anOversizedLogKeepsTheEndAndSaysItWasCut() {
        let (tail, lastLine) = DiagnosticsTestSupport
            .tailOfOversizedLog(maxBytes: 4096)
        #expect(tail.contains(lastLine))
        #expect(tail.contains("omitted"))
        #expect(!tail.contains("line 0 padding"))
        // Enough slack for the notice; nowhere near the whole file.
        #expect(tail.utf8.count < 4096 + 200)
    }

    /// Cutting mid-line would open the view on half a timestamp.
    @Test func theFirstPartialLineIsDropped() {
        let tail = DiagnosticsTestSupport.tailOfOversizedLog(maxBytes: 4096).tail
        let firstRealLine = tail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst().first ?? ""
        #expect(firstRealLine.hasPrefix("2026-"))
    }

    @Test func bothLogsAreOffered() {
        #expect(DiagnosticsTestSupport.logFileIDs() == ["app", "daemon"])
        #expect(DiagnosticsTestSupport.logFileNames() == ["sr.log", "kokoro.log"])
    }

    /// One paste has to carry everything, or it will arrive in three.
    @Test func theReportCarriesEveryLogAndTheSelfTest() {
        let report = DiagnosticsTestSupport.reportContains(
            selfTestOutput: "RuntimeError: [load_safetensors] Failed to open file")
        #expect(report.contains("# sr diagnostics"))
        #expect(report.contains("- macOS:"))
        #expect(report.contains("## Offline voice self-test"))
        #expect(report.contains("[load_safetensors]"))
        #expect(report.contains("## sr log"))
        #expect(report.contains("## Offline voice log"))
    }

    /// A self-test nobody ran must not leave an empty heading behind.
    @Test func theReportOmitsASelfTestThatNeverRan() {
        let report = DiagnosticsTestSupport.reportContains(selfTestOutput: nil)
        #expect(!report.contains("## Offline voice self-test"))
        #expect(report.contains("## sr log"))
    }
}
