import AppKit
import Combine
import Foundation
@preconcurrency import KeyboardShortcuts
import SRCore
import SwiftUI

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
    // Voice/model are per language (SpeechLanguage): a read is always started
    // for a specific language and never switches to another one.
    @Published private var voiceIDByLanguage: [SpeechLanguage: String]
    @Published private var modelIDByLanguage: [SpeechLanguage: String]
    @Published private var localVoiceIDByLanguage: [SpeechLanguage: String]

    func voiceID(for language: SpeechLanguage) -> String {
        voiceIDByLanguage[language] ?? settings.voiceID(for: language)
    }

    func setVoiceID(_ voiceID: String, for language: SpeechLanguage) {
        voiceIDByLanguage[language] = voiceID
        settings.setVoiceID(voiceID, for: language)
    }

    func modelID(for language: SpeechLanguage) -> String {
        modelIDByLanguage[language] ?? settings.modelID(for: language)
    }

    func setModelID(_ modelID: String, for language: SpeechLanguage) {
        modelIDByLanguage[language] = modelID
        settings.setModelID(modelID, for: language)
    }

    /// nil when the local model has no voice for this language (Norwegian).
    func localVoiceID(for language: SpeechLanguage) -> String? {
        localVoiceIDByLanguage[language] ?? settings.localVoiceID(for: language)
    }

    func setLocalVoiceID(_ voiceID: String, for language: SpeechLanguage) {
        // Never let a voice from another language become this language's local
        // voice — that is exactly the substitution language profiles prevent.
        guard language.ownsLocalVoice(voiceID) else { return }
        localVoiceIDByLanguage[language] = voiceID
        settings.setLocalVoiceID(voiceID, for: language)
    }

    /// True when `language` will actually be pinned on the request. False means
    /// the chosen model detects the language from the text instead — surfaced
    /// as a warning in Settings.
    func languageIsLocked(_ language: SpeechLanguage) -> Bool {
        ElevenLabsProvider.supportsLanguageLock(modelID(for: language))
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

    // MARK: Reader overlay

    /// The text of the read in progress, for the reader overlay. Held only
    /// while sr is actually speaking and dropped on stop — the overlay is a
    /// view of the current read, never a transcript sr keeps around.
    struct ReadingSession {
        let language: SpeechLanguage
        /// Normalized sentences, in order: exactly the strings that were sent
        /// to the synthesizer, so what is shown is what is being said.
        let sentences: [String]

        /// nil outside the read, which is what the overlay's context lines
        /// want at the first and last sentence.
        func sentence(at index: Int) -> String? {
            sentences.indices.contains(index) ? sentences[index] : nil
        }
    }

    @Published private(set) var reading: ReadingSession?
    let readerOverlay = ReaderOverlayController()

    @Published var readerOverlayEnabled: Bool {
        didSet {
            settings.readerOverlayEnabled = readerOverlayEnabled
            readerOverlayDismissed = false
            updateReaderOverlay()
        }
    }
    @Published var readerShowsPreviousSentence: Bool {
        didSet {
            settings.readerShowsPreviousSentence = readerShowsPreviousSentence
            readerOverlay.relayout()
        }
    }
    @Published var readerShowsCurrentSentence: Bool {
        didSet {
            settings.readerShowsCurrentSentence = readerShowsCurrentSentence
            readerOverlay.relayout()
        }
    }
    @Published var readerShowsNextSentence: Bool {
        didSet {
            settings.readerShowsNextSentence = readerShowsNextSentence
            readerOverlay.relayout()
        }
    }

    var readerShowsAnySentence: Bool {
        readerShowsPreviousSentence || readerShowsCurrentSentence || readerShowsNextSentence
    }

    /// Hidden with the overlay's own ✕, for this read only.
    private var readerOverlayDismissed = false
    /// Where the pointer was when the read was started, so the overlay opens
    /// on the display the selection is on rather than wherever sr last drew.
    private var selectionPoint: NSPoint?
    /// Word splitting is cheap but the overlay asks for the current sentence
    /// ten times a second; parse each one once.
    private var parsedSentence: (index: Int, sentence: ReaderSentence)?

    /// The sentence being spoken, split into words. nil when nothing is
    /// playing or the read has no sentence at that index.
    var currentReaderSentence: ReaderSentence? {
        guard let reading else { return nil }
        let index = playback.currentSentence
        guard let text = reading.sentence(at: index) else { return nil }
        if let parsedSentence, parsedSentence.index == index {
            return parsedSentence.sentence
        }
        let parsed = ReaderSentence.parse(text)
        parsedSentence = (index, parsed)
        return parsed
    }

    /// Forget a dragged position and send the overlay back to the top-right
    /// of the screen the current read started on.
    func resetReaderOverlayPosition() {
        settings.resetReaderOverlayPosition()
        readerOverlay.reposition(near: selectionPoint)
    }

    /// Hide the overlay for the current read without changing the setting.
    func dismissReaderOverlay() {
        readerOverlayDismissed = true
        readerOverlay.hide()
    }

    /// Hotkey: hide the reader, or bring it back. Turning it off this way
    /// sticks for the next read too; the overlay's own ✕ is the "just this
    /// read" version.
    func toggleReaderOverlay() {
        if readerOverlayEnabled && !readerOverlayDismissed {
            readerOverlayEnabled = false
        } else if readerOverlayEnabled {
            // Dismissed by the ✕ but still enabled — restore it.
            readerOverlayDismissed = false
            updateReaderOverlay()
        } else {
            readerOverlayEnabled = true
        }
    }

    private func updateReaderOverlay() {
        guard reading != nil, readerOverlayEnabled, !readerOverlayDismissed else {
            readerOverlay.hide()
            return
        }
        readerOverlay.show(state: self, near: selectionPoint)
    }

    /// Drop the on-screen text the moment the read ends.
    private func endReading() {
        reading = nil
        parsedSentence = nil
        readerOverlay.hide()
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
        var voices: [SpeechLanguage: String] = [:]
        var models: [SpeechLanguage: String] = [:]
        var localVoices: [SpeechLanguage: String] = [:]
        for language in SpeechLanguage.allCases {
            voices[language] = store.voiceID(for: language)
            models[language] = store.modelID(for: language)
            // Absent for a language the local model cannot speak (Norwegian).
            if let local = store.localVoiceID(for: language) {
                localVoices[language] = local
            }
        }
        voiceIDByLanguage = voices
        modelIDByLanguage = models
        localVoiceIDByLanguage = localVoices
        backendMode = store.backendMode
        autoDeleteHistory = store.autoDeleteHistory
        cacheEnabled = store.cacheEnabled
        readerOverlayEnabled = store.readerOverlayEnabled
        readerShowsPreviousSentence = store.readerShowsPreviousSentence
        readerShowsCurrentSentence = store.readerShowsCurrentSentence
        readerShowsNextSentence = store.readerShowsNextSentence
        AudioCache.shared.enabled = store.cacheEnabled

        // Pre-language-profile hotkey. Its stored value is dead now that every
        // read is language-scoped; drop it so it cannot linger as an orphan
        // registration in UserDefaults.
        UserDefaults.standard.removeObject(forKey: "KeyboardShortcuts_speakOrStop")

        registerShortcuts()

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

    /// Register every configurable hotkey. Keep in sync with ShortcutCatalog —
    /// a binding shown in Settings but not handled here would record fine and
    /// then do nothing.
    private func registerShortcuts() {
        for language in SpeechLanguage.allCases {
            KeyboardShortcuts.onKeyDown(for: ShortcutCatalog.speakName(for: language)) {
                [weak self] in
                Task { @MainActor in self?.speakSelection(language: language) }
            }
            KeyboardShortcuts.onKeyDown(for: ShortcutCatalog.clipboardName(for: language)) {
                [weak self] in
                Task { @MainActor in self?.speakClipboard(language: language) }
            }
        }
        KeyboardShortcuts.onKeyDown(for: .pauseResume) { [weak self] in
            Task { @MainActor in self?.playback.togglePauseResume() }
        }
        KeyboardShortcuts.onKeyDown(for: .stop) { [weak self] in
            Task { @MainActor in self?.stop() }
        }
        KeyboardShortcuts.onKeyDown(for: .previousSentence) { [weak self] in
            Task { @MainActor in self?.playback.seekSentence(by: -1) }
        }
        KeyboardShortcuts.onKeyDown(for: .nextSentence) { [weak self] in
            Task { @MainActor in self?.playback.seekSentence(by: 1) }
        }
        KeyboardShortcuts.onKeyDown(for: .seekBackward) { [weak self] in
            Task { @MainActor in self?.playback.seek(by: -5) }
        }
        KeyboardShortcuts.onKeyDown(for: .seekForward) { [weak self] in
            Task { @MainActor in self?.playback.seek(by: 5) }
        }
        KeyboardShortcuts.onKeyDown(for: .restart) { [weak self] in
            Task { @MainActor in self?.playback.restart() }
        }
        KeyboardShortcuts.onKeyDown(for: .speedDown) { [weak self] in
            Task { @MainActor in self?.nudgeRate(by: -0.1) }
        }
        KeyboardShortcuts.onKeyDown(for: .speedUp) { [weak self] in
            Task { @MainActor in self?.nudgeRate(by: 0.1) }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleReaderOverlay) { [weak self] in
            Task { @MainActor in self?.toggleReaderOverlay() }
        }
    }

    /// Step the playback rate, clamped to the supported 0.5×–3.0× range.
    func nudgeRate(by delta: Double) {
        let stepped = ((playbackRate + delta) * 10).rounded() / 10
        let clamped = min(max(stepped, 0.5), 3.0)
        guard abs(clamped - playbackRate) > 0.001 else { return }
        playbackRate = clamped
        flashStatus(String(format: "Speed %.1f×", clamped))
    }

    /// Speak the current selection in `language`. If something is already
    /// playing, the new read replaces it; an empty selection leaves current
    /// playback untouched. (Q-5 revisited by user request — stopping is the
    /// pause hotkey's and the menu's job.)
    func speakSelection(language: SpeechLanguage) {
        // Where the pointer is when the hotkey fires is the best available
        // proxy for which display the selection is on; AX gives no reliable
        // screen rect for a selection across apps. Read it now, not when the
        // overlay opens — by then the pointer may have moved.
        selectionPoint = NSEvent.mouseLocation
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
                handleCapture(result, language: language, fallbackRoutingAction: action)
            }
        }
    }

    func speakClipboard(language: SpeechLanguage) {
        selectionPoint = NSEvent.mouseLocation
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let action = routing.action(for: bundleID)
        if action == .block {
            NSSound.beep()
            flashStatus("Speaking blocked for this app")
            SRLog.event("routing.blocked", ["source": "clipboard"])
            return
        }
        if playback.isActive { stop() }
        handleCapture(SelectionCapture.clipboardText(),
                      language: language,
                      fallbackRoutingAction: action)
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
        endReading()
    }

    private func handleCapture(_ result: SelectionCapture.CaptureResult,
                               language: SpeechLanguage,
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
            speak(raw, language: language, captureMethod: method,
                  routingAction: routingAction)
        }
    }

    /// Resolve primary/fallback providers from backend mode + routing (F-3, P-8)
    /// for one language.
    ///
    /// A language the local model cannot speak (Norwegian) never gets a local
    /// route, not even as an Auto-mode fallback: falling back would read the
    /// text aloud in an English voice, which is the language substitution the
    /// per-language hotkeys exist to rule out. Such a read is cloud-only, and
    /// in Local-Only mode it is refused outright rather than mispronounced.
    private func resolveRoutes(language: SpeechLanguage,
                               routingAction: RoutingPolicy.Action)
        -> (primary: SynthesisPipeline.Route, fallback: SynthesisPipeline.Route?, isLocal: Bool)? {
        let wantsLocal = backendMode == .local || routingAction == .forceLocal
        let local = localRoute(for: language)
        let cloud = cloudRoute(for: language)

        let plan = BackendRouting.plan(
            mode: backendMode,
            forceLocal: wantsLocal,
            localAvailable: local != nil,
            hasCloudCredential: KeychainStore.readAPIKey() != nil)

        switch plan {
        case .localUnavailable:
            lastError = localUnavailableMessage(for: language)
            flashStatus(lastError!)
            return nil
        case .localOnly:
            guard let local else {
                lastError = localUnavailableMessage(for: language)
                flashStatus(lastError!)
                return nil
            }
            return (local, nil, true)
        case .cloudOnly:
            return (cloud, nil, false)
        case .cloudWithLocalFallback:
            // `local` is nil for a language Kokoro cannot speak, which is
            // precisely the intent: no fallback rather than a wrong-language one.
            return (cloud, local, false)
        }
    }

    private func cloudRoute(for language: SpeechLanguage) -> SynthesisPipeline.Route {
        let model = modelID(for: language)
        return SynthesisPipeline.Route(
            provider: ElevenLabsProvider(modelID: model, language: language),
            voiceID: voiceID(for: language),
            modelID: model,
            // Cache under the language that is actually pinned, so an
            // auto-detected recording is never replayed as a locked one.
            languageCode: ElevenLabsProvider.lockedLanguageCode(
                for: language, modelID: model) ?? "")
    }

    /// nil when the local model has no voice for `language`.
    private func localRoute(for language: SpeechLanguage) -> SynthesisPipeline.Route? {
        guard KokoroRuntime.shared.isInstalled,
              let localVoice = localVoiceID(for: language),
              language.isSpeakableLocally else { return nil }
        return SynthesisPipeline.Route(
            provider: KokoroProvider(language: language),
            voiceID: localVoice,
            modelID: KokoroProvider.cacheModelID,
            languageCode: language.rawValue)
    }

    private func localUnavailableMessage(for language: SpeechLanguage) -> String {
        language.isSpeakableLocally
            ? "Local voice not installed — install it in Settings → General."
            : "The offline voice has no \(language.displayName) — switch to Cloud or Auto in Settings."
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
                language: language,
                captureMethod: captureMethod,
                routingAction: routingAction)
        }
    }

    private func beginPreparedSpeak(
        normalized: String,
        chunks: [Chunk],
        language: SpeechLanguage,
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
        guard var routes = resolveRoutes(language: language,
                                         routingAction: routingAction) else { return }
        let localFallbackAvailable = localRoute(for: language) != nil

        // Budget gate (C-2) — cloud reads only.
        if !routes.isLocal {
            switch ledger.verdict() {
            case .exceeded(let spent, let budget):
                if let localChoice = budgetExceededDialog(
                    spent: spent, budget: budget,
                    localAvailable: localFallbackAvailable) {
                    if localChoice {
                        guard let local = localRoute(for: language) else { return }
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
            switch largeReadDialog(characters: normalized.count,
                                   localAvailable: localFallbackAvailable) {
            case .cancel:
                return
            case .speakLocally:
                guard let local = localRoute(for: language) else { return }
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
            "lang": language.rawValue,
        ])

        // Cancel the old pipeline BEFORE starting the new session, and tag
        // this run: an old chunk already past its cancellation check would
        // otherwise deliver the previous text's audio into the new timeline.
        pipeline.cancel()
        speakGeneration += 1
        let generation = speakGeneration

        playback.startSession(totalSentences: chunks.count)
        activeUsesCloud = !routes.isLocal
        // The overlay reads from `reading`; publish before showing it so its
        // first frame has the opening sentence rather than an empty pane.
        reading = ReadingSession(language: language,
                                 sentences: chunks.map(\.text))
        parsedSentence = nil
        readerOverlayDismissed = false
        updateReaderOverlay()
        playback.onFinished = { [weak self] in
            self?.activeUsesCloud = false
            self?.endReading()
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

    // MARK: - Dialogs (C-2 / C-3)

    /// Returns nil = cancel; false = override budget (speak cloud); true = speak
    /// locally. `localAvailable` is false when the local voice is missing *or*
    /// cannot speak this read's language, so the free option is not offered.
    private func budgetExceededDialog(spent: Int, budget: Int,
                                      localAvailable: Bool) -> Bool? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Daily budget reached"
        alert.informativeText =
            "You've spent \(spent.formatted()) of your \(budget.formatted())-character daily budget."
        alert.addButton(withTitle: localAvailable
            ? "Speak Locally (free)" : "Cancel")
        alert.addButton(withTitle: "Override for Today")
        if localAvailable {
            alert.addButton(withTitle: "Cancel")
        }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return localAvailable ? true : nil
        case .alertSecondButtonReturn:
            ledger.overriddenToday = true
            return false
        default:
            return nil
        }
    }

    private enum LargeReadChoice { case speakCloud, speakLocally, cancel }

    private func largeReadDialog(characters: Int,
                                 localAvailable: Bool) -> LargeReadChoice {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Large selection"
        alert.informativeText =
            "≈\(characters.formatted()) characters — roughly \((characters / 2).formatted())–\(characters.formatted()) credits depending on model."
        alert.addButton(withTitle: "Speak with ElevenLabs")
        if localAvailable {
            alert.addButton(withTitle: "Speak Locally (free)")
        }
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .speakCloud
        case .alertSecondButtonReturn where localAvailable:
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
            lastError = "No ElevenLabs API key — add one in Settings → Cost."
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
        case .network("kokoro: language not installed"):
            lastError = "The offline voice cannot speak that language — switch to Cloud or Auto."
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
            // If a language's selected voice isn't usable on this account
            // (e.g. a library voice that 402s on free plans), fall back to the
            // first available one.
            for language in SpeechLanguage.allCases {
                let selected = self.voiceID(for: language)
                if !voices.contains(where: { $0.id == selected }),
                   !ElevenLabsProvider.presetVoices.contains(where: { $0.id == selected }) {
                    self.setVoiceID(voices[0].id, for: language)
                }
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
        KeyboardShortcuts.reset(ShortcutCatalog.allNames)
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
