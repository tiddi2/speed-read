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

// MARK: - Menu panel (quick controls only; text input lives in Settings)

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transportCluster
            progressSection
            speedSection
            Divider()
            speakClipboardButton
            backendPicker
            voicePickers
            Divider()
            privacySection
            statusSection
            Divider()
            bottomRow
        }
        .padding(14)
        .frame(width: 336, alignment: .leading)
        .onAppear { state.refreshVoices() }
    }

    // MARK: Transport (F-7) — the panel's hero: open menu → hit a control
    // in one motion. Big central play/pause, generous circular hit areas,
    // hover rings for click confidence.

    private var transportCluster: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            TransportButton(systemName: "backward.end.fill",
                            size: 30, iconSize: 11,
                            help: "Restart from the top") {
                state.playback.restart()
            }
            TransportButton(systemName: "gobackward.5",
                            size: 38, iconSize: 17,
                            help: "Back 5 seconds") {
                state.playback.seek(by: -5)
            }
            TransportButton(systemName: isPaused || !state.playback.isActive
                                ? "play.fill" : "pause.fill",
                            size: 46, iconSize: 19, prominent: true,
                            help: isPaused ? "Resume" : "Pause") {
                state.playback.togglePauseResume()
            }
            TransportButton(systemName: "goforward.5",
                            size: 38, iconSize: 17,
                            help: "Forward 5 seconds") {
                state.playback.seek(by: 5)
            }
            TransportButton(systemName: "stop.fill",
                            size: 30, iconSize: 11,
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
            Text("Select text anywhere, then press \(shortcutHint)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var shortcutHint: String {
        KeyboardShortcuts.getShortcut(for: .speakOrStop)?.description ?? "the hotkey (unset)"
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

    private var speakClipboardButton: some View {
        Button {
            state.speakClipboard()
        } label: {
            Label("Speak Clipboard", systemImage: "doc.on.clipboard")
                .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
    }

    // MARK: Backend & voices (F-3, P-8 Local-Only)

    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            BackendSelector(selection: $state.backendMode)
            Text(backendCaption)
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.leading, 2)
        }
    }

    private var backendCaption: String {
        switch state.backendMode {
        case .auto: return "Cloud voices, local fallback if the cloud fails"
        case .cloud: return "ElevenLabs only"
        case .local: return "Nothing ever leaves this Mac"
        }
    }

    @ViewBuilder
    private var voicePickers: some View {
        // Reading language drives normalization (F-4), not voice selection:
        // it decides which words the normalizer injects ("50 %" → "50
        // prosent"), so it applies to both backends.
        Picker("Reading language", selection: $state.speechLanguage) {
            ForEach(SpeechLanguage.allCases, id: \.self) { language in
                Text(language.displayName).tag(language)
            }
        }
        if state.backendMode != .local {
            Picker("Voice", selection: $state.voiceID) {
                ForEach(state.availableVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
                if !state.availableVoices.contains(where: { $0.id == state.voiceID }) {
                    Text("Custom (\(String(state.voiceID.prefix(8)))…)").tag(state.voiceID)
                }
            }
            Picker("Model", selection: $state.modelID) {
                ForEach(ElevenLabsProvider.models, id: \.id) { model in
                    Text(model.name).tag(model.id)
                }
            }
        }
        if state.kokoroInstalled && state.backendMode != .cloud {
            Picker("Local voice", selection: $state.localVoiceID) {
                ForEach(KokoroProvider.presetVoices) { voice in
                    Text(voice.name).tag(voice.id)
                }
            }
        }
    }

    // MARK: Privacy & status (P-6, P-10, C-1/C-2)

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Auto-delete ElevenLabs history", isOn: $state.autoDeleteHistory)
                .toggleStyle(.checkbox)
            Toggle("Cache audio", isOn: $state.cacheEnabled)
                .toggleStyle(.checkbox)
                .help("Disable for sensitive sessions — nothing is written to disk")
            if !state.historyStatus.isEmpty {
                Text(state.historyStatus)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

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
        if !state.kokoroInstalled && state.kokoroInstallStatus == nil {
            Button(state.kokoroNeedsUpdate
                   ? "Update Local Voice Runtime…"
                   : "Install Local Voice (Kokoro, ~330 MB)…") {
                state.installKokoro()
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        HStack(spacing: 4) {
            if let remaining = state.creditsRemaining, let limit = state.creditsLimit {
                Text("Credits \(remaining.formatted()) / \(limit.formatted())")
            }
            let spent = state.ledger.spentToday
            if spent > 0 {
                Text("· \(spent.formatted()) today")
            }
        }
        .font(.caption2).foregroundStyle(.tertiary)
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

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyDraft = ""
    @State private var apiKeySavedFlash = false
    @State private var apiKeySaveError: String?

    var body: some View {
        Form {
            Section("Hotkeys") {
                LabeledContent("Speak / Stop:") {
                    ShortcutRecorderField(name: .speakOrStop)
                }
                LabeledContent("Pause / Resume:") {
                    ShortcutRecorderField(name: .pauseResume)
                }
                Button("Reset Shortcuts to Defaults") {
                    state.resetShortcutsToDefaults()
                }
            }

            Section("ElevenLabs") {
                HStack {
                    SecureField(
                        KeychainStore.maskedAPIKey() ?? "API key",
                        text: $apiKeyDraft
                    )
                    Button("Save") {
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
                if apiKeySavedFlash {
                    Text("Saved to Keychain").font(.caption).foregroundStyle(.green)
                }
                if let apiKeySaveError {
                    Text(apiKeySaveError).font(.caption).foregroundStyle(.red)
                }
                Text("Stored only in the macOS Keychain. Scope the key to Text-to-Speech + User Read.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cost") {
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
            }

            Section("Maintenance") {
                Button("Purge Audio Cache") { state.purgeCache() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
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
