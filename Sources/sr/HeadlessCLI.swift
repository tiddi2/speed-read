import AppKit
import Foundation
import SRCore

/// Headless CLI modes (acceptance testing + Phase 4 CLI seed).
///
///   sr --install-kokoro          install the English offline voice
///   sr --install-norwegian       install the Norwegian offline voice
///   sr --speak <file|->          speak a file (or stdin) through the full
///                                pipeline: normalize → chunk → synthesize
///                                (cache, janitor, fallback) → play
///   sr --speak-clipboard         speak the clipboard (honors concealed-
///                                content refusal; exit 2 when refused)
///
/// Flags: --local forces the offline route; --lang picks the language profile
/// (voice, model and the language pinned on the request). Like the GUI, the
/// CLI never detects the language from the text — an unspecified --lang means
/// English, not "whatever the model thinks".
@MainActor
enum HeadlessCLI {
    enum Mode {
        case installKokoro
        case installNorwegian
        case speak(source: String, language: SpeechLanguage,
                   forceLocal: Bool, overrideCostControls: Bool)
        case speakClipboard(language: SpeechLanguage,
                            forceLocal: Bool, overrideCostControls: Bool)
        case usage(error: String?)   // --help, or unrecognized/malformed args

        /// nil = no arguments at all → launch the GUI. Anything else is a CLI
        /// invocation: unrecognized flags become a usage error rather than
        /// silently launching the menu-bar app.
        init?(arguments: [String]) {
            let args = Array(arguments.dropFirst())
            guard !args.isEmpty else { return nil }
            // Help never executes a command, even when its operand is absent.
            if args.contains("--help") || args.contains("-h") {
                self = .usage(error: nil)
                return
            }
            var command: String?
            var source: String?
            var language: SpeechLanguage?
            var forceLocal = false
            var overrideCostControls = false
            var index = 0
            while index < args.count {
                let argument = args[index]
                switch argument {
                case "--local":
                    forceLocal = true
                case "--override-cost-controls":
                    overrideCostControls = true
                case "--lang":
                    guard language == nil else {
                        self = .usage(error: "--lang given more than once")
                        return
                    }
                    guard index + 1 < args.count,
                          let parsed = SpeechLanguage(rawValue: args[index + 1]) else {
                        let codes = SpeechLanguage.allCases.map(\.rawValue)
                            .joined(separator: "|")
                        self = .usage(error: "--lang requires one of: \(codes)")
                        return
                    }
                    language = parsed
                    index += 1
                case "--speak", "--speak-clipboard",
                     "--install-kokoro", "--install-norwegian":
                    guard command == nil else {
                        self = .usage(error: "choose exactly one command")
                        return
                    }
                    command = argument
                    if argument == "--speak" {
                        guard index + 1 < args.count,
                              args[index + 1] == "-" || !args[index + 1].hasPrefix("-") else {
                            self = .usage(error: "--speak requires a file path or - for stdin")
                            return
                        }
                        index += 1
                        source = args[index]
                    }
                default:
                    self = .usage(error: "unrecognized arguments: \(argument)")
                    return
                }
                index += 1
            }
            if command == "--install-kokoro" || command == "--install-norwegian" {
                guard !forceLocal && !overrideCostControls && language == nil else {
                    self = .usage(error: "speech flags require --speak or --speak-clipboard")
                    return
                }
                self = command == "--install-kokoro" ? .installKokoro : .installNorwegian
            } else if command == "--speak", let source {
                self = .speak(source: source, language: language ?? .english,
                              forceLocal: forceLocal,
                              overrideCostControls: overrideCostControls)
            } else if command == "--speak-clipboard" {
                self = .speakClipboard(language: language ?? .english,
                                       forceLocal: forceLocal,
                                       overrideCostControls: overrideCostControls)
            } else {
                self = .usage(error: "a command is required")
            }
        }
    }

