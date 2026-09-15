@preconcurrency import AVFoundation
import Foundation
import SRCore

/// The sentence a voice audition speaks, per language.
///
/// Short on purpose — an audition is a cloud request like any other, and at
/// roughly seventy characters a whole afternoon of picking voices costs less
/// than one paragraph of real reading. Each language gets its own sentence
/// rather than a translation of one: what you are listening for is how the
/// voice handles that language's rhythm.
enum VoiceSample {
    static func text(for language: SpeechLanguage) -> String {
        switch language {
        case .english:
            return "This is how your selection will sound when sr reads it back to you."
        case .norwegian:
            return "Slik høres teksten du markerer ut når sr leser den høyt for deg."
        }
    }
}

/// One-shot audio previews for Settings: voice auditions and pronunciation
/// tests.
///
/// Deliberately not the PlaybackEngine. That engine owns a timeline — speed
/// stretching, sentence seeking, read-ahead — and a read in progress. A
/// preview is one short clip that must not disturb any of it, so it gets its
/// own `AVAudioPlayer` and its own stop button.
@MainActor
final class VoicePreviewer: NSObject, ObservableObject {
    /// Which row is busy, as an opaque token the caller invents (a voice ID,
    /// a rule ID) so several preview buttons can share one previewer without
    /// lighting up together.
    @Published private(set) var loadingToken: String?
    @Published private(set) var playingToken: String?
    @Published private(set) var failure: String?

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    func isLoading(_ token: String) -> Bool { loadingToken == token }
    func isPlaying(_ token: String) -> Bool { playingToken == token }
    func isBusy(_ token: String) -> Bool { isLoading(token) || isPlaying(token) }

    /// Start `token`, or stop it if it is the one already running. Any other
    /// preview is replaced — two voices talking over each other tells you
    /// nothing about either.
    func toggle(_ token: String,
                synthesize: @escaping @Sendable () async throws -> Data) {
        if isBusy(token) {
            stop()
            return
        }
        stop()
        failure = nil
        loadingToken = token
        task = Task { @MainActor [weak self] in
            do {
                let audio = try await synthesize()
                guard let self, !Task.isCancelled, self.loadingToken == token else { return }
                self.start(audio, token: token)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.loadingToken == token else { return }
                self.loadingToken = nil
                self.failure = Self.message(for: error)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        loadingToken = nil
        playingToken = nil
    }

    private func start(_ audio: Data, token: String) {
        loadingToken = nil
        guard let player = try? AVAudioPlayer(data: audio) else {
            failure = "That preview came back as something this Mac can't play."
            return
        }
        player.delegate = self
        self.player = player
        guard player.play() else {
            self.player = nil
            failure = "Could not start audio playback."
            return
        }
        playingToken = token
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? TTSError else { return "Preview failed." }
        switch error {
        case .missingAPIKey:
            return "No ElevenLabs API key — add one in Settings → Cost."
        case .http(401, _), .http(403, _):
            return "ElevenLabs auth failed — check your API key."
        case .http(402, _):
            return "That voice needs a paid ElevenLabs plan."
        case .http(429, _):
            return "ElevenLabs quota exceeded."
        case .http(let status, _):
            return "Preview failed (HTTP \(status))."
        case .invalidAudio:
            return "ElevenLabs returned invalid audio."
        case .network(let detail) where detail.hasPrefix("kokoro"):
            return "The offline voice is unavailable."
        case .network:
            return "Could not reach ElevenLabs."
        case .budgetExceeded:
            return "Daily cloud budget reached."
        case .cancelled:
            return "Preview cancelled."
        }
    }
}

extension VoicePreviewer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,
                                                 successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            self.playingToken = nil
        }
    }
}
