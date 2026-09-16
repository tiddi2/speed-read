import AVFoundation
import Foundation
import SRCore

/// Records a short reference clip through the default input device.
///
/// Deliberately small: it captures straight to the 24 kHz mono the model
/// conditions on, so the clip that reaches F5VoiceStore needs no resampling
/// and what the reader hears back is what the model will hear. The store
/// still runs its own conversion and length checks — one place decides what a
/// valid reference is, and it is not this one.
///
/// Nothing here leaves the Mac, and the file lives in a temp directory until
/// the reader chooses to keep it.
@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    /// A forgotten recording should not run until the disk fills. Well past
    /// the longest script, and past the store's own 12 s trim.
    static let maxSeconds: TimeInterval = 30

    enum Permission: Equatable {
        case unknown, granted, denied
    }

    @Published private(set) var isRecording = false
    @Published private(set) var isPlayingBack = false
    /// 0…1 for the level meter, so the reader can see the mic is live.
    @Published private(set) var level: Double = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var recordedURL: URL?
    @Published private(set) var permission: Permission = .unknown
    @Published var failure: String?

    /// Loudest moment seen while recording, in dBFS. Drives the "that was
    /// very quiet" nudge, which is the single most common reason a reference
    /// clip clones badly.
    private(set) var peakDecibels: Float = -160

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var meterTask: Task<Void, Never>?
    private let directory: URL

    override init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-voice-recording-\(UUID().uuidString)",
                                    isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    /// Delete the working directory. The kept clip has already been copied
    /// into the voice store by then.
    func discardAll() {
        stop()
        stopPlayback()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Permission

    func refreshPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = .granted
        case .denied, .restricted: permission = .denied
        default: permission = .unknown
        }
    }

    /// Ask for the microphone. macOS only shows its prompt once ever; after a
    /// denial the answer has to be changed in System Settings, which is what
    /// the UI says when this leaves `permission` at `.denied`.
    func requestPermission() async {
        refreshPermission()
        guard permission == .unknown else { return }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        permission = granted ? .granted : .denied
    }

    // MARK: - Recording

    func start() async {
        await requestPermission()
        guard permission == .granted else {
            failure = "sr needs microphone access. Allow it in System Settings → "
                + "Privacy & Security → Microphone, then try again."
            return
        }
        stopPlayback()
        failure = nil
        peakDecibels = -160
        duration = 0
        level = 0

        let url = directory.appendingPathComponent("take-\(UUID().uuidString).wav")
        do {
            // Captured at the model's own rate and channel count, so nothing
            // is resampled between the reader's ears and the model's.
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: F5VoiceStore.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record() else {
                failure = "Could not start recording. Check the input device in "
                    + "System Settings → Sound."
                return
            }
            self.recorder = recorder
            recordedURL = nil
            isRecording = true
            startMetering()
        } catch {
            failure = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stop() {
        meterTask?.cancel()
        meterTask = nil
        guard let recorder, recorder.isRecording else { return }
        duration = recorder.currentTime
        recorder.stop()
        recordedURL = recorder.url
        isRecording = false
        level = 0
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let recorder = self.recorder, recorder.isRecording
                else { return }
                recorder.updateMeters()
                self.level = Self.normalizedLevel(recorder.averagePower(forChannel: 0))
                self.peakDecibels = max(self.peakDecibels,
                                        recorder.peakPower(forChannel: 0))
                self.duration = recorder.currentTime
                if self.duration >= Self.maxSeconds {
                    self.stop()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    // MARK: - Playback

    func playBack() {
        guard let recordedURL else { return }
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: recordedURL)
            player.delegate = self
            player.play()
            self.player = player
            isPlayingBack = true
        } catch {
            failure = "Could not play that back: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        isPlayingBack = false
    }

    // MARK: - Assessment

    /// What to tell the reader about the take they just made, or nil when it
    /// looks fine. Checked here rather than at synthesis time because this is
    /// the last moment anyone can do anything about it.
    var advice: String? {
        guard recordedURL != nil else { return nil }
        if duration < 3 {
            return "That was under three seconds — read the whole script so the "
                + "voice has enough to go on."
        }
        if peakDecibels < -30 {
            return "That came out very quiet. Move closer to the microphone, or "
                + "check the input device in System Settings → Sound."
        }
        if peakDecibels > -1.0 {
            return "That clipped the input. Move back a little and read at a "
                + "normal speaking volume."
        }
        return nil
    }

    /// dBFS to a 0…1 meter reading.
    ///
    /// Linear amplitude would spend almost the whole bar on the loudest few
    /// dB and show nothing for ordinary speech, so the scale is dB, clamped to
    /// the 50 dB below full scale that a voice actually occupies.
    nonisolated static func normalizedLevel(_ decibels: Float) -> Double {
        let floor: Double = -50
        let value = Double(decibels)
        guard value.isFinite else { return 0 }
        return min(max((value - floor) / -floor, 0), 1)
    }
}

extension VoiceRecorder: AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder, successfully flag: Bool
    ) {
        Task { @MainActor in
            self.isRecording = false
            if !flag { self.failure = "The recording did not finish cleanly." }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor in self.isPlayingBack = false }
    }
}
