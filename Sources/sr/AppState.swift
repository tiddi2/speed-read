import AppKit
import Combine
import Foundation
@preconcurrency import KeyboardShortcuts
import SRCore
import SwiftUI

@MainActor
extension KeyboardShortcuts.Name {
    /// ⌥⇧/ — speak selection, or stop if speaking (F-1, F-2).
    static let speakOrStop = Self("speakOrStop",
        default: .init(.slash, modifiers: [.option, .shift]))
    /// ⌥⇧. — pause/resume (F-2).
    static let pauseResume = Self("pauseResume",
        default: .init(.period, modifiers: [.option, .shift]))
}

/// Central controller: hotkeys → routing → capture → normalize → chunk →
/// synthesize (cache-first, budgeted) → play. Owns all mutable app state.
@MainActor
final class AppState: ObservableObject {
    let settings = SettingsStore()
    let playback: PlaybackEngine
    let ledger = CostLedger()
    private let pipeline = SynthesisPipeline()
    private let janitor = HistoryJanitor()
    private var routing = RoutingPolicy.load()

    @Published var statusMessage: String?
    @Published var lastError: String?
    @Published var creditsRemaining: Int?
    @Published var creditsLimit: Int?
    /// Account voice list (F-10); presets until the first fetch lands.
    @Published var availableVoices: [Voice] = ElevenLabsProvider.presetVoices
    private var voicesFetchedAt: Date?
    @Published var historyStatus: String = ""
    @Published var kokoroInstallStatus: String?
    @Published var kokoroInstalled = KokoroRuntime.shared.isInstalled
    @Published var kokoroNeedsUpdate = KokoroRuntime.shared.installer.needsUpdate
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()

    @Published var playbackRate: Double {
        didSet {
            settings.playbackRate = playbackRate
            playback.rate = playbackRate
        }
    }
    @Published var voiceID: String {
        didSet { settings.voiceID = voiceID }
    }
    @Published var localVoiceID: String {
        didSet { settings.localVoiceID = localVoiceID }
    }
    /// Language of the next read; picks the normalizer's lexicon (F-4).
    @Published var speechLanguage: SpeechLanguage {
        didSet { settings.speechLanguage = speechLanguage }
    }
    @Published var modelID: String {
        didSet { settings.modelID = modelID }
    }
    /// Backend mode; `.local` is the Local-Only master switch (P-8).
    @Published var backendMode: SettingsStore.BackendMode {
        didSet {
            settings.backendMode = backendMode
            // Local-Only is a live privacy boundary, not a preference for the
            // next read. Stop a cloud-backed session before more chunks upload.
            if backendMode == .local, oldValue != .local, activeUsesCloud {
                stop()
                flashStatus("Cloud read stopped — Local-Only is active")
            }
        }
    }
    @Published var autoDeleteHistory: Bool {
        didSet { settings.autoDeleteHistory = autoDeleteHistory }
    }
    @Published var cacheEnabled: Bool {
        didSet {
            settings.cacheEnabled = cacheEnabled
            AudioCache.shared.enabled = cacheEnabled
        }
    }

    private var statusClearTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// Serializes selection captures: two concurrent ⌘C fallbacks snapshot/
    /// restore each other's transient pasteboard state and can permanently
    /// replace the user's clipboard with the selection (P-3 violation).
    private var captureInFlight = false
    /// Bumped per speak(); stale pipeline deliveries (a chunk that slipped
    /// past cancellation) are dropped instead of feeding into the new session.
    private var speakGeneration = 0
    private var preparationGeneration = 0
    private var activeUsesCloud = false

