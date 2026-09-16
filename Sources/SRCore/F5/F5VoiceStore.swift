import AVFoundation
import Foundation

/// One Norwegian offline voice: a short reference recording and what is said
/// in it.
///
/// F5-TTS is a zero-shot cloner rather than a model with baked-in speakers —
/// it reads new text in the voice of whatever recording it is conditioned on.
/// So "pick a voice" here means "pick a reference clip", and adding a voice
/// is adding a clip. Nothing about it leaves the Mac.
public struct F5Voice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let transcript: String
    /// Short digest of the clip and its transcript. It goes into the audio
    /// cache key, so re-recording a voice under the same name never replays
    /// the old voice's audio.
    public let fingerprint: String

    public var asVoice: Voice { Voice(id: id, name: name) }
}

/// The reference voices on disk, under ~/Library/Application Support/sr/f5/voices.
public struct F5VoiceStore: Sendable {
    /// Upstream recommends well under ~12 s of reference audio; past that,
    /// quality falls off and every generation gets slower for no gain.
    public static let maxReferenceSeconds = 12.0
    public static let minReferenceSeconds = 1.0
    public static let sampleRate = 24_000.0

    public let paths: F5Paths

    public init(paths: F5Paths = .standard) {
        self.paths = paths
    }

    private struct Meta: Codable {
        let name: String
        let fingerprint: String
        let createdAt: Date
    }

    public func directory(for id: String) -> URL {
        paths.voicesDir.appendingPathComponent(id, isDirectory: true)
    }

    /// Every installed voice, name-sorted so the list does not reshuffle.
    public func voices() -> [F5Voice] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: paths.voicesDir, includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { voice(id: $0.lastPathComponent) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func voice(id: String) -> F5Voice? {
        guard Self.isValidID(id) else { return nil }
        let directory = directory(for: id)
        guard let transcript = try? String(
            contentsOf: directory.appendingPathComponent("ref.txt"), encoding: .utf8),
              FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("ref.wav").path)
        else { return nil }
        let meta = (try? Data(contentsOf: directory.appendingPathComponent("meta.json")))
            .flatMap { try? JSONDecoder().decode(Meta.self, from: $0) }
        return F5Voice(
            id: id,
            name: meta?.name ?? id,
            transcript: transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            fingerprint: meta?.fingerprint ?? "")
    }

    /// Import an audio file as a reference voice, converting it to the 24 kHz
    /// mono the model conditions on. Returns the stored voice.
    ///
    /// `id` is for callers that want a stable slot (the installer's "Model
    /// sample"); otherwise one is derived from the name.
    @discardableResult
    public func importVoice(
        name: String,
        audio source: URL,
        transcript: String,
        id explicitID: String? = nil
    ) throws -> F5Voice {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw InstallError(message: "Give the voice a name.")
        }
        guard !trimmedTranscript.isEmpty else {
            throw InstallError(message:
                "Type exactly what is said in the recording — F5 needs it to match voice to text.")
        }

        let fm = FileManager.default
        let id = explicitID ?? uniqueID(for: trimmedName)
        guard Self.isValidID(id) else {
            throw InstallError(message: "That name has no letters or digits to build an id from.")
        }
        let directory = directory(for: id)

        // Stage beside the destination, then swap: a half-converted clip left
        // behind by a crash would fail at synthesis time instead of here.
        let staging = paths.voicesDir
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let wav = staging.appendingPathComponent("ref.wav")
        try Self.convertToReferenceWAV(source: source, destination: wav)
        try Data(trimmedTranscript.utf8)
            .write(to: staging.appendingPathComponent("ref.txt"), options: .atomic)

        let audioHash = try LocalRuntimeInstaller.sha256(of: wav)
        let fingerprint = String(audioHash.prefix(12))
            + "-" + String(Self.digest(of: trimmedTranscript).prefix(8))
        let meta = Meta(name: trimmedName, fingerprint: fingerprint, createdAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta)
            .write(to: staging.appendingPathComponent("meta.json"), options: .atomic)

