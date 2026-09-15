@preconcurrency import AVFoundation
import Foundation
import SRCore

private final class ConverterInputState: @unchecked Sendable {
    var fed = false
}

/// Ordered cursor for a bounded seek/rate-change rerender. Keeping the cursor
/// active at the current tail lets segments decoded mid-rerender join the same
/// ordered stream instead of being scheduled early and then repeated.
struct RerenderWindowCursor {
    private(set) var nextSegmentIndex: Int?
    private var firstOffset: AVAudioFrameCount = 0

    var isActive: Bool { nextSegmentIndex != nil }

    mutating func begin(at index: Int, firstOffset: AVAudioFrameCount) {
        nextSegmentIndex = index
        self.firstOffset = firstOffset
    }

    mutating func takeNext(existingSegmentCount: Int)
        -> (index: Int, offset: AVAudioFrameCount)? {
        guard let index = nextSegmentIndex, index < existingSegmentCount else { return nil }
        let offset = firstOffset
        firstOffset = 0
        // Deliberately retain `existingSegmentCount` as the next index at the
        // current tail; a later decode can then be consumed in order.
        nextSegmentIndex = index + 1
        return (index, offset)
    }

    mutating func reset() {
        nextSegmentIndex = nil
        firstOffset = 0
    }
}

/// Timeline audio player with time-domain speed control and seeking
/// (F-7, F-8).
///
/// Speed is applied by stretching PCM with WSOLA (see TimeStretch) at
/// schedule time, not by a realtime phase-vocoder node — phase vocoders
/// (AVAudioUnitTimePitch) smear speech transients into a reverberant
/// "bright room" artifact at higher rates. The graph is therefore just
/// player → mixer in one canonical format (44.1 kHz mono float).
///
/// The content timeline (original 1.0× audio, inter-sentence silence baked
/// in) is kept verbatim; what's scheduled on the player is the stretched
/// rendering at the current rate. Rate changes and seeks re-render from
/// the current content position — segment by segment, off the main thread,
/// so the first re-rendered chunk is audible in tens of milliseconds.
///
/// Positions are tracked in content frames: the player consumes stretched
/// frames, so content position = baseFrame + playedFrames × renderRate.
/// ±5 s seeks therefore mean 5 content-seconds at any rate.
@MainActor
final class PlaybackEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case playing
        case paused
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSentence = 0
    @Published private(set) var totalSentences = 0
    @Published private(set) var currentSeconds: Double = 0
    @Published private(set) var availableSeconds: Double = 0

    var rate: Double {
        didSet {
            guard abs(rate - oldValue) > 0.001 else { return }
            scheduleRateChange()
        }
    }
    var sentencePauseMS: Int
    var onFinished: (() -> Void)?
    var onError: ((String) -> Void)?

    nonisolated static let sampleRate: Double = 44_100
    private let format = AVAudioFormat(
        standardFormatWithSampleRate: PlaybackEngine.sampleRate, channels: 1)!

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private struct Segment {
        let encodedAudio: Data
        let pauseFrames: AVAudioFrameCount
    }

    // Content timeline metadata + compressed source audio. PCM is decoded on
    // a worker for initial playback and on demand for seek/rate changes, so a
    // long read does not retain its entire uncompressed waveform in memory.
    private var segments: [Segment] = []
    private var segmentStartFrames: [AVAudioFramePosition] = []
    private var totalFrames: AVAudioFramePosition = 0
    private var pendingFeeds: [Int: Data] = [:]
    private var receivedCount = 0
    private var appendedCount = 0
    private var pendingDecodes = 0
    private var pendingRenders = 0
    private var rerenderCursor = RerenderWindowCursor()
    private let renderWindowSize = 4

    // Playback run state.
    private var renderRate: Double = 1.0                // rate of scheduled audio
    private var baseFrame: AVAudioFramePosition = 0     // content frame at run start
    private var pausedAtFrame: AVAudioFramePosition = 0
    private var outstandingBuffers = 0
    private var generation = 0
    private var sessionGeneration = 0
    private var uiTimer: Timer?
    private var engineStarted = false
    private var rateChangeWork: DispatchWorkItem?
    private var starvationPaused = false

    /// Serial chain so stretch+schedule ops run in timeline order even
    /// though the stretching happens off the main thread.
    private var chain: Task<Void, Never> = Task {}
    private var decodeChain: Task<Void, Never> = Task {}

    private var configObserver: NSObjectProtocol?

    init(rate: Double = 1.0, sentencePauseMS: Int = 400) {
        self.rate = rate
        self.sentencePauseMS = sentencePauseMS
        renderRate = rate

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Output configuration changes (AirPods profile/sample-rate switch,
        // device change) stop the engine and drop scheduled audio. Without
        // this handler playback "skips": silence until the next segment
        // schedule restarts the engine, losing everything queued in between.
        // Recover by re-rendering from the last known position.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func handleConfigurationChange() {
        guard isActive else { return }
        SRLog.event("playback.config_change", [:])
        // The engine is stopped; playerTime is gone. pausedAtFrame tracks the
        // last known position (updated 4×/s while playing), so resume there.
        rescheduleContent(from: pausedAtFrame)
    }

    var isActive: Bool { state != .idle }

    // MARK: - Session

    func startSession(totalSentences total: Int) {
        stop()
        generation += 1
        totalSentences = total
        renderRate = rate
        state = .playing
        startUITimer()
    }

    /// Deliver audio for sentence `index` (may arrive out of order; the
    /// timeline appends strictly in order).
    func feed(index: Int, audio: Data) {
        guard isActive else { return }
        pendingFeeds[index] = audio
        while let data = pendingFeeds[receivedCount] {
            let index = receivedCount
            pendingFeeds[index] = nil
            receivedCount += 1
            enqueueDecode(sentence: index, data: data)
        }
    }

    private func enqueueDecode(sentence index: Int, data: Data) {
        let pauseFrames = index == 0 ? 0 : AVAudioFrameCount(
            Double(sentencePauseMS) / 1000.0 * Self.sampleRate)
        let sessionGen = sessionGeneration
        let previous = decodeChain
        pendingDecodes += 1
        decodeChain = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            guard await MainActor.run(body: { self.sessionGeneration == sessionGen }) else { return }
            let block = await Task.detached(priority: .userInitiated) {
                Self.decodeBlock(data, pauseFrames: pauseFrames)
            }.value
            await MainActor.run {
                self.finishDecode(
                    sentence: index,
                    data: data,
                    pauseFrames: pauseFrames,
                    block: block,
                    sessionGeneration: sessionGen)
            }
        }
    }

    private func finishDecode(
        sentence index: Int,
        data: Data,
        pauseFrames: AVAudioFrameCount,
        block: AVAudioPCMBuffer?,
        sessionGeneration sessionGen: Int
    ) {
        guard sessionGen == sessionGeneration, isActive else { return }
        pendingDecodes = max(pendingDecodes - 1, 0)
        guard let block else {
            SRLog.error("playback.decode_failed", ["index": String(index)])
            failPlayback("Audio for sentence \(index + 1) could not be decoded.")
            return
        }

        segmentStartFrames.append(totalFrames)
        segments.append(Segment(
            encodedAudio: data,
            pauseFrames: pauseFrames))
        totalFrames += AVAudioFramePosition(block.frameLength)
        availableSeconds = Double(totalFrames) / Self.sampleRate
        appendedCount += 1

        if rerenderCursor.isActive {
            // A seek/rate rerender owns scheduling order until the session
            // ends. Its cursor will consume this newly appended segment.
            pumpRerenderWindow()
        } else {
            enqueueStretchAndSchedule(block, isFinal: index == totalSentences - 1)
        }
    }

    // MARK: - Transport (F-7)

    func pause() {
        guard state == .playing else { return }
        pausedAtFrame = currentFrame
        player.pause()
        starvationPaused = false
        state = .paused
        SRLog.event("playback.pause", [:])
    }

    func resume() {
        guard state == .paused else { return }
        state = .playing
        guard ensureEngineRunning() else { return }
        if outstandingBuffers > 0 {
            player.play()
            starvationPaused = false
        } else {
            // Stay clock-paused until the next decoded/rendered buffer lands.
            starvationPaused = true
        }
        SRLog.event("playback.resume", [:])
        // The last buffer's completion may have fired while paused (its
        // checkFinished no-ops on state != .playing) — re-check, or a
        // finished timeline resumes into eternal silence.
        checkFinished()
    }

    func togglePauseResume() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    func stop() {
        generation += 1
        sessionGeneration += 1
        chain = Task {}
        decodeChain = Task {}
        rateChangeWork?.cancel()
        rateChangeWork = nil
        uiTimer?.invalidate()
        uiTimer = nil
        if engineStarted {
            player.stop()
            // Release the output audio unit / device claim: a menu-bar app
            // idles most of the time and shouldn't stay an active audio
            // client (power drain; can pin AirPods in the call profile).
            engine.stop()
            engineStarted = false
        }
        segments.removeAll()
        segmentStartFrames.removeAll()
        pendingFeeds.removeAll()
        totalFrames = 0
        receivedCount = 0
        appendedCount = 0
        pendingDecodes = 0
        pendingRenders = 0
        rerenderCursor.reset()
        baseFrame = 0
        pausedAtFrame = 0
        outstandingBuffers = 0
        starvationPaused = false
        currentSentence = 0
        totalSentences = 0
        currentSeconds = 0
        availableSeconds = 0
        state = .idle
    }

    /// Seek by ±seconds of content time, clamped to decoded audio.
    func seek(by deltaSeconds: Double) {
        guard isActive else { return }
        let delta = AVAudioFramePosition(deltaSeconds * Self.sampleRate)
        rescheduleContent(from: currentFrame + delta)
        SRLog.event("playback.seek", ["delta_s": String(Int(deltaSeconds))])
    }

    /// Jump whole sentences: -1 = previous, +1 = next. Clamped to the
    /// sentences already decoded (forward) and to the first one (backward).
    ///
    /// "Previous" behaves like a music player's previous-track button: past
    /// `sentenceRestartGrace` into a sentence it restarts that sentence (the
    /// common "say that again"), and only jumps to the one before when pressed
    /// near its start.
    func seekSentence(by delta: Int) {
        guard isActive, !segments.isEmpty, delta != 0 else { return }
        let frame = currentFrame
        guard let index = segmentIndex(containing: frame) else { return }

        var target = index + delta
        if delta < 0 {
            let elapsed = Double(frame - sentenceStartFrame(index)) / Self.sampleRate
            // Re-listening to the current sentence consumes the first step.
            if elapsed >= Self.sentenceRestartGrace { target += 1 }
        }
        let clamped = min(max(target, 0), segments.count - 1)
        // Only a backward step may land on the current sentence (restarting
        // it). Forward, clamping to the last decoded sentence must not turn
        // "next" into a jump backwards while the read-ahead catches up.
        guard delta < 0 || clamped > index else { return }
        SRLog.event("playback.seek_sentence", [
            "delta": String(delta),
            "to": String(clamped),
        ])
        rescheduleContent(from: sentenceStartFrame(clamped))
    }

    /// Seconds into a sentence after which "previous" restarts it instead of
    /// stepping back one.
    private static let sentenceRestartGrace: Double = 1.5

    /// First audible frame of sentence `index` — past the inter-sentence pause
    /// baked into the segment, so a jump starts on speech, not on silence.
    private func sentenceStartFrame(_ index: Int) -> AVAudioFramePosition {
        segmentStartFrames[index] + AVAudioFramePosition(segments[index].pauseFrames)
    }

    /// Restart from the top.
    func restart() {
        guard isActive else { return }
        rescheduleContent(from: 0)
    }

    // MARK: - Rendering

    /// Debounced so slider drags don't trigger a re-render per tick.
    private func scheduleRateChange() {
        guard isActive else {
            renderRate = rate
            return
        }
        rateChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isActive else { return }
                self.rescheduleContent(from: self.currentFrame)
            }
        }
        rateChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Stop the player and re-render + re-schedule everything from `target`
    /// (content frames) at the current rate. Used by seek, restart, and
    /// rate changes; also safe while paused (stays paused at the new spot).
    private func rescheduleContent(from target: AVAudioFramePosition) {
        guard totalFrames > 0 else {
            // No audio yet, but the requested rate must still take effect —
            // otherwise every segment appended before the first decode plays
            // at the session-start rate until the next seek/rate change.
            renderRate = rate
            return
        }
        let clamped = min(max(0, target), totalFrames - 1)

        generation += 1          // invalidate stale completions and chain ops
        chain = Task {}
        pendingRenders = 0
        player.stop()            // clears queue; playerTime resets
        outstandingBuffers = 0
        starvationPaused = state == .playing
        renderRate = rate
        baseFrame = clamped
        pausedAtFrame = clamped

        guard let startSegment = segmentIndex(containing: clamped) else { return }
        rerenderCursor.begin(
            at: startSegment,
            firstOffset: AVAudioFrameCount(clamped - segmentStartFrames[startSegment]))
        pumpRerenderWindow()
        updateUIPosition()
    }

    /// Keep only a small decoded/rendered window ahead of the playhead. A
    /// seek or rate change on a long read must not decode every remaining
    /// compressed segment at once.
    private func pumpRerenderWindow() {
        while pendingRenders + outstandingBuffers < renderWindowSize,
              let next = rerenderCursor.takeNext(existingSegmentCount: segments.count) {
            enqueueSegmentRender(segments[next.index], offset: next.offset,
                                 isFinal: next.index == totalSentences - 1)
        }
    }

    /// Re-decode a compressed segment for seek/rate-change rendering. This is
    /// intentionally in the serial render chain so timeline order is stable.
    private func enqueueSegmentRender(_ segment: Segment, offset: AVAudioFrameCount, isFinal: Bool) {
        let gen = generation
        let rate = renderRate
        let previous = chain
        pendingRenders += 1
        chain = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            guard await MainActor.run(body: { self.generation == gen }) else { return }
            let rendered: AVAudioPCMBuffer? = await Task.detached(priority: .userInitiated) {
                () -> AVAudioPCMBuffer? in
                guard let block = Self.decodeBlock(
                    segment.encodedAudio, pauseFrames: segment.pauseFrames),
                      let partial = Self.slice(block, from: offset) else { return nil }
                return TimeStretch.stretch(partial, rate: rate)
            }.value
            await MainActor.run {
                self.finishRender(rendered, generation: gen, isFinal: isFinal)
            }
        }
    }

    /// Append a stretch+schedule op to the serial chain. Stretching runs
    /// off the main actor; scheduling hops back and is generation-guarded.
    private func enqueueStretchAndSchedule(_ buffer: AVAudioPCMBuffer, isFinal: Bool) {
        let gen = generation
        let rate = renderRate
        let previous = chain
        pendingRenders += 1
        chain = Task { [weak self] in
            await previous.value
            guard let self, !Task.isCancelled else { return }
            // Bail before stretching, not just before scheduling: stop() and
            // reschedules orphan this chain, and WSOLA on a long article is
            // real CPU spent on audio the generation guard would discard.
            guard await MainActor.run(body: { self.generation == gen }) else { return }
            let stretched = await Task.detached(priority: .userInitiated) {
                TimeStretch.stretch(buffer, rate: rate)
            }.value
            await MainActor.run {
                self.finishRender(stretched, generation: gen, isFinal: isFinal)
            }
        }
    }

    private func finishRender(_ buffer: AVAudioPCMBuffer?, generation gen: Int, isFinal: Bool) {
        guard gen == generation, isActive else { return }
        pendingRenders = max(pendingRenders - 1, 0)
        guard let buffer else {
            failPlayback("Audio could not be decoded while seeking.")
            return
        }
        scheduleStretched(buffer, generation: gen, isFinal: isFinal)
    }

    private func scheduleStretched(_ buffer: AVAudioPCMBuffer, generation gen: Int, isFinal: Bool) {
        guard gen == generation, isActive else { return }
        guard ensureEngineRunning() else { return }
        outstandingBuffers += 1
        // Refill/freeze the content clock as soon as non-final audio renders.
        // Only the final buffer waits for device latency; its completion may
        // stop the engine, so an earlier callback would truncate the tail.
        let completionType: AVAudioPlayerNodeCompletionCallbackType = isFinal ? .dataPlayedBack : .dataRendered
        player.scheduleBuffer(buffer, completionCallbackType: completionType) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == gen else { return }
                self.outstandingBuffers -= 1
                self.pumpRerenderWindow()
                if self.outstandingBuffers == 0,
                   !PlaybackCompletionPolicy.canFinish(
                    totalSentences: self.totalSentences,
                    appendedSentences: self.appendedCount,
                    pendingDecodes: self.pendingDecodes,
                    pendingRenders: self.pendingRenders,
                    scheduledBuffers: self.outstandingBuffers) {
                    self.pausedAtFrame = self.currentFrame
                    self.player.pause()
                    self.starvationPaused = true
                }
                self.checkFinished()
            }
        }
        if state == .playing, !player.isPlaying {
            player.play()
            starvationPaused = false
        }
    }

    // MARK: - Position

    private var currentFrame: AVAudioFramePosition {
        guard state == .playing,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            return pausedAtFrame
        }
        let contentAdvance = AVAudioFramePosition(
            Double(playerTime.sampleTime) * renderRate)
        return min(baseFrame + contentAdvance, totalFrames)
    }

    private func segmentIndex(containing frame: AVAudioFramePosition) -> Int? {
        guard !segmentStartFrames.isEmpty else { return nil }
        var low = 0
        var high = segmentStartFrames.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segmentStartFrames[mid] <= frame { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateUIPosition()
            }
        }
    }

    private func updateUIPosition() {
        let frame = currentFrame
        currentSeconds = Double(frame) / Self.sampleRate
        if let index = segmentIndex(containing: frame) {
            currentSentence = index
        }
        // Keep the fallback position fresh: it's the resume point after an
        // engine configuration change, when playerTime is unavailable.
        if state == .playing {
            pausedAtFrame = frame
        }
    }

    private func checkFinished() {
        guard state == .playing,
              PlaybackCompletionPolicy.canFinish(
                totalSentences: totalSentences,
                appendedSentences: appendedCount,
                pendingDecodes: pendingDecodes,
                pendingRenders: pendingRenders,
                scheduledBuffers: outstandingBuffers) else { return }
        let n = totalSentences
        stop()
        SRLog.event("playback.finished", ["sentences": String(n)])
        onFinished?()
    }

    // MARK: - Engine / decode

    @discardableResult
    private func ensureEngineRunning() -> Bool {
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            engineStarted = true
            return true
        } catch {
            SRLog.error("playback.engine_start", ["error": String(describing: error)])
            failPlayback("The audio output device could not be started.")
            return false
        }
    }

    private func failPlayback(_ message: String) {
        let callback = onError
        stop()
        callback?(message)
    }

    /// Decode MP3/WAV Data → canonical 44.1 kHz mono float buffer.
    private nonisolated static func decode(_ data: Data) -> AVAudioPCMBuffer? {
        // AVAudioFile needs a URL; write to a private temp file with a
        // random name (never content-derived), delete immediately after.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-\(UUID().uuidString).audio")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url, options: .completeFileProtection)
            let file = try AVAudioFile(forReading: url)
            guard let raw = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
            try file.read(into: raw)
            guard let target = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: 1) else { return nil }
            return convert(raw, to: target)
        } catch {
            SRLog.error("playback.decode", ["error": String(describing: type(of: error))])
            return nil
        }
    }

    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        to target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: target) else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let inputState = ConverterInputState()
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if inputState.fed {
                status.pointee = .endOfStream
                return nil
            }
            inputState.fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    private nonisolated static func silence(
        _ count: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard count > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let data = buffer.floatChannelData else {
            return nil
        }
        data[0].initialize(repeating: 0, count: Int(count))
        buffer.frameLength = count
        return buffer
    }

    /// nil-tolerant concatenation in the canonical format.
    private nonisolated static func concat(
        _ a: AVAudioPCMBuffer?,
        _ b: AVAudioPCMBuffer?
    ) -> AVAudioPCMBuffer? {
        guard let b else { return a }
        guard let a else { return b }
        let total = a.frameLength + b.frameLength
        guard a.format == b.format,
              let out = AVAudioPCMBuffer(pcmFormat: a.format, frameCapacity: total),
              let outData = out.floatChannelData,
              let aData = a.floatChannelData,
              let bData = b.floatChannelData else { return nil }
        outData[0].update(from: aData[0], count: Int(a.frameLength))
        (outData[0] + Int(a.frameLength)).update(from: bData[0], count: Int(b.frameLength))
        out.frameLength = total
        return out
    }

    private nonisolated static func slice(
        _ buffer: AVAudioPCMBuffer,
        from offset: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength else { return nil }
        let length = buffer.frameLength - offset
        guard let out = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: length),
              let outData = out.floatChannelData,
              let inData = buffer.floatChannelData else { return nil }
        outData[0].update(from: inData[0] + Int(offset), count: Int(length))
        out.frameLength = length
        return out
    }

    private nonisolated static func decodeBlock(
        _ data: Data,
        pauseFrames: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let content = decode(data) else { return nil }
        return concat(silence(pauseFrames, format: content.format), content) ?? content
    }
}