    init() {
        let store = SettingsStore()
        playback = PlaybackEngine(rate: store.playbackRate,
                                  sentencePauseMS: store.sentencePauseMS)
        playbackRate = store.playbackRate
        voiceID = store.voiceID
        localVoiceID = store.localVoiceID
        modelID = store.modelID
        speechLanguage = store.speechLanguage
        backendMode = store.backendMode
        autoDeleteHistory = store.autoDeleteHistory
        cacheEnabled = store.cacheEnabled
        AudioCache.shared.enabled = store.cacheEnabled

        KeyboardShortcuts.onKeyDown(for: .speakOrStop) { [weak self] in
            Task { @MainActor in self?.speakOrStop() }
        }
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { [weak self] in
            Task { @MainActor in self?.playback.togglePauseResume() }
        }

        playback.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        if !accessibilityGranted {
            promptForAccessibility()
        }
        refreshCredits()
        refreshVoices()

        // Resume history deletions that were pending when the app last quit.
        if let ids = UserDefaults.standard.stringArray(forKey: Self.pendingDeletesKey),
           !ids.isEmpty {
            let janitor = janitor
            Task {
                for id in ids { await janitor.enqueue(id) }
                UserDefaults.standard.removeObject(forKey: Self.pendingDeletesKey)
            }
        }

        // Startup cache maintenance (TTL sweep + LRU).
        Task.detached(priority: .utility) {
            AudioCache.shared.evictIfNeeded()
        }

        // Keep the installed daemon script current with the bundled one —
        // daemon fixes in app updates would otherwise never reach installs.
        if KokoroRuntime.shared.isInstalled, let source = daemonScriptSource() {
            KokoroRuntime.shared.installer.syncDaemonScript(from: source)
        }

        // Pre-warm the local daemon when it can be needed (Auto fallback or
        // Local mode), so cloud→local fallback is near-instant rather than
        // paying a cold model load. Idle unload still reclaims the memory.
        if backendMode != .cloud && KokoroRuntime.shared.isInstalled {
            Task.detached(priority: .utility) {
                try? await KokoroRuntime.shared.supervisor.ensureRunning()
            }
        }
    }

    private nonisolated static let pendingDeletesKey = "pendingHistoryDeletes"

