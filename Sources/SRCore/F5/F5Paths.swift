import Foundation

/// Filesystem layout for the Norwegian offline voice (F5-TTS).
///
/// Everything lives under ~/Library/Application Support/sr/f5/:
///   model/     model_v1.safetensors + vocab.txt, normalized by the fetcher
///   vocoder/   Vocos mel vocoder (model.safetensors + config.yaml)
///   voices/    one directory per reference voice: ref.wav + ref.txt
///   manifest.json — install manifest (resolved revision + verified hashes)
///
/// It sits beside the Kokoro tree rather than inside it because the two are
/// installed, updated and removed independently; the venv, daemon script and
/// socket they share stay under kokoro/.
public struct F5Paths: Sendable {
    public let base: URL

    public init(base: URL) {
        self.base = base
    }

    public static let standard = F5Paths(
        base: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sr/f5", isDirectory: true)
    )

    public var modelDir: URL { base.appendingPathComponent("model", isDirectory: true) }
    public var weights: URL { modelDir.appendingPathComponent("model_v1.safetensors") }
    public var vocab: URL { modelDir.appendingPathComponent("vocab.txt") }
    public var vocoderDir: URL { base.appendingPathComponent("vocoder", isDirectory: true) }
    public var vocoderWeights: URL { vocoderDir.appendingPathComponent("model.safetensors") }
    public var vocoderConfig: URL { vocoderDir.appendingPathComponent("config.yaml") }
    public var voicesDir: URL { base.appendingPathComponent("voices", isDirectory: true) }
    public var manifest: URL { base.appendingPathComponent("manifest.json") }
    /// Written by the fetcher, polled by the installer: a multi-gigabyte
    /// download with no progress is indistinguishable from a hung one.
    public var progressFile: URL { base.appendingPathComponent("download.progress") }
    /// Where the fetcher reports what it resolved and downloaded.
    public var fetchReport: URL { base.appendingPathComponent("fetch-report.json") }
}
