import AppKit
import SRCore
import SwiftUI

// MARK: - Panel

/// A panel that never takes focus.
///
/// sr reads *someone else's* selection. The moment this window becomes key,
/// the source app resigns first responder — the selection deselects in some
/// apps, the caret moves in others, and the next ⌥A captures nothing. So the
/// overlay is click-through-to-its-own-controls but never key and never main.
private final class ReaderOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that acts on the first click.
///
/// sr is an accessory app and this panel never becomes key, so a click on the
/// overlay arrives while the window is, as far as AppKit is concerned,
/// inactive. Without this the first click would be spent waking the window and
/// the second one would press the button. Declaring no initializer of its own
/// is deliberate: the subclass then inherits every one of NSHostingView's,
/// `init(coder:)` included.
private final class ReaderOverlayHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

/// Floating reader that shows what sr is speaking, with the current word
/// highlighted.
///
/// **Why a separate window rather than highlighting in place.** sr reads a
/// selection out of another application, and there is no cross-application way
/// to draw a cursor into that app's own text. Accessibility exposes
/// `AXBoundsForRange` only in the apps that bothered to implement it (Safari
/// and Preview partly, Slack and Electron not at all); the text sr speaks is
/// normalized — LaTeX spoken out, PDF line breaks repaired, citations dropped
/// — so its offsets no longer line up with the source characters; and the
/// source view scrolls and reflows underneath us while we read. A HUD behaves
/// identically in Safari, Preview, Slack, Mail and Terminal, which is the
/// whole promise of "select anywhere".
@MainActor
final class ReaderOverlayController {
    /// Fixed: a reading pane that reflows to its content is hard to read, and
    /// a fixed width makes the window height depend only on the settings, not
    /// on the sentence currently on screen.
    static let width: CGFloat = 460

    private var panel: ReaderOverlayPanel?
    private var hosting: ReaderOverlayHostingView?
    private var moveObserver: NSObjectProtocol?
    private let settings = SettingsStore()
    /// Suppresses position persistence while *we* are the ones moving the
    /// window, so programmatic placement never overwrites the user's drag.
    private var isPositioning = false

    deinit {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
    }

    /// Show the overlay on the screen `point` is on (the selection's screen),
    /// or on the main screen when there is no point to go by.
    func show(state: AppState, near point: NSPoint?) {
        // `self.panel`, not `panel`: a local of the same name cannot be
        // initialized from itself.
        let panel = self.panel ?? makePanel(for: state)
        self.panel = panel
        resizeToFit()
        place(panel, on: Self.screen(containing: point))
        // orderFrontRegardless, not makeKeyAndOrderFront: sr is an accessory
        // app reading another app's selection and must not steal focus.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Put the overlay back where the current settings say it belongs. Used
    /// after the stored drag offset is cleared; a hidden overlay needs nothing
    /// done, since the next `show` places it from scratch.
    func reposition(near point: NSPoint?) {
        guard let panel, panel.isVisible else { return }
        place(panel, on: Self.screen(containing: point))
    }

    /// Re-measure after a change that alters the overlay's height — the
    /// sentence-visibility settings. Deferred one turn of the run loop so
    /// SwiftUI has applied the change before AppKit measures it.
    func relayout() {
        guard let panel, panel.isVisible else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resizeToFit()
            }
        }
    }

    // MARK: Construction

    private func makePanel(for state: AppState) -> ReaderOverlayPanel {
        let panel = ReaderOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        // Follow the user across Spaces and sit over full-screen apps: reading
        // a full-screen PDF is exactly when you want the words on screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // The hosting view retains `state`, which owns this controller, which
        // owns the panel — a cycle, deliberately: AppState is the app's root
        // object and outlives every window, so the panel is built once and
        // reused for every read instead of being torn down and rebuilt.
        let hosting = ReaderOverlayHostingView(rootView: AnyView(
            ReaderOverlayView()
                .environmentObject(state)
                .frame(width: Self.width)))
        panel.contentView = hosting
        self.hosting = hosting

        // queue: nil keeps delivery synchronous on the posting (main) thread,
        // so `isPositioning` still covers our own setFrame calls.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rememberPosition()
            }
        }
        return panel
    }

    // MARK: Geometry

    private func resizeToFit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = max(hosting.fittingSize.height, 1)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        isPositioning = true
        defer { isPositioning = false }
        // Grow downwards: the top edge is the edge the user aligned.
        panel.setFrame(
            NSRect(x: panel.frame.minX,
                   y: panel.frame.maxY - height,
                   width: Self.width,
                   height: height),
            display: true)
        panel.invalidateShadow()
    }

    private func place(_ panel: ReaderOverlayPanel, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let offset = settings.readerOverlayCornerOffset
        let size = panel.frame.size
        var origin = NSPoint(x: visible.maxX + offset.x - size.width,
                             y: visible.maxY + offset.y - size.height)
        // Clamp into the screen. A position dragged on a larger display, or a
        // resolution change, would otherwise park the overlay out of sight.
        let maxX = max(visible.maxX - size.width, visible.minX)
        let maxY = max(visible.maxY - size.height, visible.minY)
        origin.x = min(max(origin.x, visible.minX), maxX)
        origin.y = min(max(origin.y, visible.minY), maxY)
        isPositioning = true
        defer { isPositioning = false }
        panel.setFrameOrigin(origin)
    }

    private func rememberPosition() {
        guard !isPositioning, let panel,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        settings.readerOverlayCornerOffset = (x: panel.frame.maxX - visible.maxX,
                                              y: panel.frame.maxY - visible.maxY)
    }

    /// The screen a point is on. `NSMouseInRect` with `flipped: false` is the
    /// right containment test for AppKit's bottom-left screen coordinates.
    static func screen(containing point: NSPoint?) -> NSScreen? {
        guard let point else { return NSScreen.main }
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
    }
}

