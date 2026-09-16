import KeyboardShortcuts
import SRCore
import SwiftUI

@MainActor
final class SRAppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: AppState?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Assign the icon before raising the activation policy, so the Dock
        // tile is never drawn from a stale cache entry.
        AppIcon.apply()
        SRAppDelegate.state?.applyActivationPolicy()
    }

    /// Clicking the Dock icon of an app with no windows does nothing by
    /// default. sr's transport lives in the menu bar, so the useful answer
    /// to "the user clicked the icon" is to open Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        SRAppDelegate.state?.settingsWindowDidOpen()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        return true
    }

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
            // Wrap rather than truncate. A menu row is one line wide by
            // default, so a failure that names a file, a phase and a log path
            // arrived as "Offline synthesis failed (RuntimeError). See ~/Lib…"
            // — the part that says what to do next was the part cut off.
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Either offline voice, because the panel is what stays visible once
        // the Settings window is closed — and a gigabyte-scale download is
        // exactly the thing you close the window and walk away from.
        ForEach(Array(installProgressRows.enumerated()), id: \.offset) { _, status in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if status.fraction == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(status.message).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if let fraction = status.fraction {
                        Text("\(Int(fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fraction = status.fraction {
                    ProgressView(value: fraction)
                }
            }
        }
        ForEach(Array(installErrorRows.enumerated()), id: \.offset) { _, failure in
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installProgressRows: [InstallStatus] {
        [state.kokoroInstallStatus, state.f5InstallStatus].compactMap { $0 }
    }

    private var installErrorRows: [String] {
        [state.kokoroInstallError, state.f5InstallError].compactMap { $0 }
    }

    private var bottomRow: some View {
        HStack {
            Button("Settings…") {
                // Accessory apps never truly become active, so key events
                // bypass their windows (the shortcut recorder would focus but
                // receive nothing). Raise the policy while Settings is open;
                // SettingsView.onDisappear hands it back.
                state.settingsWindowDidOpen()
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
/// Shared with the reader overlay, so the two transports feel like one control.
struct TransportButton: View {
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