        if fm.fileExists(atPath: directory.path) {
            try fm.removeItem(at: directory)
        }
        try fm.createDirectory(at: paths.voicesDir, withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: directory)
        SRLog.event("f5.voice_added", ["id": id])
        return F5Voice(id: id, name: trimmedName,
                       transcript: trimmedTranscript, fingerprint: fingerprint)
    }

    public func remove(id: String) throws {
        guard Self.isValidID(id) else { return }
        try FileManager.default.removeItem(at: directory(for: id))
        SRLog.event("f5.voice_removed", ["id": id])
    }

    // MARK: - Identifiers

    /// Voice ids are bare lowercase names: they become a directory name and
    /// travel to the daemon over the wire, where the same shape is enforced.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64
            && id.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }

    /// Letters Nordic names are full of, spelled the way a Norwegian would
    /// transliterate them. Diacritic folding alone does not touch æ, ø or å —
    /// they are letters, not accented vowels — so "Bjørn" would otherwise
    /// slug to "bj-rn".
    private static let transliterations: [Character: String] = [
        "æ": "ae", "ø": "o", "å": "a", "ä": "a", "ö": "o", "ü": "u", "ß": "ss",
    ]

    public static func slug(_ name: String) -> String {
        let expanded = String(name.lowercased().flatMap { character in
            transliterations[character] ?? String(character)
        })
        let folded = expanded.folding(options: [.diacriticInsensitive, .widthInsensitive],
                                      locale: Locale(identifier: "en_US"))
        var slug = ""
        // ASCII only, deliberately: the id becomes a directory name and is
        // re-validated by the daemon against the same narrow pattern.
        for character in folded {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        while slug.hasPrefix("-") { slug.removeFirst() }
        return String(slug.prefix(48))
    }

    private func uniqueID(for name: String) -> String {
        let base = Self.slug(name).isEmpty ? "voice" : Self.slug(name)
        var candidate = base
        var counter = 2
        while FileManager.default.fileExists(atPath: directory(for: candidate).path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func digest(of text: String) -> String {
        // Reuse the streaming hasher rather than adding a second one: the
        // transcript is a sentence, so the temp file costs nothing.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-f5-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? Data(text.utf8).write(to: temp)) != nil,
              let hash = try? LocalRuntimeInstaller.sha256(of: temp) else { return "" }
        return hash
    }

    // MARK: - Audio

    /// Convert any audio file macOS can read into the mono 24 kHz WAV the
    /// model conditions on, trimmed to a usable reference length.
    ///
    /// Doing this here rather than in the daemon means the stored clip is
    /// always exactly what F5 expects, so the daemon can refuse anything else
    /// outright instead of resampling whatever it is handed.
    static func convertToReferenceWAV(source: URL, destination: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw InstallError(message: "That file could not be read as audio.")
        }
        let inputFormat = input.processingFormat
        guard inputFormat.sampleRate > 0, input.length > 0 else {
            throw InstallError(message: "That recording is empty.")
        }
        guard Double(input.length) / inputFormat.sampleRate >= minReferenceSeconds else {
            throw InstallError(message:
                "That recording is under a second — use 3 to 10 seconds of clear speech.")
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw InstallError(message: "That recording's format is not supported.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let outputFile = try AVAudioFile(forWriting: destination, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])

        let chunk: AVAudioFrameCount = 8192
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, frameCapacity: chunk) else {
            throw InstallError(message: "Not enough memory to convert that recording.")
        }
        // Everything past the cap is dropped rather than rejected: a user
        // picking a whole podcast episode should still get a working voice.
        let frameLimit = AVAudioFramePosition(maxReferenceSeconds * sampleRate)
        var written: AVAudioFramePosition = 0
        var finished = false

        while !finished, written < frameLimit {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: chunk) else { break }
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) {
                _, outStatus in
                do {
                    inputBuffer.frameLength = chunk
                    try input.read(into: inputBuffer)
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inputBuffer
            }
            if conversionError != nil {
                throw InstallError(message: "That recording could not be converted.")
            }
            if outputBuffer.frameLength > 0 {
                let remaining = frameLimit - written
                if AVAudioFramePosition(outputBuffer.frameLength) > remaining {
                    outputBuffer.frameLength = AVAudioFrameCount(remaining)
                }
                try outputFile.write(from: outputBuffer)
                written += AVAudioFramePosition(outputBuffer.frameLength)
            }
            if status == .endOfStream || status == .error { finished = true }
            if status == .inputRanDry && outputBuffer.frameLength == 0 { finished = true }
        }

        guard written >= AVAudioFramePosition(minReferenceSeconds * sampleRate) else {
            throw InstallError(message:
                "That recording is too short — use 3 to 10 seconds of clear speech.")
        }
    }
}