// MARK: - View

/// The overlay's content: up to three sentences of context, the word cursor,
/// transport, and read-only speed and language readouts.
///
/// Speed and language are deliberately *displays*, not controls. The language
/// is fixed for the life of a read — it is chosen by which hotkey started it
/// and pinned on every request (see SpeechLanguage), so offering a switch here
/// would promise something the read cannot do. Speed is changed with the
/// Faster/Slower hotkeys, which work without moving the mouse to the overlay.
struct ReaderOverlayView: View {
    @EnvironmentObject var state: AppState

    private var playback: PlaybackEngine { state.playback }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.readerShowsAnySentence {
                sentences
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
    }

    // MARK: Header — what sr is doing, in two read-only readouts.

    private var header: some View {
        HStack(spacing: 8) {
            Label(languageName, systemImage: "character.bubble")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .help("Reading \(languageName). The language is fixed for this read — start a new read with the other hotkey to change it.")
            Spacer(minLength: 8)
            Text(String(format: "%.1f×", state.playbackRate))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .help("Speed — change it with the Faster / Slower hotkeys (Settings → Shortcuts).")
            Button {
                state.dismissReaderOverlay()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the reader for this read (Settings → General brings it back)")
        }
    }

    private var languageName: String {
        state.reading?.language.displayName ?? ""
    }

    // MARK: Sentences
    //
    // Each line reserves its space, so the window's height depends only on
    // which lines are switched on — it never jumps around as sentences of
    // different lengths go by.

    @ViewBuilder
    private var sentences: some View {
        VStack(alignment: .leading, spacing: 6) {
            if state.readerShowsPreviousSentence {
                contextLine(state.reading?.sentence(at: playback.currentSentence - 1))
            }
            if state.readerShowsCurrentSentence {
                Text(currentAttributedSentence)
                    .font(.system(size: 15))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.readerShowsNextSentence {
                contextLine(state.reading?.sentence(at: playback.currentSentence + 1))
            }
        }
    }

    private func contextLine(_ text: String?) -> some View {
        Text(text ?? " ")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1, reservesSpace: true)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The current sentence with the word being spoken picked out.
    private var currentAttributedSentence: AttributedString {
        guard let sentence = state.currentReaderSentence else {
            return AttributedString(" ")
        }
        var text = AttributedString(sentence.text)
        text.foregroundColor = .primary
        guard let index = sentence.index(atProgress: playback.sentenceProgress),
              sentence.words.indices.contains(index) else { return text }
        let word = sentence.words[index]
        guard word.offset >= 0,
              word.offset + word.length <= text.characters.count else { return text }
        let start = text.index(text.startIndex, offsetByCharacters: word.offset)
        let end = text.index(start, offsetByCharacters: word.length)
        text[start..<end].backgroundColor = Color.accentColor.opacity(0.30)
        text[start..<end].font = .system(size: 15, weight: .semibold)
        return text
    }

    // MARK: Footer — progress, transport, position.

    private var footer: some View {
        VStack(spacing: 8) {
            ProgressView(value: min(playback.currentSeconds, playback.availableSeconds),
                         total: max(playback.availableSeconds, 0.01))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(.accentColor)
            HStack(spacing: 2) {
                TransportButton(systemName: "backward.frame.fill",
                                size: 28, iconSize: 11,
                                help: "Previous sentence") {
                    playback.seekSentence(by: -1)
                }
                TransportButton(systemName: isPaused ? "play.fill" : "pause.fill",
                                size: 34, iconSize: 14, prominent: true,
                                help: isPaused ? "Resume" : "Pause") {
                    playback.togglePauseResume()
                }
                TransportButton(systemName: "forward.frame.fill",
                                size: 28, iconSize: 11,
                                help: "Next sentence") {
                    playback.seekSentence(by: 1)
                }
                Spacer(minLength: 8)
                Text(positionLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isPaused: Bool { playback.state == .paused }

    private var positionLabel: String {
        guard playback.totalSentences > 0 else { return "" }
        let position = "\(playback.currentSentence + 1) / \(playback.totalSentences)"
        return isPaused ? "Paused · \(position)" : position
    }
}
