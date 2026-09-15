import KeyboardShortcuts
import SRCore
import SwiftUI

// MARK: - Settings window (⌘,)

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    /// Every tab is drawn on a canvas of exactly this size.
    ///
    /// This is what stops the toolbar icons from shaking. A macOS Settings
    /// TabView sizes its window to whichever tab is showing, and re-lays-out
    /// the tab bar while that resize animates — so the icons jump every time
    /// you switch tabs, and twitch again whenever a row inside a tab appears
    /// or disappears ("Saved to Keychain", the install spinner, the
    /// language-lock warning). Pinning every tab to one size removes the
    /// resize, and with it the shake; a tab with more content than fits
    /// scrolls inside its own grouped Form instead of growing the window.
    static let tabWidth: CGFloat = 580
    static let tabHeight: CGFloat = 560

    var body: some View {
        TabView {
            tab(GeneralSettings())
                .tabItem { Label("General", systemImage: "gearshape") }
            tab(VoiceSettingsTab())
                .tabItem { Label("Voices", systemImage: "waveform") }
            tab(PronunciationSettingsTab())
                .tabItem { Label("Pronunciation", systemImage: "character.book.closed") }
            tab(ShortcutSettings())
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            tab(PrivacySettings())
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            tab(CostSettings())
                .tabItem { Label("Cost", systemImage: "creditcard") }
        }
        .onAppear {
            state.settingsWindowDidOpen()
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
            state.settingsWindowDidClose()
            // Nothing should keep talking after the window it was started
            // from is gone.
            state.preview.stop()
        }
    }

    private func tab(_ content: some View) -> some View {
        content.frame(width: Self.tabWidth, height: Self.tabHeight)
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

            Section("Reader overlay") {
                Toggle("Show the reader while sr is speaking",
                       isOn: $state.readerOverlayEnabled)
                Toggle("Previous sentence", isOn: $state.readerShowsPreviousSentence)
                    .disabled(!state.readerOverlayEnabled)
                Toggle("Current sentence, with the spoken word highlighted",
                       isOn: $state.readerShowsCurrentSentence)
                    .disabled(!state.readerOverlayEnabled)
                Toggle("Next sentence", isOn: $state.readerShowsNextSentence)
                    .disabled(!state.readerOverlayEnabled)
                Text("A borderless window in the top-right of the screen the selection is on — drag it anywhere and sr remembers. Sentences are shown whole and the window grows to fit them, so nothing is cut off. It also shows the speed (change it with the Faster / Slower hotkeys) and which language is being read; neither is editable mid-read.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset Overlay Position") { state.resetReaderOverlayPosition() }
            }

            Section("Appearance") {
                Toggle("Show sr in the Dock", isOn: $state.showInDock)
                Text("sr lives in the menu bar either way. With this on it also keeps a Dock icon while it runs; clicking that icon opens Settings.")
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
