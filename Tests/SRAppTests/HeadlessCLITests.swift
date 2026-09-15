import Foundation
import SRCore
import Testing
@testable import sr

private struct InvalidAudioCloudProvider: TTSProvider {
    let id = "invalid-cloud"
    let isLocal = false

    func voices() async throws -> [Voice] { [] }

    func synthesize(
        text: String, voiceID: String, settings: VoiceSettings
    ) async throws -> SynthesisResult {
        throw TTSError.invalidAudio(
            historyItemID: "history-invalid-audio",
            billedCharacters: 17)
    }
}

private struct SuccessfulLocalProvider: TTSProvider {
    let id = "local"
    let isLocal = true

    func voices() async throws -> [Voice] { [] }

    func synthesize(
        text: String, voiceID: String, settings: VoiceSettings
    ) async throws -> SynthesisResult {
        SynthesisResult(audio: Data([0x52, 0x49, 0x46, 0x46]))
    }
}

private final class PipelineCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var billedValues: [Int] = []
    private var historyIDs: [String] = []
    private var fallbackCount = 0

    func recordBilled(_ value: Int) {
        lock.withLock { billedValues.append(value) }
    }

    func recordHistory(_ value: String) {
        lock.withLock { historyIDs.append(value) }
    }

    func recordFallback() {
        lock.withLock { fallbackCount += 1 }
    }

    func snapshot() -> (billed: [Int], history: [String], fallbacks: Int) {
        lock.withLock { (billedValues, historyIDs, fallbackCount) }
    }
}

@Suite @MainActor struct HeadlessCLITests {
    @Test func noArgumentsLaunchesGUI() {
        #expect(HeadlessCLI.Mode(arguments: ["sr"]) == nil)
    }

    @Test func parsesPrivacyAndCostFlags() {
        let mode = HeadlessCLI.Mode(arguments: [
            "sr", "--speak", "article.md", "--local", "--override-cost-controls",
        ])
        guard case .speak(let source, let forceLocal, let overrideCostControls, _) = mode else {
            Issue.record("expected speak mode")
            return
        }
        #expect(source == "article.md")
        #expect(forceLocal)
        #expect(overrideCostControls)
    }

    @Test func missingSpeakOperandIsUsageError() {
        let mode = HeadlessCLI.Mode(arguments: ["sr", "--speak", "--local"])
        guard case .usage(let error) = mode else {
            Issue.record("expected usage error")
            return
        }
        #expect(error?.contains("requires a file path") == true)
    }

    @Test func unknownArgumentsDoNotLaunchGUI() {
        let mode = HeadlessCLI.Mode(arguments: ["sr", "--unknown"])
        guard case .usage(let error) = mode else {
            Issue.record("expected usage error")
            return
        }
        #expect(error?.contains("unrecognized arguments") == true)
    }
}

@Suite struct SynthesisSingleFlightTests {
    @Test func rejectsRegistrationAfterCancellation() async {
        let flights = SynthesisSingleFlight()
        flights.cancelAll()
        do {
            _ = try await flights.value(for: "late") { Data([1]) }
            Issue.record("cancelled registry accepted new synthesis work")
        } catch is CancellationError {
            // Expected: Stop/Local-Only permanently closes this run's table.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test @MainActor func invalidAudioAccountsAndDeletesBeforeLocalFallback() async {
        let pipeline = SynthesisPipeline()
        let recorder = PipelineCallbackRecorder()

        let delivered = await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            pipeline.run(
                chunks: [Chunk(id: 0, text: "test sentence", offset: 0)],
                primary: .init(
                    provider: InvalidAudioCloudProvider(),
                    voiceID: "cloud",
                    modelID: "cloud-model"),
                fallback: .init(
                    provider: SuccessfulLocalProvider(),
                    voiceID: "local",
                    modelID: "local-model"),
                settings: VoiceSettings(),
                cache: nil,
                cloudBudgetRemaining: 100,
                callbacks: .init(
                    deliver: { _, audio in continuation.resume(returning: audio) },
                    billed: { recorder.recordBilled($0) },
                    historyID: { recorder.recordHistory($0) },
                    fellBack: { recorder.recordFallback() },
                    failed: { _ in continuation.resume(returning: nil) }))
        }
        pipeline.cancel()

        let snapshot = recorder.snapshot()
        #expect(delivered == Data([0x52, 0x49, 0x46, 0x46]))
        #expect(snapshot.billed == [17])
        #expect(snapshot.history == ["history-invalid-audio"])
        #expect(snapshot.fallbacks == 1)
    }
}

@Suite struct RerenderWindowCursorTests {
    @Test func segmentsAppendedMidRerenderStayOrderedAndUnique() {
        var cursor = RerenderWindowCursor()
        cursor.begin(at: 0, firstOffset: 12)

        var scheduled: [Int] = []
        for _ in 0..<4 {
            scheduled.append(cursor.takeNext(existingSegmentCount: 6)!.index)
        }

        // Sentence 6 arrives while the first bounded window is playing.
        while let next = cursor.takeNext(existingSegmentCount: 7) {
            scheduled.append(next.index)
        }

        #expect(scheduled == Array(0..<7))
        #expect(cursor.isActive)
        #expect(cursor.takeNext(existingSegmentCount: 7) == nil)
        #expect(cursor.takeNext(existingSegmentCount: 8)?.index == 7)
    }
}
