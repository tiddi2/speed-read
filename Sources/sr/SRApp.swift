import KeyboardShortcuts
import SRCore
import SwiftUI

@MainActor
final class SRAppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?
    private var terminationPending = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await SRAppDelegate.state?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SRApp: App {
    @NSApplicationDelegateAdaptor(SRAppDelegate.self) private var appDelegate
    @StateObject private var state: AppState

    init() {
        // Wire the delegate here, not in MenuView.onAppear: MenuBarExtra
        // content is built lazily on first open, so a quit before the menu
        // was ever opened would find state == nil and skip shutdown()
        // (pending history deletes lost, daemon left to the watchdog).
        let state = AppState()
        _state = StateObject(wrappedValue: state)
        SRAppDelegate.state = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(state)
        } label: {
            Image(systemName: state.playback.isActive
                  ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)

        // Real window: unlike the MenuBarExtra panel it becomes key, so the
        // shortcut recorders and the API-key field actually receive input.
        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

// MARK: - Menu panel
//
// Transport only. Everything that configures sr — voices, models, backend,
// privacy, cost, hotkeys — lives in Settings (⌘,) so the panel stays a remote
// control you can hit in one motion instead of a preferences sheet.

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transportCluster
            progressSection
            speedSection
            Divider()
            clipboardSection
            statusSection
            Divider()
            bottomRow
        }
        .padding(14)
        .frame(width: 336, alignment: .leading)
    }

    // MARK: Transport (F-7) — the panel's hero: open menu → hit a control
    // in one motion. Big central play/pause, generous circular hit areas,
    // hover rings for click confidence.

    private var transportCluster: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            TransportButton(systemName: "backward.end.fill",
                            size: 28, iconSize: 10,
                            help: "Restart from the top") {
                state.playback.restart()
            }
            TransportButton(systemName: "backward.frame.fill",
                            size: 32, iconSize: 12,
                            help: "Previous sentence") {
                state.playback.seekSentence(by: -1)
            }
            TransportButton(systemName: "gobackward.5",
                            size: 36, iconSize: 15,
                            help: "Back 5 seconds") {
                state.playback.seek(by: -5)
            }
            TransportButton(systemName: isPaused || !state.playback.isActive
                                ? "play.fill" : "pause.fill",
                            size: 44, iconSize: 18, prominent: true,
                            help: isPaused ? "Resume" : "Pause") {
                state.playback.togglePauseResume()
            }
            TransportButton(systemName: "goforward.5",
                            size: 36, iconSize: 15,
                            help: "Forward 5 seconds") {
                state.playback.seek(by: 5)
            }
            TransportButton(systemName: "forward.frame.fill",
                            size: 32, iconSize: 12,
                            help: "Next sentence") {
                state.playback.seekSentence(by: 1)
            }
            TransportButton(systemName: "stop.fill",
                            size: 28, iconSize: 10,
                            help: "Stop") {
                state.stop()
            }
            Spacer(minLength: 0)
        }
        .disabled(!state.playback.isActive)
    }

    private var isPaused: Bool { state.playback.state == .paused }

    @ViewBuilder
    private var progressSection: some View {
        if state.playback.isActive {
            VStack(spacing: 4) {
                ProgressView(value: min(state.playback.currentSeconds,
                                        state.playback.availableSeconds),
                             total: max(state.playback.availableSeconds, 0.01))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(.accentColor)
                HStack(spacing: 6) {
                    if state.playback.state == .paused {
                        Text("Paused").fontWeight(.medium)
                    }
                    Text("Sentence \(state.playback.currentSentence + 1) of \(state.playback.totalSentences)")
                    Spacer()
                    Text("\(timeString(state.playback.currentSeconds)) / \(timeString(state.playback.availableSeconds))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(spacing: 2) {
                Text("Select text anywhere, then press")
                ForEach(SpeechLanguage.allCases) { language in
                    Text("\(shortcutHint(for: language)) for \(language.displayName)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func shortcutHint(for language: SpeechLanguage) -> String {
        KeyboardShortcuts.getShortcut(for: ShortcutCatalog.speakName(for: language))?
            .description ?? "an unset hotkey"
    }

    // MARK: Speed (F-8) — slider for fine control, chips for the speeds
    // you actually use without needing slider precision.

    private var speedSection: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "tortoise").imageScale(.small)
                    .foregroundStyle(.secondary)
                Slider(value: $state.playbackRate, in: 0.5...3.0, step: 0.1)
                Image(systemName: "hare").imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f×", state.playbackRate))
                    .font(.caption.monospacedDigit().weight(.medium))
                    .frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 6) {
                ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { preset in
                    SpeedChip(value: preset,
                              isActive: abs(state.playbackRate - preset) < 0.05) {
                        state.playbackRate = preset
                    }
                }
            }
        }
    }

    // MARK: Clipboard — one button per language. sr never guesses which
    // language a clipboard holds (see SpeechLanguage).

    private var clipboardSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speak Clipboard")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(SpeechLanguage.allCases) { language in
                    Button {
                        state.speakClipboard(language: language)
                    } label: {
                        Text(language.displayName)
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help(clipboardHelp(for: language))
                }
            }
        }
    }

    private func clipboardHelp(for language: SpeechLanguage) -> String {
        let shortcut = KeyboardShortcuts.getShortcut(
            for: ShortcutCatalog.clipboardName(for: language))
        return shortcut.map { "Speak the clipboard in \(language.displayName) (\($0))" }
            ?? "Speak the clipboard in \(language.displayName)"
    }

    // MARK: Status — only what needs acting on right now.

    @ViewBuilder
    private var statusSection: some View {
        if !state.accessibilityGranted {
            Button {
                state.promptForAccessibility()
            } label: {
                Label("Grant Accessibility (reads your selection)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
        }
        if let message = state.statusMessage {
            Text(message).font(.caption).foregroundStyle(.orange)
        }
        if let installStatus = state.kokoroInstallStatus {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(installStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var bottomRow: some View {
        HStack {
            Button("Settings…") {
                // Accessory apps never truly become active, so key events
                // bypass their windows (the shortcut recorder would focus but
                // receive nothing). Become a regular app while Settings is
                // open; SettingsView.onDisappear restores accessory mode.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Spacer()
            Button("Quit sr") {
                NSApplication.shared.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Transport components

/// Circular transport control with a hover ring and a full-circle hit area.
/// `prominent` renders as the accent-filled hero (play/pause).
private struct TransportButton: View {
    let systemName: String
    var size: CGFloat = 36
    var iconSize: CGFloat = 15
    var prominent = false
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                if prominent {
                    Circle().fill(Color.accentColor)
                    if hovering && isEnabled {
                        Circle().fill(.white.opacity(0.15))
                    }
                } else if hovering && isEnabled {
                    Circle().fill(.quaternary)
                }
                Image(systemName: systemName)
                    .font(.system(size: iconSize, weight: .semibold))
                    .foregroundStyle(prominent ? AnyShapeStyle(.white)
                                               : AnyShapeStyle(.primary))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Full-width backend selector styled to match the panel's rounded
/// language (same radius family as the Speak Clipboard button): a soft
/// container, equal-width segments, accent fill on the active one.
private struct BackendSelector: View {
    @Binding var selection: SettingsStore.BackendMode

    var body: some View {
        HStack(spacing: 3) {
            segment(.auto, title: "Auto", icon: nil,
                    help: "Cloud voices, local fallback if the cloud fails")
            segment(.cloud, title: "Cloud", icon: nil,
                    help: "ElevenLabs only")
            segment(.local, title: "Local", icon: "lock.fill",
                    help: "Nothing ever leaves this Mac")
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .animation(.easeOut(duration: 0.15), value: selection)
    }

    private func segment(_ mode: SettingsStore.BackendMode,
                         title: String, icon: String?, help: String) -> some View {
        BackendSegment(
            title: title,
            icon: icon,
            isActive: selection == mode,
            help: help
        ) {
            selection = mode
        }
    }
}

private struct BackendSegment: View {
    let title: String
    let icon: String?
    let isActive: Bool
    let help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(isActive ? 1 : 0.55)
                }
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                        ? AnyShapeStyle(Color.accentColor)
                        : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One-click speed preset.
private struct SpeedChip: View {
    let value: Double
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospacedDigit().weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isActive
                        ? AnyShapeStyle(Color.accentColor.opacity(0.25))
                        : hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                )
                .overlay(
                    Capsule().strokeBorder(
                        isActive ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25),
                        lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var label: String {
        value == value.rounded() ? String(format: "%.0f×", value)
                                 : String(format: "%.2g×", value)
    }
}

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            VoiceSettingsTab()
                .tabItem { Label("Voices", systemImage: "waveform") }
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            PrivacySettings()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            CostSettings()
                .tabItem { Label("Cost", systemImage: "creditcard") }
        }
        .frame(width: 520, height: 460)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            state.refreshVoices()
            // The Settings window can open behind the menu bar panel;
            // bring it to front once it exists.
            DispatchQueue.main.async {
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: General (F-3, P-8, P-12)

private struct GeneralSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Backend") {
                BackendSelector(selection: $state.backendMode)
                Text(backendCaption)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Offline voice") {
                if let installStatus = state.kokoroInstallStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(installStatus).font(.callout)
                    }
                } else if state.kokoroInstalled && !state.kokoroNeedsUpdate {
                    Label("Kokoro installed", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Button(state.kokoroNeedsUpdate
                           ? "Update Local Voice Runtime…"
                           : "Install Local Voice (Kokoro, ~330 MB)…") {
                        state.installKokoro()
                    }
                }
                Text("Kokoro speaks English only. Norwegian reads always use ElevenLabs, and are refused in Local-Only mode rather than read with an English voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Permissions") {
                if state.accessibilityGranted {
                    Label("Accessibility granted", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Button("Grant Accessibility…") { state.promptForAccessibility() }
                    Text("Required to read the selection in other apps. The hotkeys themselves work without it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var backendCaption: String {
        switch state.backendMode {
        case .auto: return "Cloud voices, local fallback if the cloud fails"
        case .cloud: return "ElevenLabs only"
        case .local: return "Nothing ever leaves this Mac"
        }
    }
}

// MARK: Voices — one profile per language (F-10)

private struct VoiceSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            ForEach(SpeechLanguage.allCases) { language in
                Section(language.displayName) {
                    Picker("Voice", selection: voiceBinding(language)) {
                        ForEach(state.availableVoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                        let selected = state.voiceID(for: language)
                        if !state.availableVoices.contains(where: { $0.id == selected }) {
                            Text("Custom (\(String(selected.prefix(8)))…)").tag(selected)
                        }
                    }
                    Picker("Model", selection: modelBinding(language)) {
                        ForEach(ElevenLabsProvider.models, id: \.id) { model in
                            Text(modelLabel(model)).tag(model.id)
                        }
                    }
                    if !state.languageIsLocked(language) {
                        Label(
                            "This model can't be pinned to \(language.displayName) — ElevenLabs will detect the language from the text instead. Pick Flash v2.5 or Turbo v2.5 to lock it.",
                            systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    localVoiceRow(language)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func localVoiceRow(_ language: SpeechLanguage) -> some View {
        let localVoices = KokoroProvider.presetVoices(for: language)
        if localVoices.isEmpty {
            Text("No offline voice — \(language.displayName) is cloud-only.")
                .font(.caption).foregroundStyle(.secondary)
        } else if state.kokoroInstalled {
            Picker("Offline voice", selection: localVoiceBinding(language)) {
                ForEach(localVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        }
    }

    private func modelLabel(_ model: (name: String, id: String)) -> String {
        ElevenLabsProvider.supportsLanguageLock(model.id)
            ? model.name
            : "\(model.name) — no language lock"
    }

    private func voiceBinding(_ language: SpeechLanguage) -> Binding<String> {
        Binding(get: { state.voiceID(for: language) },
                set: { state.setVoiceID($0, for: language) })
    }

    private func modelBinding(_ language: SpeechLanguage) -> Binding<String> {
        Binding(get: { state.modelID(for: language) },
                set: { state.setModelID($0, for: language) })
    }

    private func localVoiceBinding(_ language: SpeechLanguage) -> Binding<String> {
        Binding(get: { state.localVoiceID(for: language) ?? "" },
                set: { state.setLocalVoiceID($0, for: language) })
    }
}

// MARK: Shortcuts — every hotkey sr registers is rebindable here

private struct ShortcutSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            ForEach(ShortcutCatalog.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.bindings) { binding in
                        LabeledContent(binding.title) {
                            ShortcutRecorderField(name: binding.name)
                        }
                        if let note = binding.note {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button("Reset Shortcuts to Defaults") {
                    state.resetShortcutsToDefaults()
                }
                Text("Click a field and type the combination. ⎋ cancels, ⌫ clears it. A cleared shortcut simply never fires.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Privacy (P-6, P-10)

private struct PrivacySettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("ElevenLabs history") {
                Toggle("Auto-delete generations from my account", isOn: $state.autoDeleteHistory)
                if !state.historyStatus.isEmpty {
                    Text(state.historyStatus)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Audio cache") {
                Toggle("Cache audio on disk", isOn: $state.cacheEnabled)
                    .help("Disable for sensitive sessions — nothing is written to disk")
                Button("Purge Audio Cache") { state.purgeCache() }
                Text("Cached audio makes a repeated read instant and free. Filenames are hashes, never text.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Cost (C-1, C-2, C-3) + the API key (P-1)

private struct CostSettings: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeySavedFlash = false
    @State private var apiKeySaveError: String?

    var body: some View {
        Form {
            Section("ElevenLabs API key") {
                HStack {
                    SecureField(
                        KeychainStore.maskedAPIKey() ?? "API key",
                        text: $apiKeyDraft
                    )
                    Button("Save") { saveAPIKey() }
                }
                if apiKeySavedFlash {
                    Text("Saved to Keychain").font(.caption).foregroundStyle(.green)
                }
                if let apiKeySaveError {
                    Text(apiKeySaveError).font(.caption).foregroundStyle(.red)
                }
                Text("Stored only in the macOS Keychain. Scope the key to Text-to-Speech + User Read.")
                    .font(.caption).foregroundStyle(.secondary)
                if let remaining = state.creditsRemaining, let limit = state.creditsLimit {
                    LabeledContent("Credits") {
                        Text("\(remaining.formatted()) of \(limit.formatted()) left")
                            .monospacedDigit()
                    }
                }
            }

            Section("Budget") {
                let ledger = state.ledger
                LabeledContent("Daily budget") {
                    TextField("characters", value: Binding(
                        get: { ledger.dailyBudget },
                        set: { ledger.dailyBudget = max(0, $0) }
                    ), format: .number)
                    .frame(width: 100)
                }
                LabeledContent("Confirm reads above") {
                    TextField("characters", value: Binding(
                        get: { ledger.largeReadThreshold },
                        set: { ledger.largeReadThreshold = max(0, $0) }
                    ), format: .number)
                    .frame(width: 100)
                }
                let spent = ledger.spentToday
                if spent > 0 {
                    Text("\(spent.formatted()) characters spent today")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard KeychainStore.saveAPIKey(trimmed) else {
            apiKeySavedFlash = false
            apiKeySaveError = "Keychain rejected the update. Unlock your login keychain and try again."
            return
        }
        apiKeyDraft = ""
        apiKeySavedFlash = true
        apiKeySaveError = nil
        state.refreshCredits()
        state.refreshVoices(force: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            apiKeySavedFlash = false
        }
    }
}
