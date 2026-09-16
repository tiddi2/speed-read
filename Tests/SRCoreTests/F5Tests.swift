import Testing
@testable import SRCore

// Foundation-dependent setup lives in F5TestSupport.swift (see the
// cross-import overlay note there).
@Suite struct F5Tests {
    // MARK: - Paths

    @Test func pathDerivation() {
        let derived = F5TestSupport.derivedPaths(base: "/tmp/f5test")
        #expect(derived.weights == "/tmp/f5test/model/model_v1.safetensors")
        #expect(derived.vocab == "/tmp/f5test/model/vocab.txt")
        #expect(derived.vocoder == "/tmp/f5test/vocoder/model.safetensors")
        #expect(derived.voices == "/tmp/f5test/voices")
    }

    @Test func standardPathsSitBesideKokoro() {
        let base = F5TestSupport.standardBasePath()
        #expect(base.hasSuffix("/Library/Application Support/sr/f5"))
    }

    // MARK: - Architecture

    /// The daemon reads these exact keys out of SR_F5_ARCH. Renaming one on
    /// either side silently falls back to the daemon's defaults, which is the
    /// difference between Norwegian speech and Norwegian babble.
    @Test func archEnvironmentUsesTheDaemonsKeyNames() {
        #expect(F5TestSupport.archEnvironmentKeys() == [
            "conv_layers", "depth", "dim", "ff_mult", "heads",
            "pe_attn_head", "text_dim", "text_mask_padding",
        ])
    }

    @Test func variantsRoundTripThroughTheArchitecture() {
        let base = F5TestSupport.applied(.base)
        #expect(base.0 == false)
        #expect(base.1 == 1)
        let v1 = F5TestSupport.applied(.v1Base)
        #expect(v1.0 == true)
        #expect(v1.1 == nil)
        #expect(F5Installer.Arch.f5Base.variant == .base)
        #expect(F5Installer.Arch.f5Base.applying(.v1Base).variant == .v1Base)
    }

    // MARK: - Manifest

    /// The weights are gigabytes, so per-launch validation checks size rather
    /// than re-hashing — it still has to catch a truncated file.
    @Test func manifestValidationCatchesATruncatedCheckpoint() throws {
        let (intact, truncated) = try F5TestSupport.manifestValidation()
        #expect(intact)
        #expect(!truncated)
    }

    // MARK: - Fetch report (the Python ↔ Swift contract)

    @Test func fetchReportDecodesWhatTheFetcherWrites() throws {
        let (revision, weights, peAttnHead, reference) =
            try F5TestSupport.decodeFetchReport()
        #expect(revision == "deadbeef")
        #expect(weights == "model_last.safetensors")
        #expect(peAttnHead == 1)
        #expect(reference == "Hei og hallo.")
    }

    @Test func aNullPeAttnHeadMeansTheV1Architecture() throws {
        #expect(try F5TestSupport.decodeV1FetchReportVariant() == .v1Base)
    }

    // MARK: - Download progress

    /// A gigabyte-scale download with no visible progress is
    /// indistinguishable from a hang, so the byte fields the fetcher writes
    /// have to survive the trip into a percentage.
    @Test func downloadProgressBecomesAPercentage() throws {
        let stage = try F5TestSupport.readProgress(
            #"{"stage":"downloading","detail":"412 MB of 1.4 GB","bytes":412000000,"total":1400000000}"#)
        #expect(stage.found)
        #expect(stage.message == "Downloading Norwegian model — 412 MB of 1.4 GB")
        #expect(stage.fraction != nil)
        #expect(abs((stage.fraction ?? 0) - 0.294) < 0.01)
    }

    /// Steps that cannot report bytes must stay indeterminate rather than
    /// claim 0% — a spinner is honest, a stuck bar at zero is not.
    @Test(arguments: [
        #"{"stage":"resolving","detail":""}"#,
        #"{"stage":"normalizing","detail":""}"#,
        #"{"stage":"downloading","detail":"","bytes":5,"total":0}"#,
    ])
    func stepsWithoutBytesReportNoFraction(_ json: String) throws {
        let stage = try F5TestSupport.readProgress(json)
        #expect(stage.found)
        #expect(stage.fraction == nil)
    }

    @Test func anUnknownStageIsIgnoredRatherThanShown() throws {
        let unknown = try F5TestSupport.readProgress(#"{"stage":"who-knows"}"#)
        #expect(!unknown.found)
        let garbage = try F5TestSupport.readProgress("not json at all")
        #expect(!garbage.found)
    }

    // MARK: - Reference voices

    @Test func importedVoiceIsResampledAndReadableBack() throws {
        let (id, name, transcript, fingerprintLength, seconds, sampleRate) =
            try F5TestSupport.importRoundTrip()
        #expect(id == "min-stemme")
        #expect(name == "Min Stemme!")
        #expect(transcript == "Hei og hallo.")
        #expect(fingerprintLength > 0)
        // The daemon refuses anything that is not 24 kHz, so the store has to
        // resample — the source here was 44.1 kHz — without losing the clip.
        #expect(sampleRate == F5VoiceStore.sampleRate)
        #expect(seconds > 3.8 && seconds < 4.2)
    }

    @Test func aLongClipIsTrimmedRatherThanRefused() throws {
        let seconds = try F5TestSupport.importTrimsLongClip()
        #expect(seconds <= F5VoiceStore.maxReferenceSeconds + 0.2)
        #expect(seconds > F5VoiceStore.maxReferenceSeconds - 0.5)
    }

    /// A voice with no transcript cannot be synthesized with at all — F5
    /// conditions on reference text — so it is refused at import, not at read.
    @Test func importRefusesWhatCannotBeSpokenWith() throws {
        let (rejectedEmpty, rejectedShort, removed) =
            try F5TestSupport.importRejectionsAndRemoval()
        #expect(rejectedEmpty)
        #expect(rejectedShort)
        #expect(removed)
    }

    @Test func sameNameDoesNotOverwriteAnExistingVoice() throws {
        let ids = try F5TestSupport.duplicateNamesGetDistinctIDs()
        #expect(ids == ["nora", "nora-2"])
    }

    // MARK: - Identifiers

    /// Voice ids become directory names and travel to the daemon, which
    /// enforces the same shape. Anything with a slash or a dot in it would be
    /// a path-traversal question rather than a naming one.
    @Test(arguments: [
        ("Min stemme", "min-stemme"),
        ("Nora (NRK)", "nora-nrk"),
        ("Bjørn Ørn", "bjorn-orn"),
        ("   ", ""),
        ("../etc/passwd", "etc-passwd"),
    ])
    func slugsAreBareLowercaseNames(_ input: String, _ expected: String) {
        #expect(F5VoiceStore.slug(input) == expected)
    }

    @Test func idValidationRejectsAnythingThatIsNotABareName() {
        #expect(F5VoiceStore.isValidID("min-stemme"))
        #expect(F5VoiceStore.isValidID("model-sample"))
        #expect(!F5VoiceStore.isValidID(""))
        #expect(!F5VoiceStore.isValidID("../escape"))
        #expect(!F5VoiceStore.isValidID("has/slash"))
        #expect(!F5VoiceStore.isValidID("has.dot"))
        #expect(!F5VoiceStore.isValidID("Upper"))
        #expect(!F5VoiceStore.isValidID("-leading"))
        #expect(!F5VoiceStore.isValidID(String(repeating: "a", count: 65)))
    }

    // MARK: - Routing

    /// Kokoro's audio depends only on voice and model, so its cache key must
    /// not gain a variant — that would orphan every entry already on disk.
    @Test func kokoroKeepsAnEmptyCacheVariant() {
        #expect(LocalVoices.cacheVariant(for: .english, voiceID: "bf_lily").isEmpty)
    }

    @Test func eachLanguageRoutesToItsOwnEngine() {
        #expect(LocalVoices.cacheModelID(for: .english) == KokoroProvider.cacheModelID)
        #expect(LocalVoices.cacheModelID(for: .norwegian) == F5Provider.cacheModelID)
        #expect(LocalVoices.provider(for: .english).id == "kokoro")
        #expect(LocalVoices.provider(for: .norwegian).id == "f5")
    }

    /// F5 is Norwegian's engine; handed another language it must refuse
    /// rather than read the text in the wrong one.
    @Test func f5RefusesALanguageItWasNotInstalledFor() async {
        do {
            _ = try await F5Provider(language: .english)
                .synthesize(text: "hello", voiceID: "whatever", settings: VoiceSettings())
            Issue.record("F5 spoke English with the Norwegian model")
        } catch let error as TTSError {
            guard case .network(let detail) = error else {
                Issue.record("unexpected TTSError: \(error)")
                return
            }
            #expect(detail == "f5: language not installed")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
