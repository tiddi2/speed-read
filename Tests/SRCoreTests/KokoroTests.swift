import Testing
@testable import SRCore

// Foundation-dependent setup lives in KokoroTestSupport.swift (see the
// cross-import overlay note there).
@Suite struct KokoroTests {
    // MARK: - Token generation

    @Test func tokenIs64HexChars() {
        let token = KokoroDaemonSupervisor.generateToken()
        #expect(token.count == 64)
        #expect(token.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) })
    }

    @Test func tokensAreUnique() {
        let tokens = (0..<100).map { _ in KokoroDaemonSupervisor.generateToken() }
        #expect(Set(tokens).count == tokens.count)
    }

    // MARK: - Wire format

    @Test func requestEncodesAllFields() throws {
        let request = LocalTTSRequest(
            token: "abc123", text: "Hello world.", voice: "bf_lily",
            speed: "1.0", lang_code: "b")
        let line = try KokoroWire.encode(request)
        #expect(!line.contains("\n"))
        for fragment in ["\"token\":\"abc123\"", "\"text\":\"Hello world.\"",
                         "\"voice\":\"bf_lily\"", "\"speed\":\"1.0\"",
                         "\"lang_code\":\"b\"", "\"engine\":\"kokoro\""] {
            #expect(line.contains(fragment), "missing \(fragment) in \(line)")
        }
    }

    /// The daemon serves both engines over one socket, so the engine has to
    /// be on the wire — and default to Kokoro, which is what a request from
    /// before the Norwegian voice existed means.
    @Test func requestDefaultsToKokoroAndCarriesTheChosenEngine() throws {
        let f5 = LocalTTSRequest(
            token: "t", text: "Hei.", voice: "min-stemme",
            speed: "1.0", lang_code: "n", engine: "f5")
        #expect(try KokoroWire.encode(f5).contains("\"engine\":\"f5\""))
    }

    /// Each engine has its own output version; a daemon answering with the
    /// other engine's namespace must never reach playback or the cache.
    @Test func engineOutputVersionsDoNotCrossOver() throws {
        let f5Line = #"{"status":"ok","audio_file":"/tmp/gen_x/out.wav","output_version":"f5-tts-no-t1"}"#
        #expect(try KokoroWire.decodeResponse(f5Line, expecting: F5Provider.cacheModelID)
                == .ok(audioFile: "/tmp/gen_x/out.wav"))
        #expect(try KokoroWire.decodeResponse(f5Line)
                == .incompatible(audioFile: "/tmp/gen_x/out.wav"))
        let kokoroLine = #"{"status":"ok","audio_file":"/tmp/gen_x/out.wav","output_version":"kokoro-82M-t2"}"#
        #expect(try KokoroWire.decodeResponse(kokoroLine, expecting: F5Provider.cacheModelID)
                == .incompatible(audioFile: "/tmp/gen_x/out.wav"))
    }

    @Test func responseParsesOK() throws {
        let response = try KokoroWire.decodeResponse(
            #"{"status": "ok", "audio_file": "/tmp/gen_x/out.wav", "output_version": "kokoro-82M-t2"}"#)
        #expect(response == .ok(audioFile: "/tmp/gen_x/out.wav"))
    }

    @Test(arguments: [
        #"{"status":"ok","audio_file":"/tmp/gen_x/out.wav"}"#,
        #"{"status":"ok","audio_file":"/tmp/gen_x/out.wav","output_version":"kokoro-82M-t1"}"#,
    ])
    func legacyDaemonCannotProduceCacheableAudio(_ line: String) throws {
        #expect(try KokoroWire.decodeResponse(line) == .incompatible(audioFile: "/tmp/gen_x/out.wav"))
    }

    @Test func responseParsesError() throws {
        let response = try KokoroWire.decodeResponse(
            #"{"status": "error", "message": "unauthorized"}"#)
        #expect(response == .error(message: "unauthorized"))
    }

    @Test func responseOKWithoutFileIsError() throws {
        let response = try KokoroWire.decodeResponse(#"{"status": "ok"}"#)
        #expect(response == .error(message: "unknown daemon error"))
    }

    // MARK: - Child environment

    /// uv reads UV_* from the environment as well as from uv.toml, and
    /// `--no-config` only covers the files. A `UV_EXCLUDE_NEWER` left in a
    /// login shell is enough to stop `uv venv` from starting at all.
    @Test func uvSettingsFromTheUsersShellDoNotReachTheInstaller() {
        let (kept, uvRemaining, path, extra) = KokoroTestSupport.scrubbedEnvironment()
        #expect(uvRemaining == 0)
        // PATH, HOME, HTTPS_PROXY and the one added variable — the three UV_
        // entries are gone and nothing else was collateral.
        #expect(kept == 4)
        #expect(path == "/usr/bin")
        #expect(extra == "1")
    }

    @Test func anExplicitVariableOverridesTheAmbientOne() {
        #expect(KokoroTestSupport.scrubbedEnvironmentPrefersExplicitValues() == "1")
    }

    // MARK: - Paths

    @Test func pathDerivation() {
        let derived = KokoroTestSupport.derivedPaths(base: "/tmp/krtest")
        #expect(derived.python == "/tmp/krtest/venv/bin/python3")
        #expect(derived.script == "/tmp/krtest/sr_tts_server.py")
        #expect(derived.socket == "/tmp/krtest/daemon.sock")
        #expect(derived.manifest == "/tmp/krtest/manifest.json")
    }

    @Test func standardPathsUnderApplicationSupport() {
        #expect(KokoroTestSupport.standardBasePath()
            .hasSuffix("Application Support/sr/kokoro"))
    }

    // MARK: - Installer state

    @Test func isInstalledFalseOnEmptyDir() throws {
        let (paths, cleanup) = try KokoroTestSupport.tempPaths()
        defer { cleanup() }
        #expect(KokoroTestSupport.isInstalled(paths) == false)
    }

    @Test func manifestRoundTrips() throws {
        let (paths, cleanup) = try KokoroTestSupport.tempPaths()
        defer { cleanup() }
        let (version, revision, weightsSHA) = try KokoroTestSupport.manifestRoundTrip(paths)
        #expect(version == "0.4.4")
        #expect(revision == KokoroInstaller.modelRevision)
        #expect(weightsSHA == KokoroInstaller.weightsSHA256)
    }

    @Test func validatedManifestFailsClosedWhenSnapshotIsMissing() throws {
        let (paths, cleanup) = try KokoroTestSupport.tempPaths()
        defer { cleanup() }
        #expect(try KokoroTestSupport.validatedManifestRejectsMissingSnapshot(paths))
    }

    @Test func legacyManifestRemainsDecodableForUpdatePrompt() throws {
        let (paths, cleanup) = try KokoroTestSupport.tempPaths()
        defer { cleanup() }
        #expect(try KokoroTestSupport.legacyManifestRemainsDecodable(paths))
    }

    // MARK: - Socket health check

    @Test func socketConnectableFalseForMissingSocket() {
        #expect(KokoroDaemonSupervisor.socketConnectable("/tmp/definitely-missing.sock") == false)
    }

    // MARK: - SHA-256

    @Test func sha256MatchesKnownVector() throws {
        let hash = try KokoroTestSupport.sha256OfContent("abc")
        #expect(hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Provider voices

    @Test func providerListsTwelveVoices() async throws {
        let voices = try await KokoroProvider().voices()
        #expect(voices.count == 12)
        #expect(voices.first?.id == "bf_lily")
        #expect(KokoroProvider().isLocal == true)
    }
}
