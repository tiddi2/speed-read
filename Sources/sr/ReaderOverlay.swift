import AppKit
import Combine
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
    /// Fixed width, variable height. A reading column that reflowed as
    /// sentences came and went would be miserable to read, and holding the
    /// width still means the text's height depends on the text alone — which
    /// is what lets the window size itself to whole sentences.
    static let width: CGFloat = 560

    private var panel: ReaderOverlayPanel?
    private var hosting: ReaderOverlayHostingView?
    private var moveObserver: NSObjectProtocol?
    private var layoutObserver: AnyCancellable?
    private let layout = ReaderOverlayLayout()
    private let settings = SettingsStore()
    /// Suppresses position persistence while *we* are the ones moving the
    /// window, so programmatic placement never overwrites the user's drag.
    private var isPositioning = false
    /// Top-right corner the overlay hangs from, in screen coordinates. Height
    /// changes are applied from here rather than from the current frame, so a
    /// window nudged upwards to fit a long sentence drops back to the user's
    /// spot when a short one follows instead of walking up the screen.
    private var anchor: NSPoint?

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
        let screen = Self.screen(containing: point)
        // Set the ceiling before measuring: it caps how tall the pane may ask
        // the window to be on this particular display.
        layout.maxTextHeight = Self.maxTextHeight(on: screen)
        resizeToFit()
        place(panel, on: screen)
        // orderFrontRegardless, not makeKeyAndOrderFront: sr is reading
        // another app's selection and must not steal focus. This holds
        // whichever activation policy sr is running under (see AppIcon) —
        // the panel is non-activating and never becomes key.
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
            ReaderOverlayView(layout: layout)
                .environmentObject(state)
                .frame(width: Self.width)))
        panel.contentView = hosting
        self.hosting = hosting

        // Sentences are shown whole, so the window follows the text: whenever
        // SwiftUI re-measures the pane (a new sentence, a settings change, a
        // different screen's ceiling) the frame is re-fitted to it. The hop to
        // the next run-loop turn lets SwiftUI apply the change first — willSet
        // is what publishes it, so the view has not re-laid-out yet.
        layoutObserver = layout.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.resizeToFit()
                }
            }
        }

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
        // Grow downwards: the top edge is the one the user aligned. A taller
        // window can then reach past the bottom of the screen, so re-clamp.
        let top = anchor?.y ?? panel.frame.maxY
        let right = anchor?.x ?? panel.frame.maxX
        var frame = NSRect(x: right - Self.width,
                           y: top - height,
                           width: Self.width,
                           height: height)
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin = clamped(frame.origin, size: frame.size, in: visible)
        }
        isPositioning = true
        defer { isPositioning = false }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    private func place(_ panel: ReaderOverlayPanel, on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let offset = settings.readerOverlayCornerOffset
        let size = panel.frame.size
        let corner = NSPoint(x: visible.maxX + offset.x, y: visible.maxY + offset.y)
        anchor = corner
        let origin = NSPoint(x: corner.x - size.width, y: corner.y - size.height)
        isPositioning = true
        defer { isPositioning = false }
        panel.setFrameOrigin(clamped(origin, size: size, in: visible))
    }

    /// Keep the whole window inside the visible area. A position dragged on a
    /// larger display, a resolution change, or a sentence that made the window
    /// taller would otherwise push part of it out of sight.
    private func clamped(_ origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX), max(visible.maxX - size.width, visible.minX)),
            y: min(max(origin.y, visible.minY), max(visible.maxY - size.height, visible.minY)))
    }

    private func rememberPosition() {
        guard !isPositioning, let panel,
              let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        anchor = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        settings.readerOverlayCornerOffset = (x: panel.frame.maxX - visible.maxX,
                                              y: panel.frame.maxY - visible.maxY)
    }

    /// How tall the sentence pane may grow on `screen` before it starts
    /// scrolling instead. Generous — the point of the overlay is to show the
    /// text — but never so tall that the window swallows the display or runs
    /// off the bottom of it.
    private static func maxTextHeight(on screen: NSScreen?) -> CGFloat {
        let available = (screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        // `available - 200` leaves room for the overlay's own header, footer
        // and margins; the 0.6 keeps it from covering most of the screen on a
        // tall display.
        return max(min(available * 0.6, available - 200), 160)
    }

    /// The screen a point is on. `NSMouseInRect` with `flipped: false` is the
    /// right containment test for AppKit's bottom-left screen coordinates.
    static func screen(containing point: NSPoint?) -> NSScreen? {
        guard let point else { return NSScreen.main }
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
    }
}

