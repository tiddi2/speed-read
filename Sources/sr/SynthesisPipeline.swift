import Foundation
import SRCore

/// Bounded-concurrency chunk synthesis (F-5) with cache-first lookup (C-4),
/// exact-cost + history-ID reporting, and cloud→local fallback (F-3 Auto).
///
/// At most `maxInFlight` chunks synthesize concurrently; results are
/// delivered as they complete and the playback engine schedules in order.
/// Chunk 0 is requested first so playback starts fast.
///
/// Fallback (ported from speak.sh): when the primary provider fails with a
/// fallback-trigger error (429 / 5xx / network) and a fallback provider is
/// configured, the failed chunk is retried on the fallback and all
/// subsequent chunks go straight there. Fallback is one-way, cloud→local —
/// never local→cloud (that would violate P-8 routing guarantees).
final class SynthesisPipeline: @unchecked Sendable {
    static let maxInFlight = 3
    /// Include the current sentence plus a small startup/latency cushion.
    static let maxBufferedChunks = 6

    @MainActor static func needsChunk(_ index: Int, currentSentence: Int,
                                     isPlaying: Bool) -> Bool {
        isPlaying && index < currentSentence + maxBufferedChunks
    }

    struct Route: Sendable {
        let provider: any TTSProvider
        let voiceID: String
        /// Modeled for cache keying; "" for providers without models.
        let modelID: String
        /// Language actually pinned on the request, for cache keying; "" when
        /// the provider was left to detect it from the text.
        let languageCode: String
        /// Anything else that changes the audio for identical text — today
        /// the pronunciation-dictionary version sent with the request (F-13).
        let variant: String

        init(provider: any TTSProvider, voiceID: String, modelID: String,
             languageCode: String = "", variant: String = "") {
            self.provider = provider
            self.voiceID = voiceID
            self.modelID = modelID
            self.languageCode = languageCode
            self.variant = variant
        }
    }

    struct Callbacks: Sendable {
        let deliver: @MainActor @Sendable (Int, Data) -> Void
        let billed: @Sendable (Int) -> Void
        let historyID: @Sendable (String) -> Void
        let fellBack: @MainActor @Sendable () -> Void
        let failed: @MainActor @Sendable (TTSError) -> Void
    }

    private var task: Task<Void, Never>?
    private var flights: SynthesisSingleFlight?

