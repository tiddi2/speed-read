import AVFoundation
import SRCore
import SwiftUI

/// Record a Norwegian reference voice, end to end.
///
/// The point of a wizard rather than a file picker and a text field: F5-TTS
/// needs a recording *and* a transcript that agree word for word, and asking
/// someone to type out what they just said is both work and the most likely
/// way to get a subtly wrong pairing. Handing them a script inverts that —
/// sr already knows the text, so the transcript is exact by construction and
/// the reader only has to read.
///
/// Three steps, and the reader can go back a step at any point:
///   read     — the script, and how to read it
///   review   — hear the take back, keep it or do it again
///   listen   — hear the model read something *else* in that voice, which is
///              the only thing that actually answers "is this voice any good"
struct RecordVoiceSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = VoiceRecorder()

    private enum Step {
        case read, review, listen
    }

    @State private var step: Step = .read
    @State private var script = ReferenceScript.norwegian[0]
    @State private var name = "Min stemme"
    @State private var savedVoiceID: String?
    @State private var saveError: String?

    private let language = SpeechLanguage.norwegian

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            switch step {
            case .read: readStep
            case .review: reviewStep
            case .listen: listenStep
            }
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 520, height: 470)
        .onDisappear { recorder.discardAll() }
        .task { recorder.refreshPermission() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch step {
        case .read: return "Record your Norwegian voice"
        case .review: return "How did that sound?"
        case .listen: return "Here is sr reading in your voice"
        }
    }

    private var subtitle: String {
        switch step {
        case .read:
            return "Read the sentence below out loud. It stays on this Mac."
        case .review:
            return "Listen back before you keep it — the model copies whatever it hears."
        case .listen:
            return "A different sentence, so you can hear the voice rather than the recording."
        }
    }

    // MARK: - Step 1: read

    private var readStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(script.text)
                .font(.title3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.4)))

            if recorder.isRecording {
                levelMeter
            } else {
                coaching
            }

            if let failure = recorder.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Somewhere quiet, about a hand's width from the microphone.",
                  systemImage: "1.circle")
            Label("Read at your normal pace and volume — not slowly, not loudly.",
                  systemImage: "2.circle")
            Label("Read it the way you would want sr to read to you. The voice "
                  + "copies your delivery, flatness included.",
                  systemImage: "3.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var levelMeter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                ProgressView(value: recorder.level)
                Text(String(format: "%.0fs", recorder.duration))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("Recording — press Stop when you reach the end of the sentence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Step 2: review

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    recorder.isPlayingBack ? recorder.stopPlayback() : recorder.playBack()
                } label: {
                    Label(recorder.isPlayingBack ? "Stop" : "Play it back",
                          systemImage: recorder.isPlayingBack ? "stop.fill" : "play.fill")
                }
                Text(String(format: "%.1f seconds", recorder.duration))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let advice = recorder.advice {
                Label(advice, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("That looks like a usable take.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }

            LabeledContent("Name") {
                TextField("Voice name", text: $name)
            }

            Text("Keeping it converts the clip to the 24 kHz mono the model "
                 + "conditions on and stores it under Application Support. The "
                 + "script you read is saved with it as the transcript.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Step 3: listen

    private var listenStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !LocalVoices.isInstalled(for: language) {
                Label("The Norwegian model is not installed yet, so there is "
                      + "nothing to synthesize with. The voice is saved and will "
                      + "be used once you install it in Settings → General.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(VoiceSample.text(for: language))
                    .font(.title3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(.quaternary.opacity(0.4)))

                HStack(spacing: 10) {
                    AuditionButton(
                        isLoading: isPreviewLoading,
                        isPlaying: isPreviewPlaying,
                        help: "Hear the model read this in your voice",
                        action: previewSavedVoice)
                    Text(isPreviewLoading
                         ? "Synthesizing — the first one also loads the model, which takes a moment."
                         : "Press play to hear it.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let failure = state.preview.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Not happy with it? Record again — the new take replaces this "
                 + "voice rather than piling up next to it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previewToken: String? {
        savedVoiceID.map { AppState.PreviewToken.localVoice($0, language) }
    }

    private var isPreviewLoading: Bool {
        previewToken.map { state.preview.isLoading($0) } ?? false
    }

    private var isPreviewPlaying: Bool {
        previewToken.map { state.preview.isPlaying($0) } ?? false
    }

    private func previewSavedVoice() {
        guard let savedVoiceID else { return }
        state.previewLocalVoice(savedVoiceID, language: language)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if step == .read {
                Button("Another sentence") { cycleScript() }
                    .disabled(recorder.isRecording)
            } else {
                Button("Record again") { recordAgain() }
            }
            Spacer()
            switch step {
            case .read:
                Button("Cancel") { dismiss() }
                if recorder.isRecording {
                    Button("Stop") { stopAndReview() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        Task { await recorder.start() }
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .review:
                Button("Cancel") { dismiss() }
                Button("Use this voice") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(recorder.recordedURL == nil)
            case .listen:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Actions

    private func cycleScript() {
        let all = ReferenceScript.norwegian
        guard let index = all.firstIndex(of: script) else { return }
        script = all[(index + 1) % all.count]
    }

    private func stopAndReview() {
        recorder.stop()
        step = .review
    }

    private func recordAgain() {
        recorder.stopPlayback()
        state.preview.stop()
        saveError = nil
        step = .read
    }

    private func save() {
        guard let url = recorder.recordedURL else { return }
        recorder.stopPlayback()
        // The script is the transcript, exactly — that pairing is the whole
        // reason this flow exists.
        let outcome = state.addF5Voice(
            name: name, audio: url, transcript: script.text,
            replacing: savedVoiceID, makeDefault: true)
        switch outcome {
        case .success(let voice):
            savedVoiceID = voice.id
            saveError = nil
            step = .listen
        case .failure(let message):
            saveError = message
        }
    }
}