// MARK: - Layout model

/// Bridges SwiftUI's measurement of the sentence pane back to AppKit's window
/// sizing. The pane is the only part of the overlay whose height varies, and
/// the window has to follow it: sentences are shown whole, so the frame has to
/// be as tall as the text rather than the text cut to fit the frame.
@MainActor
final class ReaderOverlayLayout: ObservableObject {
    /// What SwiftUI says the three sentences need, unconstrained.
    @Published var naturalTextHeight: CGFloat = 0
    /// The ceiling for this screen. Past it the pane scrolls — still nothing
    /// hidden, but the window stops growing.
    @Published var maxTextHeight: CGFloat = 480

    /// Keeps a one-word sentence from collapsing the pane to a sliver.
    static let minTextHeight: CGFloat = 40

    var textHeight: CGFloat {
        min(max(naturalTextHeight, Self.minTextHeight), maxTextHeight)
    }

    /// True when the text is taller than the pane, so the pane scrolls and the
    /// current sentence has to be scrolled into view as the read moves on.
    var isScrolling: Bool { naturalTextHeight > maxTextHeight + 0.5 }
}

/// Reports the natural height of the sentence stack up to the layout model.
private struct ReaderTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - View

/// The overlay's content: the previous, current and next sentence in full, the
/// word cursor, transport, and read-only speed and language readouts.
///
/// **Nothing is truncated.** Every sentence wraps to as many lines as it takes
/// and the window grows to fit. Only a pathological sentence — the chunker
/// allows up to 5,000 characters, which is minified text or OCR without
/// punctuation, not prose — can exceed the screen; then the pane scrolls and
/// follows the read instead of clipping.
///
/// Speed and language are deliberately *displays*, not controls. The language
/// is fixed for the life of a read — it is chosen by which hotkey started it
/// and pinned on every request (see SpeechLanguage), so offering a switch here
/// would promise something the read cannot do. Speed is changed with the
/// Faster/Slower hotkeys, which work without moving the mouse to the overlay.
struct ReaderOverlayView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var layout: ReaderOverlayLayout

    private var playback: PlaybackEngine { state.playback }

    /// Scroll anchor for the sentence being read.
    private static let currentSentenceID = "sr.reader.current"
    private static let currentFontSize: CGFloat = 16
    private static let contextFontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.readerShowsAnySentence {
                textPane
            }
            footer
        }
        .padding(16)
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
    // The pane is given an exact height — the text's own, clamped to what the
    // screen allows — so the window can size itself to it. Sentences are never
    // line-limited; when the clamp bites, the pane scrolls and keeps the
    // sentence being read in view.

    private var textPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                sentenceStack
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        GeometryReader { geometry in
                            Color.clear.preference(key: ReaderTextHeightKey.self,
                                                   value: geometry.size.height)
                        }
                    )
            }
            .frame(height: layout.textHeight)
            .onChange(of: playback.currentSentence) { _, _ in
                guard layout.isScrolling, state.readerShowsCurrentSentence else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.currentSentenceID, anchor: .center)
                }
            }
        }
        .onPreferenceChange(ReaderTextHeightKey.self) { [layout] height in
            // The preference callback is not actor-isolated; the layout model
            // is main-actor state, so hop before touching it.
            Task { @MainActor in layout.naturalTextHeight = height }
        }
    }

    private var sentenceStack: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.readerShowsPreviousSentence, let previous = neighbour(-1) {
                contextSentence(previous)
            }
            if state.readerShowsCurrentSentence {
                Text(currentAttributedSentence)
                    .font(.system(size: Self.currentFontSize))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(Self.currentSentenceID)
            }
            if state.readerShowsNextSentence, let next = neighbour(1) {
                contextSentence(next)
            }
        }
    }

    /// nil at the first and last sentence of the read, where the line is simply
    /// left out rather than held open as a blank.
    private func neighbour(_ delta: Int) -> String? {
        state.reading?.sentence(at: playback.currentSentence + delta)
    }

    private func contextSentence(_ text: String) -> some View {
        Text(text)
            .font(.system(size: Self.contextFontSize))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
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
        text[start..<end].font = .system(size: Self.currentFontSize, weight: .semibold)
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