    func shutdown() async {
        stop()
        installTask?.cancel()
        await installTask?.value
        installTask = nil
        // Persist not-yet-completed history deletions across quits (IDs are
        // opaque provider tokens — content-free). Re-enqueued at next launch.
        let ids = await janitor.pendingIDs
        if ids.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.pendingDeletesKey)
        } else {
            UserDefaults.standard.set(ids, forKey: Self.pendingDeletesKey)
        }
        UserDefaults.standard.synchronize()
        await KokoroRuntime.shared.supervisor.stop()
    }

    // MARK: - Primary flows

    /// Primary hotkey: always speak the current selection. If something is
    /// already playing, the new read replaces it; an empty selection leaves
    /// current playback untouched. (Q-5 revisited by user request — stopping
    /// is the pause hotkey's and the menu's job.)
    func speakOrStop() {
        // Routing is decided on the app that is frontmost at hotkey time (P-8).
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = routing.action(for: bundleID)
        if action == .block {
            NSSound.beep()
            flashStatus("Speaking blocked for this app")
            SRLog.event("routing.blocked", [:])
            return
        }
        // Capture must run off the main thread: the ⌘C fallback sleeps
        // while polling the pasteboard. Strong capture is fine — AppState
        // lives for the app's lifetime and the task is short.
        guard !captureInFlight else { return }
        captureInFlight = true
        let preparation = preparationGeneration
        Task.detached { [self] in
            let result = SelectionCapture.capture()
            await MainActor.run {
                captureInFlight = false
                // Let capture restore the clipboard, but never let a late
                // completion undo Stop or replace a newer read.
                guard preparationGeneration == preparation else { return }
                handleCapture(result, fallbackRoutingAction: action)
            }
        }
    }

    func speakClipboard() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = routing.action(for: bundleID)
        if action == .block {
            NSSound.beep()
            flashStatus("Speaking blocked for this app")
            SRLog.event("routing.blocked", ["source": "clipboard"])
            return
        }
        if playback.isActive { stop() }
        handleCapture(SelectionCapture.clipboardText(), fallbackRoutingAction: action)
    }

    func stop() {
        // Invalidate callbacks already queued on the main actor as well as
        // cancelling their tasks. They must not change a replacement session.
        speakGeneration += 1
        preparationGeneration += 1
        preparationTask?.cancel()
        preparationTask = nil
        pipeline.cancel()
        playback.stop()
        activeUsesCloud = false
    }

    private func handleCapture(_ result: SelectionCapture.CaptureResult,
                               fallbackRoutingAction: RoutingPolicy.Action) {
        switch result {
        case .accessibilityDenied:
            accessibilityGranted = false
            promptForAccessibility()
        case .concealed:
            NSSound.beep()
            flashStatus("Concealed content skipped")
        case .empty:
            // Leave any current playback running — a missed selection
            // shouldn't kill the read in progress.
            NSSound.beep()
            flashStatus("No selection found")
        case .text(let raw, let method, let sourceBundleID):
            // Re-resolve against the element that actually supplied the text.
            // Focus can change while the detached AX/clipboard capture runs.
            let routingAction = sourceBundleID.map { routing.action(for: $0) }
                ?? fallbackRoutingAction
            if routingAction == .block {
                NSSound.beep()
                flashStatus("Speaking blocked for this app")
                SRLog.event("routing.blocked", ["source": method.rawValue])
                return
            }
            speak(raw, language: speechLanguage,
                  captureMethod: method, routingAction: routingAction)
        }
    }

    /// Resolve primary/fallback providers from backend mode + routing (F-3, P-8).
    private func resolveRoutes(routingAction: RoutingPolicy.Action)
        -> (primary: SynthesisPipeline.Route, fallback: SynthesisPipeline.Route?, isLocal: Bool)? {
        let wantsLocal = backendMode == .local || routingAction == .forceLocal
        let kokoroReady = KokoroRuntime.shared.isInstalled

        let localRoute = SynthesisPipeline.Route(
            provider: KokoroProvider(), voiceID: localVoiceID, modelID: KokoroProvider.cacheModelID)
        let cloudRoute = SynthesisPipeline.Route(
            provider: ElevenLabsProvider(modelID: modelID), voiceID: voiceID, modelID: modelID)

        let plan = BackendRouting.plan(
            mode: backendMode,
            forceLocal: wantsLocal,
            localAvailable: kokoroReady,
            hasCloudCredential: KeychainStore.readAPIKey() != nil)

        switch plan {
        case .localUnavailable:
            lastError = "Local voice not installed — use \"Install Local Voice\" in the menu."
            flashStatus(lastError!)
            return nil
        case .localOnly:
            return (localRoute, nil, true)
        case .cloudOnly:
            return (cloudRoute, nil, false)
        case .cloudWithLocalFallback:
            return (cloudRoute, localRoute, false)
        }
    }

    private func speak(_ raw: String,
                       language: SpeechLanguage,
                       captureMethod: SelectionCapture.Method,
                       routingAction: RoutingPolicy.Action) {
        guard raw.count <= Chunker.maxReadCharacters else {
            lastError = "Selection is too large (maximum \(Chunker.maxReadCharacters.formatted()) characters)."
            flashStatus(lastError!)
            return
        }
        preparationGeneration += 1
        let preparation = preparationGeneration
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                () -> (String, [Chunk])? in
                guard !Task.isCancelled else { return nil }
                let normalized = Normalizer.normalize(raw, language: language)
                guard !Task.isCancelled else { return nil }
                let chunks = Chunker.split(normalized)
                guard !Task.isCancelled else { return nil }
                return (normalized, chunks)
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  self.preparationGeneration == preparation,
                  let prepared else { return }
            self.preparationTask = nil
            self.beginPreparedSpeak(
                normalized: prepared.0,
                chunks: prepared.1,
                captureMethod: captureMethod,
                routingAction: routingAction)
        }
    }

    private func beginPreparedSpeak(
        normalized: String,
        chunks: [Chunk],
        captureMethod: SelectionCapture.Method,
        routingAction: RoutingPolicy.Action
    ) {
        guard !chunks.isEmpty else {
            flashStatus("Nothing to speak")
            return
        }
        guard normalized.count <= Chunker.maxReadCharacters else {
            lastError = "Selection is too large (maximum \(Chunker.maxReadCharacters.formatted()) characters)."
            flashStatus(lastError!)
            return
        }
        guard var routes = resolveRoutes(routingAction: routingAction) else { return }

        // Budget gate (C-2) — cloud reads only.
        if !routes.isLocal {
            switch ledger.verdict() {
            case .exceeded(let spent, let budget):
                if let localChoice = budgetExceededDialog(spent: spent, budget: budget) {
                    if localChoice {
                        guard let local = resolveLocalOnlyRoute() else { return }
                        routes = (local, nil, true)
                    } // else: override chosen, continue on cloud
                } else {
                    return
                }
            case .warning(let spent, let budget):
                flashStatus("Budget: \(spent.formatted()) of \(budget.formatted()) today")
            case .ok:
                break
            }
        }

        // Large-read confirmation (C-3) — cloud reads only.
        if !routes.isLocal && normalized.count >= ledger.largeReadThreshold {
            switch largeReadDialog(characters: normalized.count) {
            case .cancel:
                return
            case .speakLocally:
                guard let local = resolveLocalOnlyRoute() else { return }
                routes = (local, nil, true)
            case .speakCloud:
                break
            }
        }

        SRLog.event("speak.start", [
            "capture": captureMethod.rawValue,
            "chars": String(normalized.count),
            "sentences": String(chunks.count),
            "backend": routes.isLocal ? "local" : "cloud",
        ])

        // Cancel the old pipeline BEFORE starting the new session, and tag
        // this run: an old chunk already past its cancellation check would
        // otherwise deliver the previous text's audio into the new timeline.
        pipeline.cancel()
        speakGeneration += 1
        let generation = speakGeneration

        playback.startSession(totalSentences: chunks.count)
        activeUsesCloud = !routes.isLocal
        playback.onFinished = { [weak self] in
            self?.activeUsesCloud = false
            self?.refreshCredits()
        }
        playback.onError = { [weak self] message in
            guard let self else { return }
            self.pipeline.cancel()
            self.activeUsesCloud = false
            self.lastError = message
            self.flashStatus(message)
            NSSound.beep()
        }

        let deleteHistory = autoDeleteHistory
        let janitor = janitor
        let ledger = ledger
        let cloudBudgetRemaining = !routes.isLocal && !ledger.overriddenToday
            ? max(ledger.dailyBudget - ledger.spentToday, 0)
            : nil
        pipeline.run(
            chunks: chunks,
            primary: routes.primary,
            fallback: routes.fallback,
            settings: settings.voiceSettings,
            cache: cacheEnabled ? AudioCache.shared : nil,
            cloudBudgetRemaining: cloudBudgetRemaining,
            shouldSynthesize: { [weak self] index in
                guard let self, self.speakGeneration == generation else { return false }
                return SynthesisPipeline.needsChunk(
                    index, currentSentence: self.playback.currentSentence,
                    isPlaying: self.playback.state == .playing)
            },
            callbacks: .init(
                deliver: { [weak self] index, audio in
                    guard let self, self.speakGeneration == generation else { return }
                    self.playback.feed(index: index, audio: audio)
                },
                billed: { billed in
                    ledger.record(billedCharacters: billed)
                },
                historyID: { [self] id in
                    guard deleteHistory else { return }
                    Task {
                        await janitor.enqueue(id)
                        let line = await janitor.statusLine
                        await MainActor.run { historyStatus = line }
                    }
                },
                fellBack: { [weak self] in
                    guard let self, self.speakGeneration == generation else { return }
                    // A fallback only reroutes future chunks. Other workers
                    // may still have cloud requests in flight, so retain the
                    // cloud flag until this session finishes or is stopped.
                    self.flashStatus("Cloud unavailable — using local voice")
                },
                failed: { [weak self] error in
                    guard let self, self.speakGeneration == generation else { return }
                    self.handleSynthesisError(error)
                }
            )
        )
    }

    private func resolveLocalOnlyRoute() -> SynthesisPipeline.Route? {
        guard KokoroRuntime.shared.isInstalled else {
            lastError = "Local voice not installed — use \"Install Local Voice\" in the menu."
            flashStatus(lastError!)
            return nil
        }
        return SynthesisPipeline.Route(
            provider: KokoroProvider(), voiceID: localVoiceID, modelID: KokoroProvider.cacheModelID)
    }

    // MARK: - Dialogs (C-2 / C-3)

    /// Returns nil = cancel; false = override budget (speak cloud); true = speak locally.
    private func budgetExceededDialog(spent: Int, budget: Int) -> Bool? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Daily budget reached"
        alert.informativeText =
            "You've spent \(spent.formatted()) of your \(budget.formatted())-character daily budget."
        alert.addButton(withTitle: KokoroRuntime.shared.isInstalled
            ? "Speak Locally (free)" : "Cancel")
        alert.addButton(withTitle: "Override for Today")
        if KokoroRuntime.shared.isInstalled {
            alert.addButton(withTitle: "Cancel")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return KokoroRuntime.shared.isInstalled ? true : nil
        case .alertSecondButtonReturn:
            ledger.overriddenToday = true
            return false
        default:
            return nil
        }
    }

    private enum LargeReadChoice { case speakCloud, speakLocally, cancel }

    private func largeReadDialog(characters: Int) -> LargeReadChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Large selection"
        alert.informativeText =
            "≈\(characters.formatted()) characters — roughly \((characters / 2).formatted())–\(characters.formatted()) credits depending on model."
        alert.addButton(withTitle: "Speak with ElevenLabs")
        if KokoroRuntime.shared.isInstalled {
            alert.addButton(withTitle: "Speak Locally (free)")
        }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .speakCloud
        case .alertSecondButtonReturn where KokoroRuntime.shared.isInstalled:
            return .speakLocally
        default:
            return .cancel
        }
    }

    // MARK: - Kokoro install (P-12)

    func installKokoro() {
        guard kokoroInstallStatus == nil else { return }
        guard let source = daemonScriptSource(),
              let requirementsLock = requirementsLockSource() else {
            lastError = "Local voice installer resources are missing from the app bundle."
            flashStatus(lastError!)
            return
        }
        kokoroInstallStatus = "Starting…"
        // Strong capture: install must outlive any UI churn, and AppState
        // lives for the app's lifetime.
        installTask = Task { [self] in
            defer { installTask = nil }
            for await progress in KokoroRuntime.shared.installer.install(
                daemonSourceURL: source,
                requirementsLockURL: requirementsLock) {
                switch progress {
                case .creatingVenv: kokoroInstallStatus = "Creating Python environment…"
                case .installingPackages: kokoroInstallStatus = "Installing mlx-audio…"
                case .downloadingModel: kokoroInstallStatus = "Downloading Kokoro model (~330 MB)…"
                case .verifying: kokoroInstallStatus = "Verifying checksums…"
                case .done:
                    kokoroInstallStatus = nil
                    kokoroInstalled = true
                    kokoroNeedsUpdate = false
                    flashStatus("Local voice installed")
                case .failed(let message):
                    kokoroInstallStatus = nil
                    lastError = "Local install failed: \(message)"
                    flashStatus(lastError ?? "Install failed")
                }
            }
        }
    }

    private func daemonScriptSource() -> URL? {
        if let bundled = Bundle.main.url(forResource: "sr_tts_server", withExtension: "py") {
            return bundled
        }
        // Dev fallback: running from the repo via `swift run`.
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/sr_tts_server.py")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    private func requirementsLockSource() -> URL? {
        if let bundled = Bundle.main.url(
            forResource: "kokoro-requirements", withExtension: "lock") {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("daemon/requirements.lock")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    // MARK: - Cache actions (P-10)

    func purgeCache() {
        AudioCache.shared.purge()
        flashStatus("Cache purged")
    }

    // MARK: - Error surface (F-11 minimal)

    private func handleSynthesisError(_ error: TTSError) {
        stop()
        NSSound.beep()
        switch error {
        case .missingAPIKey:
            lastError = "No ElevenLabs API key — add one in Settings."
        case .http(401, _), .http(403, _):
            lastError = "ElevenLabs auth failed — check your API key."
        case .http(402, _):
            lastError = "This voice needs a paid ElevenLabs plan — pick another voice."
        case .http(429, _):
            lastError = "ElevenLabs quota exceeded."
        case .http(let status, _):
            lastError = "Synthesis error (HTTP \(status))."
        case .invalidAudio:
            lastError = "ElevenLabs returned invalid audio; the read was stopped."
        case .network("kokoro: incompatible daemon"):
            lastError = "Local voice needs a restart — quit all sr instances, then reopen sr."
        case .network(let detail) where detail.hasPrefix("kokoro"):
            lastError = "Local voice unavailable."
        case .network:
            lastError = "Could not reach ElevenLabs."
        case .cancelled:
            return
        case .budgetExceeded:
            lastError = "Daily cloud budget reached — the remaining text was not sent."
        }
        flashStatus(lastError ?? "Error")
    }

    // MARK: - Voices (F-10)

    func refreshVoices(force: Bool = false) {
        if !force, let at = voicesFetchedAt, Date().timeIntervalSince(at) < 3600 { return }
        Task { [weak self] in
            guard let self else { return }
            guard let voices = try? await ElevenLabsProvider().voices(), !voices.isEmpty else { return }
            self.availableVoices = voices
            self.voicesFetchedAt = Date()
            // If the selected voice isn't usable on this account (e.g. a
            // library voice that 402s on free plans), fall back to the first.
            if !voices.contains(where: { $0.id == self.voiceID }),
               !ElevenLabsProvider.presetVoices.contains(where: { $0.id == self.voiceID }) {
                self.voiceID = voices[0].id
            }
        }
    }

    // MARK: - Credits (C-1)

    func refreshCredits() {
        Task { [weak self] in
            guard let self else { return }
            guard let sub = try? await ElevenLabsProvider().subscription() else { return }
            self.creditsRemaining = sub.remaining
            self.creditsLimit = sub.characterLimit
        }
    }

    // MARK: - Shortcuts

    func resetShortcutsToDefaults() {
        KeyboardShortcuts.reset(.speakOrStop, .pauseResume)
    }

    // MARK: - Accessibility onboarding

    func promptForAccessibility() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // Poll until granted so the UI banner clears without a relaunch.
        Task { @MainActor [weak self] in
            while !AXIsProcessTrusted() {
                try? await Task.sleep(for: .seconds(1))
                if self == nil { return }
            }
            self?.accessibilityGranted = true
        }
    }

    // MARK: - Helpers

    private func flashStatus(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.statusMessage = nil }
        }
    }
}
