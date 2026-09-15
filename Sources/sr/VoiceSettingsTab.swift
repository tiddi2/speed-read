import SRCore
import SwiftUI

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

    @ViewBuilder
    private var offlineVoices: some View {
        let localVoices = KokoroProvider.presetVoices(for: language)
        if localVoices.isEmpty {
            Text("No offline voice — \(language.displayName) is cloud-only.")
                .font(.caption).foregroundStyle(.secondary)
        } else if !state.kokoroInstalled {
            Text("Install the local voice in Settings → General to use sr offline.")
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
                            audition: { state.previewLocalVoice(voice.id, language: language) })
                    }
                }
            }
            .frame(height: 88)
        }
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

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            AuditionButton(isLoading: isLoading, isPlaying: isPlaying,
                           help: auditionHelp, action: audition)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
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
