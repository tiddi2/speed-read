import Foundation
@testable import SRCore

// Foundation-touching helpers for KokoroTests, isolated in a file that does
// NOT import Testing: the CLT toolchain lacks the _Testing_Foundation
// cross-import overlay, so files importing Testing cannot use Foundation
// types directly (same pattern as FixtureLoader.swift).
enum KokoroTestSupport {
    static func paths(base: String) -> KokoroPaths {
        KokoroPaths(base: URL(fileURLWithPath: base))
    }

    /// Creates a unique temp dir; returns (paths, cleanup).
    static func tempPaths() throws -> (paths: KokoroPaths, cleanup: () -> Void) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-kokoro-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return (KokoroPaths(base: temp), { try? FileManager.default.removeItem(at: temp) })
    }

    static func isInstalled(_ paths: KokoroPaths) -> Bool {
        KokoroInstaller(paths: paths).isInstalled
    }

    /// Writes a manifest with the compiled-in pins, reloads it, and returns
    /// (mlxAudioVersion, modelRevision, weightsSHA256).
    static func manifestRoundTrip(_ paths: KokoroPaths) throws -> (String, String, String) {
        let manifest = KokoroInstaller.Manifest(
            mlxAudioVersion: KokoroInstaller.mlxAudioVersion,
            modelRepo: KokoroInstaller.modelRepo,
            modelRevision: KokoroInstaller.modelRevision,
            weightsSHA256: KokoroInstaller.weightsSHA256,
            configSHA256: KokoroInstaller.configSHA256,
            requirementsLockSHA256: KokoroInstaller.requirementsLockSHA256,
            snapshotPath: "/nonexistent",
            installedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        try JSONEncoder().encode(manifest).write(to: paths.manifest)
        let loaded = try KokoroInstaller(paths: paths).loadManifest()
        return (loaded.mlxAudioVersion, loaded.modelRevision, loaded.weightsSHA256)
    }

    static func validatedManifestRejectsMissingSnapshot(_ paths: KokoroPaths) throws -> Bool {
        _ = try manifestRoundTrip(paths)
        do {
            _ = try KokoroInstaller(paths: paths).loadValidatedManifest()
            return false
        } catch {
            return true
        }
    }

    static func legacyManifestRemainsDecodable(_ paths: KokoroPaths) throws -> Bool {
        struct LegacyManifest: Codable {
            let mlxAudioVersion: String
            let modelRepo: String
            let modelRevision: String
            let weightsSHA256: String
            let configSHA256: String
            let snapshotPath: String
            let installedAt: Date
        }
        let legacy = LegacyManifest(
            mlxAudioVersion: KokoroInstaller.mlxAudioVersion,
            modelRepo: KokoroInstaller.modelRepo,
            modelRevision: KokoroInstaller.modelRevision,
            weightsSHA256: KokoroInstaller.weightsSHA256,
            configSHA256: KokoroInstaller.configSHA256,
            snapshotPath: "/nonexistent",
            installedAt: Date(timeIntervalSince1970: 1_780_000_000))
        try JSONEncoder().encode(legacy).write(to: paths.manifest)
        return try KokoroInstaller(paths: paths).loadManifest()
            .requirementsLockSHA256 == nil
    }

    /// (keptKeys, uvKeysRemaining, pathValue, extraValue) after scrubbing.
    static func scrubbedEnvironment() -> (Int, Int, String?, String?) {
        let ambient = [
            "PATH": "/usr/bin",
            "HOME": "/Users/someone",
            "HTTPS_PROXY": "http://proxy:3128",
            "UV_EXCLUDE_NEWER": "3 days",
            "UV_INDEX_URL": "https://somewhere.else/simple",
            "UV_PYTHON": "3.9",
        ]
        let result = LocalRuntimeInstaller.scrubbed(
            ambient, adding: ["HF_HUB_DISABLE_TELEMETRY": "1"])
        return (result.count,
                result.keys.filter { $0.hasPrefix("UV_") }.count,
                result["PATH"],
                result["HF_HUB_DISABLE_TELEMETRY"])
    }

    /// An explicit extra must win over an ambient value of the same name.
    static func scrubbedEnvironmentPrefersExplicitValues() -> String? {
        LocalRuntimeInstaller.scrubbed(
            ["HF_HUB_DISABLE_TELEMETRY": "0"],
            adding: ["HF_HUB_DISABLE_TELEMETRY": "1"])["HF_HUB_DISABLE_TELEMETRY"]
    }

    /// SHA-256 of a temp file containing `content`, via the streaming hasher.
    static func sha256OfContent(_ content: String) throws -> String {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sr-sha-test-\(UUID().uuidString).txt")
        try Data(content.utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        return try KokoroInstaller.sha256(of: temp)
    }

    static func standardBasePath() -> String {
        KokoroPaths.standard.base.path
    }

    static func derivedPaths(base: String) -> (python: String, script: String, socket: String, manifest: String) {
        let p = paths(base: base)
        return (p.venvPython.path, p.daemonScript.path, p.socketPath, p.manifest.path)
    }
}
