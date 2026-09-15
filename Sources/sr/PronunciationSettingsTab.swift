import SRCore
import SwiftUI

/// Pronunciation — the words sr gets wrong, and what to do about them (F-13).
///
/// One dictionary per language, because "Anne" is not said the same way in
/// English and Norwegian and a single shared list would have to pick one.
/// Every entry can be heard both ways before you keep it: as sr says it now,
/// and as the rule would have it.
struct PronunciationSettingsTab: View {
    @EnvironmentObject var state: AppState
    @State private var language: SpeechLanguage = .english
    @State private var selection: UUID?
    @State private var editing: EditorTarget?

    struct EditorTarget: Identifiable {
        var draft: PronunciationRule
        var isNew: Bool
        var id: UUID { draft.id }
    }

    private var rules: [PronunciationRule] { state.rules(for: language) }

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

            Section("Custom pronunciations") {
                ruleList
                listToolbar
            }

            Section {
                statusFootnote
            }
        }
        .formStyle(.grouped)
        .onChange(of: language) { _, _ in
            selection = nil
            state.preview.stop()
            state.syncPronunciations(for: language)
        }
        .sheet(item: $editing) { target in
            PronunciationEditor(
                draft: target.draft,
                isNew: target.isNew,
                language: language,
                onCancel: { editing = nil },
                onSave: { rule in
                    save(rule)
                    editing = nil
                })
                .environmentObject(state)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var ruleList: some View {
        if rules.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No custom pronunciations for \(language.displayName) yet.")
                    .font(.callout)
                Text("Add a name, an acronym or a loan word sr stumbles over, and it will be said your way in every read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rules) { rule in
                        PronunciationRow(
                            rule: rule,
                            isSelected: rule.id == selection,
                            isLoading: state.preview.isLoading(
                                AppState.PreviewToken.rule(rule.id, applied: true)),
                            isPlaying: state.preview.isPlaying(
                                AppState.PreviewToken.rule(rule.id, applied: true)),
                            select: { selection = rule.id },
                            edit: { editing = EditorTarget(draft: rule, isNew: false) },
                            toggleEnabled: { setEnabled(!rule.isEnabled, on: rule) },
                            audition: {
                                state.previewPhrase(
                                    rule.stringToReplace, language: language,
                                    applying: rule,
                                    token: AppState.PreviewToken.rule(rule.id, applied: true))
                            })
                    }
                }
            }
            .frame(height: 236)
        }
    }

    private var listToolbar: some View {
        HStack(spacing: 8) {
            Button {
                let draft = PronunciationRule()
                editing = EditorTarget(draft: draft, isNew: true)
            } label: {
                Label("Add", systemImage: "plus")
            }
            Button {
                guard let rule = selectedRule else { return }
                editing = EditorTarget(draft: rule, isNew: false)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .disabled(selectedRule == nil)
            Button(role: .destructive) {
                removeSelected()
            } label: {
                Label("Remove", systemImage: "minus")
            }
            .disabled(selectedRule == nil)
            Spacer()
        }
    }

    @ViewBuilder
    private var statusFootnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.isSyncingPronunciations(for: language) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Sending phoneme rules to ElevenLabs…").font(.caption)
                }
            } else if !state.pronunciationStatus(for: language).isEmpty {
                Text(state.pronunciationStatus(for: language))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if state.phonemeRulesAreIgnored(language) {
                Label(
                    "The model chosen for \(language.displayName) in Settings → Voices ignores phoneme rules. Switch that language to v3, or write the entry as a respelling instead — respellings work on every model.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Respellings are applied on this Mac, before any text is sent, so they work with the offline voice too. Phoneme rules are the one kind only ElevenLabs can apply: those entries are uploaded as a pronunciation dictionary.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Mutations

    private var selectedRule: PronunciationRule? {
        selection.flatMap { id in rules.first { $0.id == id } }
    }

    private func save(_ rule: PronunciationRule) {
        var updated = rules
        if let index = updated.firstIndex(where: { $0.id == rule.id }) {
            updated[index] = rule
        } else {
            updated.append(rule)
        }
        state.setRules(updated, for: language)
        selection = rule.id
    }

    private func setEnabled(_ enabled: Bool, on rule: PronunciationRule) {
        var updated = rules
        guard let index = updated.firstIndex(where: { $0.id == rule.id }) else { return }
        updated[index].isEnabled = enabled
        state.setRules(updated, for: language)
    }

    private func removeSelected() {
        guard let id = selection else { return }
        state.preview.stop()
        state.setRules(rules.filter { $0.id != id }, for: language)
        selection = nil
    }
}

// MARK: - Row

private struct PronunciationRow: View {
    let rule: PronunciationRule
    let isSelected: Bool
    let isLoading: Bool
    let isPlaying: Bool
    let select: () -> Void
    let edit: () -> Void
    let toggleEnabled: () -> Void
    let audition: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: Binding(get: { rule.isEnabled },
                                     set: { _ in toggleEnabled() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(rule.isEnabled ? "Applied to every read" : "Kept, but not applied")

            Text(rule.stringToReplace.isEmpty ? "—" : rule.stringToReplace)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(rule.replacementSummary.isEmpty ? "—" : rule.replacementSummary)
                .lineLimit(1)
                .truncationMode(.tail)
                .font(rule.kind == .phoneme ? .body.monospaced() : .body)

            Spacer(minLength: 6)

            Text(rule.kind.displayName)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.quaternary))

            AuditionButton(isLoading: isLoading, isPlaying: isPlaying,
                           help: "Hear this entry", action: audition)
        }
        .opacity(rule.isEnabled ? 1 : 0.5)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : hovering ? AnyShapeStyle(.quaternary.opacity(0.6))
                                 : AnyShapeStyle(.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: edit)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

// MARK: - Editor

/// Add or change one entry, with the before/after pair that makes the
/// decision obvious. Both auditions use ElevenLabs' inline markup rather
/// than the uploaded dictionary, so a rule can be heard while it is still
/// being typed — nothing is uploaded until Save.
private struct PronunciationEditor: View {
    @EnvironmentObject var state: AppState
    @State var draft: PronunciationRule
    @State private var phrase: String = ""
    let isNew: Bool
    let language: SpeechLanguage
    let onCancel: () -> Void
    let onSave: (PronunciationRule) -> Void

    init(draft: PronunciationRule,
         isNew: Bool,
         language: SpeechLanguage,
         onCancel: @escaping () -> Void,
         onSave: @escaping (PronunciationRule) -> Void) {
        _draft = State(initialValue: draft)
        _phrase = State(initialValue: draft.stringToReplace)
        self.isNew = isNew
        self.language = language
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New pronunciation — \(language.displayName)"
                       : "Edit pronunciation — \(language.displayName)")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                Section {
                    TextField("Word or phrase", text: $draft.stringToReplace)
                        .onChange(of: draft.stringToReplace) { old, new in
                            // The test phrase follows the word until it is
                            // edited into something of its own.
                            if phrase == old { phrase = new }
                        }
                    Picker("How", selection: $draft.kind) {
                        ForEach(PronunciationRule.Kind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch draft.kind {
                    case .alias:
                        TextField("Say it as", text: $draft.alias)
                        Text("A plain respelling, spelled the way it sounds: “Nguyen” → “Nwin”. Works with every model and with the offline voice, and never leaves this Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .phoneme:
                        TextField("Phonemes", text: $draft.phoneme)
                            .font(.body.monospaced())
                        Picker("Alphabet", selection: $draft.alphabet) {
                            ForEach(PronunciationRule.Alphabet.allCases) { alphabet in
                                Text(alphabet.displayName).tag(alphabet)
                            }
                        }
                        .pickerStyle(.segmented)
                        if phonemesAreIgnored {
                            Label(
                                "\(language.displayName) currently reads with a model that ignores phoneme rules. The preview below will too — use a respelling, or switch that language to v3 in Settings → Voices.",
                                systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("An exact transcription, e.g. “ŋwɪn”. Only ElevenLabs can apply these, and only on models that support them.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Match capitalisation exactly", isOn: $draft.matchCase)
                    Toggle("Apply this entry", isOn: $draft.isEnabled)
                }

                Section("Listen") {
                    TextField("Test phrase", text: $phrase)
                    HStack(spacing: 14) {
                        auditionPair(title: "As it is now", applied: false)
                        auditionPair(title: "With this entry", applied: true)
                        Spacer()
                    }
                    if let failure = state.preview.failure {
                        Text(failure).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    state.preview.stop()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    state.preview.stop()
                    onSave(trimmedDraft)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!trimmedDraft.isComplete)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 460)
    }

    private func auditionPair(title: String, applied: Bool) -> some View {
        let token = AppState.PreviewToken.rule(draft.id, applied: applied)
        return HStack(spacing: 7) {
            AuditionButton(
                isLoading: state.preview.isLoading(token),
                isPlaying: state.preview.isPlaying(token),
                help: title
            ) {
                state.previewPhrase(phrase, language: language,
                                    applying: applied ? trimmedDraft : nil,
                                    token: token)
            }
            Text(title).font(.callout)
        }
        .opacity(applied && !trimmedDraft.isComplete ? 0.4 : 1)
        .disabled(applied && !trimmedDraft.isComplete)
    }

    private var phonemesAreIgnored: Bool {
        !ElevenLabsProvider.supportsPhonemeRules(state.modelID(for: language))
    }

    /// Stray whitespace around a word silently stops it matching anything.
    private var trimmedDraft: PronunciationRule {
        var rule = draft
        rule.stringToReplace = rule.stringToReplace
            .trimmingCharacters(in: .whitespacesAndNewlines)
        rule.alias = rule.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.phoneme = rule.phoneme.trimmingCharacters(in: .whitespacesAndNewlines)
        return rule
    }
}
