import AppKit
import SRCore
import SwiftUI

/// What the logs say, without a Terminal.
///
/// The offline engines fail for reasons that live on disk rather than on a
/// network, and the daemon deliberately never relays an exception's message —
/// it could quote the text being read. That is the right trade for a running
/// daemon, and it leaves someone holding a class name. This tab shows both
/// logs, runs the self-test that is allowed to print the whole failure, and
/// puts the lot on the clipboard in one click.
@MainActor
final class DiagnosticsModel: ObservableObject {
    /// Selected like a log file, because to a reader it is one.
    static let selfTestID = "self-test"

    @Published var selection: String = Diagnostics.logFiles.first?.id ?? "app"
    @Published var lines: [Line] = []
    /// Nil until the self-test has been run in this window session.
    @Published private(set) var selfTestOutput: String?
    @Published private(set) var isRunningSelfTest = false
    @Published private(set) var selfTestSucceeded: Bool?
    /// Set briefly after a copy so the button can confirm it did something.
    @Published private(set) var didCopy = false

    /// One row of the console. Identified by position so a redraw of a
    /// growing log reuses rows instead of rebuilding every one of them.
    struct Line: Identifiable {
        let id: Int
        let text: String
        let isProblem: Bool
    }

    private var selfTestTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    /// What `lines` was built from. A follow tick that finds the same bytes
    /// republishes nothing, so an idle log costs no redraws.
    private var renderedFrom: String?

    var selectedLog: Diagnostics.LogFile? {
        Diagnostics.logFiles.first { $0.id == selection }
    }

    var showingSelfTest: Bool { selection == Self.selfTestID }

    // MARK: Reading

    func refresh(force: Bool = false) {
        if force { renderedFrom = nil }
        let text = showingSelfTest
            ? (selfTestOutput ?? "")
            : selectedLog.map { Diagnostics.tail($0.url, maxBytes: 64 << 10) } ?? ""
        guard text != renderedFrom else { return }
        renderedFrom = text
        // Only the tail is drawn: past a couple of thousand lines nobody is
        // reading, they are scrolling, and the file is one click away.
        lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(2000)
            .enumerated()
            .map { index, line in
                let row = String(line)
                return Line(id: index, text: row, isProblem: Self.looksLikeTrouble(row))
            }
    }

    /// Errors are the reason anyone opens this tab, so let them be findable.
    private static func looksLikeTrouble(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return lowered.contains("error") || lowered.contains("failed")
            || lowered.contains("traceback") || lowered.contains("refusing")
    }

    /// Re-read while the tab is on screen, and only then: a log nobody is
    /// looking at is a log nobody needs re-read.
    func startFollowing() {
        refresh()
        followTask?.cancel()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stopFollowing() {
        followTask?.cancel()
        followTask = nil
    }

    // MARK: Self-test

    func runSelfTest() {
        guard !isRunningSelfTest else { return }
        isRunningSelfTest = true
        selfTestSucceeded = nil
        selfTestOutput = ""
        selection = Self.selfTestID
        refresh(force: true)

        selfTestTask = Task { [weak self] in
            for await event in Diagnostics.offlineSelfTest() {
                guard let self else { return }
                switch event {
                case .output(let chunk):
                    self.selfTestOutput = (self.selfTestOutput ?? "") + chunk
                    if self.showingSelfTest { self.refresh() }
                case .finished(let status):
                    self.selfTestSucceeded = status == 0
                }
            }
            self?.isRunningSelfTest = false
        }
    }

    func cancelSelfTest() {
        selfTestTask?.cancel()
        selfTestTask = nil
        isRunningSelfTest = false
    }

    // MARK: Handing it over

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            Diagnostics.report(selfTestOutput: selfTestOutput), forType: .string)
        didCopy = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.didCopy = false
        }
    }

    func revealInFinder() {
        let url = selectedLog?.url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([Diagnostics.logDirectory])
        }
    }
}

// MARK: - The tab

/// Thin shell: the tab is constructed from the environment, but the view that
/// redraws has to observe the model, not the AppState that happens to own it.
struct DiagnosticsSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        DiagnosticsConsole(model: state.diagnostics)
    }
}

private struct DiagnosticsConsole: View {
    @ObservedObject var model: DiagnosticsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            picker
            console
            caption
            controls
        }
        .padding(20)
        .onAppear { model.startFollowing() }
        .onDisappear { model.stopFollowing() }
        .onChange(of: model.selection) { _, _ in model.refresh(force: true) }
    }

    private var picker: some View {
        Picker("", selection: $model.selection) {
            ForEach(Diagnostics.logFiles) { file in
                Text(file.title).tag(file.id)
            }
            // Only once there is something to show: an empty tab invites a
            // click that does nothing.
            if model.selfTestOutput != nil {
                Text("Self-test").tag(DiagnosticsModel.selfTestID)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var console: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if model.lines.isEmpty {
                    Text("Nothing logged yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.lines) { line in
                    // A blank line still gets a row, or the shape of the log —
                    // the gaps between runs — disappears.
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(line.isProblem ? Color.orange : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        // Follow the tail: the newest line is the one being waited for, and
        // this keeps it in view as the log grows without fighting a scroll.
        .defaultScrollAnchor(.bottom)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxHeight: .infinity)
    }

    private var caption: some View {
        Group {
            if model.showingSelfTest {
                Text(selfTestCaption)
            } else if let log = model.selectedLog {
                Text("\(log.summary)  \(log.url.path)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selfTestCaption: String {
        if model.isRunningSelfTest {
            return "Loading the offline model and reading one sentence. "
                + "The first run takes a minute or two."
        }
        guard let succeeded = model.selfTestSucceeded else { return "" }
        return succeeded
            ? "The offline voice works when run this way. If reads still fail, "
                + "quit every sr window and reopen sr so the daemon restarts."
            : "That is the failure in full, including what the daemon is not "
                + "allowed to say during a read. Copy it for a bug report."
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if model.isRunningSelfTest {
                    ProgressView().controlSize(.small)
                    Button("Stop") { model.cancelSelfTest() }
                } else {
                    Button("Test the offline voice") { model.runSelfTest() }
                        .help("Loads the offline model and reads one sentence of "
                            + "its own, printing exactly what fails if anything does.")
                }
                Spacer()
                Button("Show in Finder") { model.revealInFinder() }
                Button(model.didCopy ? "Copied" : "Copy for a bug report") {
                    model.copyReport()
                }
                .disabled(model.didCopy)
            }
            Text("Copying takes the version, what is installed, both logs and "
                + "any self-test output. sr's logs record counts, timings and "
                + "error types — never the text you read, never your API key — "
                + "so they are safe to paste anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
