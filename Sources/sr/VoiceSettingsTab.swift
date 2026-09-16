import AppKit
import SRCore
import SwiftUI
import UniformTypeIdentifiers

/// Voices — one profile per language (F-10), and a way to hear them.
///
/// One language at a time, chosen at the top. Picking a voice used to be a
/// pop-up menu of names you had to already know; here every voice is a row
/// with a play button, and the sample it plays is synthesized with *this*
/// language's model and language lock. So the audition is the real thing —
/// a Norwegian voice is auditioned in Norwegian, and a voice that sounds
/// wrong under Flash v2.5 sounds wrong in the preview too.
struct VoiceSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var language: SpeechLanguage = .english
    @State private var search = ""
    // Draft state for a new Norwegian reference recording.
    @State private var isAddingVoice = false
    @State private var newVoiceName = ""
    @State private var newVoiceTranscript = ""
    @State private var newVoiceURL: URL?
    @State private var addVoiceError: String?
    @State private var isRecordingVoice = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    ForEach(SpeechLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section("ElevenLabs voice") {
                searchField
                voiceList
                auditionFootnote
            }

            Section("Model") {
                Picker("Model", selection: modelBinding) {
                    ForEach(ElevenLabsProvider.models, id: \.id) { model in
                        Text(modelLabel(model)).tag(model.id)
                    }
                }
                .labelsHidden()
                if !state.languageIsLocked(language) {
                    Label(
                        "This model can't be pinned to \(language.displayName) — ElevenLabs will detect the language from the text instead. Pick Flash v2.5 or Turbo v2.5 to lock it.",
                        systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Offline voice") {
                offlineVoices
            }
        }
        .formStyle(.grouped)
        .onChange(of: language) { _, _ in
            search = ""
            state.preview.stop()
            resetVoiceDraft()
        }
        .sheet(isPresented: $isRecordingVoice) {
            RecordVoiceSheet().environmentObject(state)
        }
    }

    // MARK: - Cloud voices

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Filter voices", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The account's voices, plus whatever is currently selected even when
    /// the account no longer lists it — a voice you can't see is a voice you
    /// can't change away from.
    private var voices: [Voice] {
        var all = state.availableVoices
        let selected = state.voiceID(for: language)
        if !all.contains(where: { $0.id == selected }) {
            all.insert(Voice(id: selected, name: "Custom (\(selected.prefix(8))…)"), at: 0)
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var voiceList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(voices) { voice in
                    VoiceRow(
                        name: voice.name,
                        isSelected: voice.id == state.voiceID(for: language),
                        isLoading: state.preview.isLoading(
                            AppState.PreviewToken.cloudVoice(voice.id, language)),
                        isPlaying: state.preview.isPlaying(
                            AppState.PreviewToken.cloudVoice(voice.id, language)),
                        auditionHelp: "Hear \(voice.name) read \(language.displayName)",
                        select: { state.setVoiceID(voice.id, for: language) },
                        audition: { state.previewCloudVoice(voice.id, language: language) })
                }
                if voices.isEmpty {
                    Text("No voice matches “\(search)”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
        }
        // Fixed height: the list scrolls rather than the window growing when
        // an account has eighty voices and shrinking when a filter matches
        // two. See SettingsView.tabHeight.
        .frame(height: 150)
    }

    @ViewBuilder
    private var auditionFootnote: some View {
        if let failure = state.preview.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text("Samples are a single sentence, synthesized with the model below and cached — hearing the same voice again is instant and free.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Offline voices

    /// Kokoro ships a fixed voice list; the Norwegian model reads in the
    /// voice of a recording you supply, so the same section has to present
    /// both a chooser and an editor.
    @ViewBuilder
    private var offlineVoices: some View {
        if !LocalVoices.isInstalled(for: language) {
            Text(language.localEngine == .f5
                 ? "The Norwegian offline voice is not installed — add it in Settings → General."
                 : "Install the English offline voice in Settings → General to use sr offline.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            let localVoices = language.localEngine == .f5
                ? state.f5Voices.map(\.asVoice)
                : LocalVoices.available(for: language)
            if localVoices.isEmpty {
                Text("No voice yet. Record one — sr gives you a sentence to read, then reads back in your voice. It takes about a minute and never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(localVoices) { voice in
                            VoiceRow(
                                name: voice.name,
                                isSelected: voice.id == state.localVoiceID(for: language),
                                isLoading: state.preview.isLoading(
                                    AppState.PreviewToken.localVoice(voice.id, language)),
                                isPlaying: state.preview.isPlaying(
                                    AppState.PreviewToken.localVoice(voice.id, language)),
                                auditionHelp: "Hear \(voice.name) (offline, free)",
                                select: { state.setLocalVoiceID(voice.id, for: language) },
                                audition: { state.previewLocalVoice(voice.id, language: language) },
                                remove: language.localEngine == .f5
                                    ? { state.removeF5Voice(id: voice.id) } : nil)
                        }
                    }
                }
                .frame(height: 88)
            }
            if language.localEngine == .f5 {
                referenceVoiceEditor
                architecturePicker
            }
        }
    }

    // MARK: - Reference recordings (Norwegian)

    @ViewBuilder
    private var referenceVoiceEditor: some View {
        if !isAddingVoice {
            HStack(spacing: 10) {
                Button {
                    state.preview.stop()
                    isRecordingVoice = true
                } label: {
                    Label("Record a Voice…", systemImage: "mic")
                }
                Button("Add from a File…") {
                    resetVoiceDraft()
                    isAddingVoice = true
                }
            }
        }
        if isAddingVoice {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button("Choose Recording…") { chooseRecording() }
                    Text(newVoiceURL?.lastPathComponent ?? "No file chosen")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                TextField("Voice name", text: $newVoiceName)
                TextField("Exactly what is said in the recording",
                          text: $newVoiceTranscript, axis: .vertical)
                    .lineLimit(2...4)
                if let addVoiceError {
                    Label(addVoiceError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Any audio file works — sr converts it to the 24 kHz mono the model needs and keeps only that copy. The transcript has to match the recording word for word: it is how F5 lines the voice up with the text.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Add Voice") { addVoice() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newVoiceURL == nil)
                    Button("Cancel") { resetVoiceDraft() }
                }
            }
        }
    }

    /// The escape hatch for a checkpoint that loads but sounds wrong.
    @ViewBuilder
    private var architecturePicker: some View {
        Picker("Architecture", selection: $state.f5Variant) {
            ForEach(F5Installer.Variant.allCases) { variant in
                Text(variant.displayName).tag(variant)
            }
        }
        Text("The two F5-TTS architectures use identical tensor shapes, so the downloaded checkpoint cannot say which one it is — sr goes by what the model repo declares. If Norwegian comes out as babble rather than speech, switch this and try again.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func chooseRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick 3–10 seconds of clear Norwegian speech."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newVoiceURL = url
        addVoiceError = nil
        if newVoiceName.trimmingCharacters(in: .whitespaces).isEmpty {
            newVoiceName = url.deletingPathExtension().lastPathComponent
        }
    }

    private func addVoice() {
        guard let url = newVoiceURL else { return }
        switch state.addF5Voice(name: newVoiceName, audio: url,
                                transcript: newVoiceTranscript) {
        case .success:
            resetVoiceDraft()
        case .failure(let message):
            addVoiceError = message
        }
    }

    private func resetVoiceDraft() {
        isAddingVoice = false
        newVoiceName = ""
        newVoiceTranscript = ""
        newVoiceURL = nil
        addVoiceError = nil
    }

    // MARK: - Bindings

    private var modelBinding: Binding<String> {
        Binding(get: { state.modelID(for: language) },
                set: { state.setModelID($0, for: language) })
    }

    private func modelLabel(_ model: (name: String, id: String)) -> String {
        ElevenLabsProvider.supportsLanguageLock(model.id)
            ? model.name
            : "\(model.name) — no language lock"
    }
}

/// One selectable voice: audition on the left, name in the middle, a
/// checkmark when it is the one this language reads with.
private struct VoiceRow: View {
    let name: String
    let isSelected: Bool
    let isLoading: Bool
    let isPlaying: Bool
    let auditionHelp: String
    let select: () -> Void
    let audition: () -> Void
    /// Only reference voices can be removed — Kokoro's are part of the model.
    var remove: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AuditionButton(isLoading: isLoading, isPlaying: isPlaying,
                           help: auditionHelp, action: audition)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this voice")
                // Hidden rather than absent, for the same reason as the
                // checkmark below: an appearing button would nudge the name.
                .opacity(hovering ? 1 : 0)
            }
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                // Hidden rather than absent: an appearing checkmark would
                // otherwise nudge the name every time the selection moved.
                .opacity(isSelected ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : hovering ? AnyShapeStyle(.quaternary.opacity(0.6))
                                 : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        // The audition button sits inside the row's hit area, so the row's
        // own tap gesture must not swallow its clicks — a plain Button
        // nested in an onTapGesture still wins, which is why the row uses
        // the gesture and the button stays a Button.
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}