    func run(
        chunks: [Chunk],
        primary: Route,
        fallback: Route?,
        settings: VoiceSettings,
        cache: AudioCache?,
        cloudBudgetRemaining: Int? = nil,
        shouldSynthesize: (@MainActor @Sendable (Int) -> Bool)? = nil,
        callbacks: Callbacks
    ) {
        cancel()
        let errorFlag = OnceFlag()
        let fallbackFlag = OnceFlag()
        let useFallback = AtomicBool()
        let budget = AtomicBudget(remaining: cloudBudgetRemaining)
        let flights = SynthesisSingleFlight()
        self.flights = flights

        @Sendable func cacheKey(_ route: Route, _ chunk: Chunk) -> String {
            AudioCache.key(text: chunk.text, provider: route.provider.id,
                           voiceID: route.voiceID, modelID: route.modelID,
                           languageCode: route.languageCode,
                           variant: route.variant,
                           settings: settings)
        }

        @Sendable func synthesizeOn(_ route: Route, chunk: Chunk) async throws -> Data {
            try Task.checkCancellation()
            let key = cacheKey(route, chunk)
            if let cached = cache?.lookup(key) { return cached }

            return try await flights.value(for: key) {
                try Task.checkCancellation()
                // A sibling may have filled the cache while this task waited
                // for ownership of the single-flight operation.
                if let cached = cache?.lookup(key) { return cached }

                let reservation: Int?
                if route.provider.isLocal {
                    reservation = nil
                } else {
                    guard let claimed = budget.claim(chunk.text.count) else {
                        throw TTSError.budgetExceeded
                    }
                    reservation = claimed
                }

                let result: SynthesisResult
                do {
                    try Task.checkCancellation()
                    result = try await route.provider.synthesize(
                        text: chunk.text, voiceID: route.voiceID, settings: settings)
                } catch let error as TTSError {
                    if case .invalidAudio(let historyID, let billedCharacters) = error {
                        if let reservation {
                            let billed = max(billedCharacters ?? chunk.text.count, 0)
                            budget.settle(reservation: reservation, actual: billed)
                            callbacks.billed(billed)
                        }
                        if let historyID { callbacks.historyID(historyID) }
                    } else if let reservation {
                        budget.release(reservation)
                    }
                    throw error
                } catch {
                    if let reservation { budget.release(reservation) }
                    throw error
                }

                if let reservation {
                    // Missing billing headers must fail closed for budgeting:
                    // one credit per input character is the conservative bound.
                    let billed = max(result.billedCharacters ?? chunk.text.count, 0)
                    budget.settle(reservation: reservation, actual: billed)
                    callbacks.billed(billed)
                }
                if let historyID = result.remoteHistoryItemID {
                    callbacks.historyID(historyID)
                }
                cache?.store(key, data: result.audio)
                return result.audio
            }
        }

        @Sendable func synthesize(_ chunk: Chunk) async throws -> Void {
            // Bound *total* prepared audio, not only simultaneous requests.
            // A paused/slow listener must not pay to generate the whole article.
            if let shouldSynthesize {
                while !(await shouldSynthesize(chunk.id)) {
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            try Task.checkCancellation()
            var route = useFallback.value ? (fallback ?? primary) : primary
            let audio: Data
            do {
                audio = try await synthesizeOn(route, chunk: chunk)
            } catch let error as TTSError where error.isFallbackTrigger && fallback != nil && !route.provider.isLocal {
                // Flip to fallback for this and all subsequent chunks (T-7).
                useFallback.set(true)
                if fallbackFlag.trip() {
                    SRLog.event("pipeline.fallback", ["trigger": error.logCategory])
                    await MainActor.run { callbacks.fellBack() }
                }
                route = fallback!
                audio = try await synthesizeOn(route, chunk: chunk)
            }

            guard !Task.isCancelled else { return }
            await callbacks.deliver(chunk.id, audio)
        }

        task = Task {
            await withTaskGroup(of: Void.self) { group in
                var iterator = chunks.makeIterator()
                var active = 0

                func spawnNext() -> Bool {
                    guard let chunk = iterator.next() else { return false }
                    active += 1
                    group.addTask {
                        do {
                            try await synthesize(chunk)
                        } catch let error as TTSError {
                            guard !Task.isCancelled, error != .cancelled else { return }
                            if errorFlag.trip() {
                                await MainActor.run { callbacks.failed(error) }
                            }
                        } catch {
                            // Providers map their own cancellations to
                            // TTSError.cancelled; anything else that lands
                            // here (wire decode errors, unexpected throws)
                            // is a real failure. Swallowing it would leave
                            // the session waiting forever for a chunk that
                            // never arrives.
                            guard !Task.isCancelled, !(error is CancellationError) else { return }
                            if errorFlag.trip() {
                                SRLog.error("pipeline.chunk_failed",
                                            ["error": String(describing: type(of: error))])
                                await MainActor.run {
                                    callbacks.failed(.network(
                                        underlying: "synthesis failed: \(type(of: error))"))
                                }
                            }
                        }
                    }
                    return true
                }

                for _ in 0..<Self.maxInFlight {
                    if !spawnNext() { break }
                }
                while active > 0 {
                    await group.next()
                    active -= 1
                    if Task.isCancelled { group.cancelAll(); break }
                    _ = spawnNext()
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        flights?.cancelAll()
        flights = nil
    }
}

/// Thread-safe once-only latch for first-error reporting.
private final class OnceFlag: @unchecked Sendable {
    private var tripped = false
    private let lock = NSLock()

    /// Returns true exactly once.
    func trip() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if tripped { return false }
        tripped = true
        return true
    }
}

private final class AtomicBool: @unchecked Sendable {
    private var stored = false
    private let lock = NSLock()

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ newValue: Bool) {
        lock.lock()
        stored = newValue
        lock.unlock()
    }
}

/// Per-run conservative cloud-credit reservations. Reserving before a request
/// prevents the three concurrent workers from collectively crossing the cap.
private final class AtomicBudget: @unchecked Sendable {
    private var remaining: Int?
    private let lock = NSLock()

    init(remaining: Int?) {
        self.remaining = remaining.map { max($0, 0) }
    }

    func claim(_ amount: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        let amount = max(amount, 0)
        guard let available = remaining else { return amount }
        guard amount <= available else { return nil }
        remaining = available - amount
        return amount
    }

    func release(_ reservation: Int) {
        lock.lock()
        if let available = remaining { remaining = available + reservation }
        lock.unlock()
    }

    func settle(reservation: Int, actual: Int) {
        lock.lock()
        if let available = remaining {
            remaining = available + reservation - actual
        }
        lock.unlock()
    }
}

/// Deduplicates identical in-flight cache misses. Side effects live inside the
/// owner operation, so billing/history callbacks run exactly once.
/// Internal for cancellation regression tests.
final class SynthesisSingleFlight: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let task: Task<Data, Error>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var cancelled = false

    func value(
        for key: String,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        try Task.checkCancellation()
        let entry: Entry = try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            if let existing = entries[key] { return existing }
            let created = Entry(id: UUID(), task: Task { try await operation() })
            entries[key] = created
            return created
        }
        defer {
            lock.withLock {
                if entries[key]?.id == entry.id { entries[key] = nil }
            }
        }
        return try await entry.task.value
    }

    func cancelAll() {
        let tasks: [Task<Data, Error>] = lock.withLock {
            cancelled = true
            let tasks = entries.values.map(\.task)
            entries.removeAll()
            return tasks
        }
        for task in tasks { task.cancel() }
    }
}

extension TTSError: Equatable {
    public static func == (lhs: TTSError, rhs: TTSError) -> Bool {
        switch (lhs, rhs) {
        case (.missingAPIKey, .missingAPIKey),
             (.budgetExceeded, .budgetExceeded),
             (.cancelled, .cancelled):
            return true
        case (.invalidAudio(let ah, let ab), .invalidAudio(let bh, let bb)):
            return ah == bh && ab == bb
        case (.http(let a, _), .http(let b, _)):
            return a == b
        case (.network(let a), .network(let b)):
            return a == b
        default:
            return false
        }
    }
}
