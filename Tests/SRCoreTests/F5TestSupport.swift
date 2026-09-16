import AVFoundation
import Foundation
@testable import SRCore

// Foundation-touching helpers for F5Tests, isolated in a file that does NOT
// import Testing — same cross-import-overlay reason as KokoroTestSupport.
enum F5TestSupport {
    static func tempPaths() throws -> (paths: F5Paths, cleanup: () -> Void) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-f5-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return (F5Paths(base: temp), { try? FileManager.default.removeItem(at: temp) })
    }

    static func derivedPaths(base: String) -> (weights: String, vocab: String,
                                               vocoder: String, voices: String) {
        let p = F5Paths(base: URL(fileURLWithPath: base))
        return (p.weights.path, p.vocab.path, p.vocoderWeights.path, p.voicesDir.path)
    }

    static func standardBasePath() -> String { F5Paths.standard.base.path }

    // MARK: - Architecture

    /// The daemon reads these keys out of SR_F5_ARCH, so the JSON spelling is
    /// a contract with sr_tts_server.py, not an implementation detail.
    static func archEnvironmentKeys() -> [String] {
        let json = F5Installer.Arch.f5Base.environmentJSON
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return object.keys.sorted()
    }

    /// (textMaskPadding, peAttnHead) after switching to `variant`.
    static func applied(_ variant: F5Installer.Variant) -> (Bool, Int?) {
        let arch = F5Installer.Arch.f5Base.applying(variant)
        return (arch.textMaskPadding, arch.peAttnHead)
    }

    // MARK: - Manifest

    static func writeManifest(_ paths: F5Paths, weightsBytes: Int) throws {
        let manifest = F5Installer.Manifest(
            modelRepo: F5Installer.modelRepo,
            modelRevision: "0123456789abcdef0123456789abcdef01234567",
            weightsSource: "model_last.safetensors",
            weightsSHA256: String(repeating: "a", count: 64),
            weightsBytes: weightsBytes,
            vocabSHA256: String(repeating: "b", count: 64),
            vocoderRepo: F5Installer.vocoderRepo,
            vocoderSHA256: String(repeating: "c", count: 64),
            requirementsLockSHA256: LocalRuntimeInstaller.requirementsLockSHA256,
            arch: .f5Base,
            archSource: nil,
            installedAt: Date(timeIntervalSince1970: 1_780_000_000))
        try JSONEncoder().encode(manifest).write(to: paths.manifest)
    }

    /// Lay down the four files a validated install must have.
    static func writeModelFiles(_ paths: F5Paths, weights: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.modelDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: paths.vocoderDir, withIntermediateDirectories: true)
        try weights.write(to: paths.weights)
        try Data("a\nb\n".utf8).write(to: paths.vocab)
        try Data("vocoder".utf8).write(to: paths.vocoderWeights)
        try Data("config".utf8).write(to: paths.vocoderConfig)
    }

    /// Returns (validatesWhenIntact, validatesAfterTruncation).
    static func manifestValidation() throws -> (Bool, Bool) {
        let (paths, cleanup) = try tempPaths()
        defer { cleanup() }
        let weights = Data(repeating: 7, count: 4096)
        try writeModelFiles(paths, weights: weights)
        try writeManifest(paths, weightsBytes: weights.count)
        let installer = F5Installer(paths: paths)
        let intact = (try? installer.loadValidatedManifest()) != nil
        try Data(repeating: 7, count: 8).write(to: paths.weights)
        let truncated = (try? installer.loadValidatedManifest()) != nil
        return (intact, truncated)
    }

    // MARK: - Fetch report

    /// Decode the exact shape sr_f5_fetch.py writes. Returns
    /// (revision, weightsSource, peAttnHead, referenceText).
    static func decodeFetchReport() throws -> (String, String, Int?, String?) {
        let json = """
        {
          "arch": {"conv_layers": 4, "depth": 22, "dim": 1024, "ff_mult": 2,
                   "heads": 16, "pe_attn_head": 1, "text_dim": 512,
                   "text_mask_padding": false},
          "arch_source": "config.yaml",
          "model_sha256": "aa",
          "reference": {"audio": "/tmp/ref.wav", "text": "Hei og hallo."},
          "repo": "akhbar/F5_Norwegian",
          "revision": "deadbeef",
          "vocab_sha256": "bb",
          "vocoder_sha256": "cc",
          "weights_source": "model_last.safetensors"
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-f5-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        let report = try FetchReport.load(from: url)
        return (report.revision, report.weightsSource,
                report.arch?.peAttnHead, report.reference?.text)
    }

    /// A v1 config has no `pe_attn_head`, which must decode as "all heads".
    static func decodeV1FetchReportVariant() throws -> F5Installer.Variant? {
        let json = """
        {"arch": {"conv_layers": 4, "depth": 22, "dim": 1024, "ff_mult": 2,
                  "heads": 16, "pe_attn_head": null, "text_dim": 512,
                  "text_mask_padding": true},
         "model_sha256": "a", "revision": "r", "vocab_sha256": "b",
         "vocoder_sha256": "c", "weights_source": "w.safetensors"}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-f5-report-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        return try FetchReport.load(from: url).arch?.variant
    }

    // MARK: - Download progress

    /// Feed the fetcher's exact progress JSON through the installer's reader.
    ///
    /// Flattened into three fields rather than an optional tuple so the tests
    /// never have to reach through two layers of Optional to assert on a
    /// fraction that is itself optional.
    static func readProgress(_ json: String) throws
        -> (found: Bool, message: String, fraction: Double?) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-f5-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        guard let stage = F5Installer.readProgress(at: url) else {
            return (false, "", nil)
        }
        return (true, stage.message, stage.fraction)
    }

    // MARK: - Voice store

    /// Minimal 16-bit mono WAV of `seconds` at `rate`, quiet but not silent.
    static func makeWAV(seconds: Double, rate: Int) -> Data {
        let frames = Int(seconds * Double(rate))
        var samples = Data(capacity: frames * 2)
        for index in 0..<frames {
            let value = Int16(8000 * sin(2 * Double.pi * 220 * Double(index) / Double(rate)))
            samples.append(UInt8(truncatingIfNeeded: value))
            samples.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func le32(_ value: Int) -> Data {
            Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        func le16(_ value: Int) -> Data {
            Data((0..<2).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
        }
        var wav = Data("RIFF".utf8)
        wav += le32(36 + samples.count)
        wav += Data("WAVEfmt ".utf8)
        wav += le32(16) + le16(1) + le16(1)
        wav += le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        wav += Data("data".utf8) + le32(samples.count)
        wav += samples
        return wav
    }

    /// Duration of a stored reference clip, read back through the same
    /// framework that wrote it rather than inferred from the byte count —
    /// a WAV header is not a fixed 44 bytes.
    static func storedSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }

    static func storedSampleRate(_ url: URL) throws -> Double {
        try AVAudioFile(forReading: url).fileFormat.sampleRate
    }

    /// Import a generated clip and read it back.
    /// Returns (id, name, transcript, fingerprintLength, seconds, sampleRate).
    static func importRoundTrip() throws -> (String, String, String, Int, Double, Double) {
        let (paths, cleanup) = try tempPaths()
        defer { cleanup() }
        let source = paths.base.appendingPathComponent("source.wav")
        // 44.1 kHz on purpose: the store must resample, because the daemon
        // refuses anything that is not 24 kHz.
        try makeWAV(seconds: 4, rate: 44_100).write(to: source)

        let store = F5VoiceStore(paths: paths)
        let added = try store.importVoice(
            name: "Min Stemme!", audio: source, transcript: "  Hei og hallo.  ")
        guard let loaded = store.voice(id: added.id) else {
            throw InstallError(message: "voice did not round-trip")
        }
        let stored = store.directory(for: added.id).appendingPathComponent("ref.wav")
        return (loaded.id, loaded.name, loaded.transcript, loaded.fingerprint.count,
                try storedSeconds(stored), try storedSampleRate(stored))
    }

    /// A clip longer than the cap is trimmed, not rejected.
    /// Returns the stored duration in seconds.
    static func importTrimsLongClip() throws -> Double {
        let (paths, cleanup) = try tempPaths()
        defer { cleanup() }
        let source = paths.base.appendingPathComponent("long.wav")
        try makeWAV(seconds: 40, rate: 24_000).write(to: source)
        let store = F5VoiceStore(paths: paths)
        let added = try store.importVoice(
            name: "Long", audio: source, transcript: "Lang opptak.")
        return try storedSeconds(
            store.directory(for: added.id).appendingPathComponent("ref.wav"))
    }

    /// Returns (rejectedEmptyTranscript, rejectedTooShort, removedCleanly).
    static func importRejectionsAndRemoval() throws -> (Bool, Bool, Bool) {
        let (paths, cleanup) = try tempPaths()
        defer { cleanup() }
        let store = F5VoiceStore(paths: paths)
        let source = paths.base.appendingPathComponent("clip.wav")
        try makeWAV(seconds: 3, rate: 24_000).write(to: source)

        var rejectedEmpty = false
        do {
            _ = try store.importVoice(name: "A", audio: source, transcript: "   ")
        } catch { rejectedEmpty = true }

        let tiny = paths.base.appendingPathComponent("tiny.wav")
        try makeWAV(seconds: 0.2, rate: 24_000).write(to: tiny)
        var rejectedShort = false
        do {
            _ = try store.importVoice(name: "B", audio: tiny, transcript: "Hei.")
        } catch { rejectedShort = true }

        let added = try store.importVoice(name: "C", audio: source, transcript: "Hei.")
        try store.remove(id: added.id)
        let removed = store.voice(id: added.id) == nil && store.voices().isEmpty
        return (rejectedEmpty, rejectedShort, removed)
    }

    /// Two voices with the same name must not collide on disk.
    static func duplicateNamesGetDistinctIDs() throws -> [String] {
        let (paths, cleanup) = try tempPaths()
        defer { cleanup() }
        let store = F5VoiceStore(paths: paths)
        let source = paths.base.appendingPathComponent("clip.wav")
        try makeWAV(seconds: 3, rate: 24_000).write(to: source)
        let first = try store.importVoice(name: "Nora", audio: source, transcript: "Hei.")
        let second = try store.importVoice(name: "Nora", audio: source, transcript: "Hei.")
        return [first.id, second.id]
    }
}