    private static let usageText = """
    usage: sr [--speak <file|-> | --speak-clipboard | --install-kokoro | --install-norwegian] [--lang en|no] [--local] [--override-cost-controls]
      --speak <file|->    speak a file (or stdin) through the full pipeline
      --speak-clipboard   speak the clipboard (exit 2 on concealed content)
      --install-kokoro    install the English offline voice (Kokoro, ~330 MB)
      --install-norwegian install the Norwegian offline voice (F5-TTS, ~1.4 GB)
      --lang en|no        language profile to read in (default: en); pins the
                          language on the request instead of detecting it
      --local             force the offline route for this language
      --override-cost-controls
                          allow a cloud read past budget/large-read gates
    Run with no arguments to launch the menu-bar app.
    """

    static func run(_ mode: Mode) async -> Int32 {
        switch mode {
        case .usage(let error):
            if let error {
                FileHandle.standardError.write(Data("sr: \(error)\n\(usageText)\n".utf8))
                return 64  // EX_USAGE
            }
            print(usageText)
            return 0
        case .installKokoro:
            return await installKokoro()
        case .installNorwegian:
            return await installNorwegian()
        case .speak(let source, let language, let forceLocal, let overrideCostControls):
            guard let text = readText(source) else {
                FileHandle.standardError.write(Data("cannot read \(source)\n".utf8))
                return 1
            }
            return await speak(
                text,
                language: language,
                forceLocal: forceLocal,
                overrideCostControls: overrideCostControls)
        case .speakClipboard(let language, let forceLocal, let overrideCostControls):
            switch SelectionCapture.clipboardText() {
            case .concealed:
                print("CONCEALED-REFUSED")
                return 2
            case .empty, .accessibilityDenied:
                print("clipboard empty")
                return 1
            case .text(let text, _, _):
                return await speak(
                    text,
                    language: language,
                    forceLocal: forceLocal,
                    overrideCostControls: overrideCostControls)
            }
        }
    }

    private static func readText(_ source: String) -> String? {
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        }
        return try? String(contentsOfFile: source, encoding: .utf8)
    }

    // MARK: - Install

    private static func installKokoro() async -> Int32 {
        guard let source = daemonScriptSource(),
              let requirementsLock = requirementsLockSource() else {
            print("local installer resources not found (looked in bundle + ./daemon/)")
            return 1
        }
        if KokoroRuntime.shared.isInstalled {
            print("already installed")
            return 0
        }
        if KokoroRuntime.shared.installer.needsUpdate {
            print("updating existing local voice runtime…")
        }
        for await progress in KokoroRuntime.shared.installer.install(
            daemonSourceURL: source,
            requirementsLockURL: requirementsLock) {
            switch progress {
            case .creatingVenv: print("[1/4] creating Python venv…")
            case .installingPackages: print("[2/4] installing pinned mlx-audio…")
            case .downloadingModel: print("[3/4] downloading Kokoro model (~330 MB)…")
            case .verifying: print("[4/4] verifying SHA-256…")
            case .done:
                print("done — local voice installed")
                return 0
            case .failed(let message):
                print("FAILED: \(message)")
                return 1
            }
        }
        print("FAILED: install stream ended unexpectedly")
        return 1
    }

    /// The Norwegian model, headlessly. Same install the Settings button runs;
    /// reference recordings are added in the GUI, since picking an audio file
    /// and typing its transcript is not a command-line shape.
    private static func installNorwegian() async -> Int32 {
        guard let source = daemonScriptSource(),
              let requirementsLock = requirementsLockSource(),
              let fetcher = f5FetchScriptSource() else {
            print("local installer resources not found (looked in bundle + ./daemon/)")
            return 1
        }
        if F5Runtime.shared.isInstalled {
            print("already installed")
            return 0
        }
        if F5Runtime.shared.installer.needsUpdate {
            print("updating existing Norwegian voice…")
        }
        // The download reports bytes about once a second. On a terminal that
        // is a log, not a progress bar, so print a line only when the step
        // changes or another 5% has landed.
        var lastStage = ""
        var lastPercent = -5
        for await progress in F5Runtime.shared.installer.install(
            daemonSourceURL: source,
            requirementsLockURL: requirementsLock,
            fetchSourceURL: fetcher) {
            switch progress {
            case .creatingVenv: print("creating Python venv…")
            case .installingPackages: print("installing pinned f5-tts-mlx…")
            case .downloading(let stage, let fraction):
                guard let fraction else {
                    if stage != lastStage {
                        lastStage = stage
                        lastPercent = -5
                        print(stage)
                    }
                    break
                }
                let percent = Int(fraction * 100)
                if stage != lastStage || percent >= lastPercent + 5 {
                    lastStage = stage
                    lastPercent = percent
                    print("\(stage) — \(percent)%")
                }
            case .verifying: print("verifying SHA-256…")
            case .done:
                let voices = F5Runtime.shared.voices.voices()
                print(voices.isEmpty
                      ? "done — add a reference recording in Settings → Voices to use it"
                      : "done — Norwegian offline voice installed")
                return 0
            case .failed(let message):
                print("FAILED: \(message)")
                return 1
            }
        }
        print("FAILED: install stream ended unexpectedly")
        return 1
    }

    private static func f5FetchScriptSource() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sr_f5_fetch", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/sr_f5_fetch.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private static func daemonScriptSource() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sr_tts_server", withExtension: "py") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/sr_tts_server.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private static func requirementsLockSource() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "kokoro-requirements", withExtension: "lock") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/requirements.lock")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Speak

    private static func speak(
        _ text: String,
        language: SpeechLanguage,
        forceLocal: Bool,
        overrideCostControls: Bool
    ) async -> Int32 {
        // Same daemon-script freshness guarantee as the GUI (AppState.init).
        if KokoroRuntime.shared.isInstalled, let source = daemonScriptSource() {
            KokoroRuntime.shared.installer.syncDaemonScript(from: source)
        }
        let settings = SettingsStore()
        guard text.count <= Chunker.maxReadCharacters else {
            print("input too large (maximum \(Chunker.maxReadCharacters) characters)")
            return 1
        }
        // Same two steps as the GUI: normalize, then apply the language's
        // custom respellings before anything is chunked or hashed (F-13).
        let normalized = PronunciationStore.shared.applyAliases(
            to: Normalizer.normalize(text, language: language), language: language)
        guard normalized.count <= Chunker.maxReadCharacters else {
            print("input too large (maximum \(Chunker.maxReadCharacters) characters)")
            return 1
        }
        let chunks = Chunker.split(normalized)
        guard !chunks.isEmpty else {
            print("nothing to speak")
            return 1
        }
        print("sentences=\(chunks.count) chars=\(normalized.count) lang=\(language.rawValue)")

        AudioCache.shared.enabled = settings.cacheEnabled
        let playback = PlaybackEngine(rate: settings.playbackRate,
                                      sentencePauseMS: settings.sentencePauseMS)
        let pipeline = SynthesisPipeline()
        let janitor = HistoryJanitor()
        let ledger = CostLedger()
        let deleteHistory = settings.autoDeleteHistory

        let model = settings.modelID(for: language)
        // Phoneme rules ride along only on a model that acts on them, and
        // only once they have been uploaded — the CLI uses whatever the GUI
        // last synced rather than uploading mid-read.
        let locator = ElevenLabsProvider.supportsPhonemeRules(model)
            ? PronunciationStore.shared.locator(for: language) : nil
        let cloud = SynthesisPipeline.Route(
            provider: ElevenLabsProvider(modelID: model, language: language,
                                         pronunciationLocator: locator),
            voiceID: settings.voiceID(for: language),
            modelID: model,
            languageCode: ElevenLabsProvider.lockedLanguageCode(
                for: language, modelID: model) ?? "",
            variant: locator?.versionID ?? "")
        // Same rule as the GUI: a language whose offline model is missing —
        // or, for Norwegian, that has no reference recording yet — gets no
        // local route at all, rather than another language's voice reading it.
        var local: SynthesisPipeline.Route?
        if LocalVoices.isInstalled(for: language),
           let localVoice = settings.localVoiceID(for: language),
           LocalVoices.owns(voiceID: localVoice, language: language) {
            local = SynthesisPipeline.Route(
                provider: LocalVoices.provider(for: language),
                voiceID: localVoice,
                modelID: LocalVoices.cacheModelID(for: language),
                languageCode: language.rawValue,
                variant: LocalVoices.cacheVariant(for: language, voiceID: localVoice,
                                                  settings: settings))
        }

        let routePlan = BackendRouting.plan(
            mode: settings.backendMode,
            forceLocal: forceLocal,
            localAvailable: local != nil,
            hasCloudCredential: KeychainStore.readAPIKey() != nil)
        if routePlan == .localUnavailable {
            print(LocalVoices.unavailableMessage(for: language))
            return 1
        }
        let primary: SynthesisPipeline.Route
        let fallback: SynthesisPipeline.Route?
        switch routePlan {
        case .localOnly:
            primary = local!
            fallback = nil
        case .cloudOnly:
            primary = cloud
            fallback = nil
        case .cloudWithLocalFallback:
            primary = cloud
            fallback = local
        case .localUnavailable:
            return 1
        }

        let usesCloud = !primary.provider.isLocal
        if usesCloud && !overrideCostControls {
            if case .exceeded(let spent, let budget) = ledger.verdict() {
                print("COST-CONTROL: daily budget reached (\(spent)/\(budget)); use --override-cost-controls to continue")
                return 5
            }
            if normalized.count >= ledger.largeReadThreshold {
                print("COST-CONTROL: large cloud read (\(normalized.count) characters); use --override-cost-controls to continue")
                return 5
            }
        }
        let cloudBudgetRemaining = usesCloud && !overrideCostControls && !ledger.overriddenToday
            ? max(ledger.dailyBudget - ledger.spentToday, 0)
            : nil

        final class ExitBox: @unchecked Sendable {
            var code: Int32 = 0
            var resumed = false
        }
        let box = ExitBox()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @MainActor (Int32) -> Void = { code in
                guard !box.resumed else { return }
                box.resumed = true
                box.code = code
                continuation.resume()
            }

            playback.startSession(totalSentences: chunks.count)
            playback.onFinished = { finish(0) }
            playback.onError = { message in
                print("PLAYBACK-FAILED: \(message)")
                pipeline.cancel()
                finish(3)
            }

            pipeline.run(
                chunks: chunks,
                primary: primary,
                fallback: fallback,
                settings: settings.voiceSettings,
                cache: settings.cacheEnabled ? AudioCache.shared : nil,
                cloudBudgetRemaining: cloudBudgetRemaining,
                shouldSynthesize: { index in
                    SynthesisPipeline.needsChunk(
                        index, currentSentence: playback.currentSentence,
                        isPlaying: playback.state == .playing)
                },
                callbacks: .init(
                    deliver: { index, audio in playback.feed(index: index, audio: audio) },
                    billed: { billed in ledger.record(billedCharacters: billed) },
                    historyID: { id in
                        guard deleteHistory else { return }
                        Task { await janitor.enqueue(id) }
                    },
                    fellBack: { print("FELL-BACK-TO-LOCAL") },
                    failed: { error in
                        print("SYNTHESIS-FAILED: \(safeMessage(for: error))")
                        // Stop the remaining chunks too — they'd keep
                        // synthesizing (and billing, on cloud routes) through
                        // the janitor drain window below otherwise.
                        pipeline.cancel()
                        playback.stop()
                        finish(3)
                    }
                )
            )
        }

        // Do not exit with history deletions pending: the janitor's
        // 404-retry ladder (2.5s + 6s + 20s) exists precisely because
        // ElevenLabs materializes history items late. 45s covers it.
        if deleteHistory {
            let drained = await janitor.waitUntilDrained(timeout: 45)
            let janitorStatus = await janitor.statusLine
            if drained {
                print(janitorStatus)
            } else {
                print("WARNING: exiting with history deletions pending — \(janitorStatus)")
                if box.code == 0 { box.code = 4 }
            }
        }
        await KokoroRuntime.shared.supervisor.stop()
        return box.code
    }

    private static func safeMessage(for error: TTSError) -> String {
        // Offline failures name the real cause; see LocalVoices.failureMessage.
        if let local = LocalVoices.failureMessage(for: error) { return local }
        switch error {
        case .missingAPIKey: return "missing ElevenLabs API key"
        case .http(let status, _): return "provider HTTP \(status)"
        case .invalidAudio: return "provider returned invalid audio"
        case .network: return "provider network error"
        case .budgetExceeded: return "daily cloud budget reached"
        case .cancelled: return "cancelled"
        }
    }
}
