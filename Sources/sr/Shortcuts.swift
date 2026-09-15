@preconcurrency import KeyboardShortcuts
import SRCore

/// Every global hotkey sr registers. All of them are user-configurable in
/// Settings → Shortcuts; the defaults below are deliberately few, so sr claims
/// as little of the global key space as it can get away with.
@MainActor
extension KeyboardShortcuts.Name {
    /// ⌥A — speak the selection as English (F-1).
    static let speakEnglish = Self("speakEnglish",
        default: .init(.a, modifiers: [.option]))
    /// ⌥⇧A — speak the selection as Norwegian (F-1).
    static let speakNorwegian = Self("speakNorwegian",
        default: .init(.a, modifiers: [.option, .shift]))

    /// Clipboard equivalents of the two above; unset by default.
    static let speakClipboardEnglish = Self("speakClipboardEnglish")
    static let speakClipboardNorwegian = Self("speakClipboardNorwegian")

    /// ⌥⇧. — pause/resume (F-2). Sits between the two sentence-step defaults,
    /// so `,` `.` `/` read left-to-right as back / pause / forward.
    static let pauseResume = Self("pauseResume",
        default: .init(.period, modifiers: [.option, .shift]))
    /// ⌥⇧, — previous sentence (restarts the current one when already past
    /// its opening; see PlaybackEngine.seekSentence).
    static let previousSentence = Self("previousSentence",
        default: .init(.comma, modifiers: [.option, .shift]))
    /// ⌥⇧/ — next sentence.
    static let nextSentence = Self("nextSentence",
        default: .init(.slash, modifiers: [.option, .shift]))

    /// ⌥⇧[ / ⌥⇧] — slower / faster. Bound by default because the reader
    /// overlay shows the speed but deliberately offers no control for it: the
    /// readout would be a dead end if there were no key to change it with.
    /// They extend the same ⌥⇧ cluster as the transport keys.
    static let speedDown = Self("speedDown",
        default: .init(.leftBracket, modifiers: [.option, .shift]))
    static let speedUp = Self("speedUp",
        default: .init(.rightBracket, modifiers: [.option, .shift]))

    /// Unset by default — the menu panel already has buttons for these.
    static let stop = Self("stop")
    static let restart = Self("restart")
    static let seekBackward = Self("seekBackward")
    static let seekForward = Self("seekForward")
    /// Show/hide the reader overlay.
    static let toggleReaderOverlay = Self("toggleReaderOverlay")
}

/// One configurable hotkey, as shown in Settings → Shortcuts.
struct ShortcutBinding: Identifiable {
    let name: KeyboardShortcuts.Name
    let title: String
    /// Optional one-line explanation under the recorder.
    let note: String?

    var id: String { name.rawValue }

    init(_ name: KeyboardShortcuts.Name, _ title: String, note: String? = nil) {
        self.name = name
        self.title = title
        self.note = note
    }
}

@MainActor
enum ShortcutCatalog {
    /// Grouped for the Settings list. Order here is the order on screen.
    static let groups: [(title: String, bindings: [ShortcutBinding])] = [
        ("Read selection", [
            ShortcutBinding(.speakEnglish, "Speak selection — English"),
            ShortcutBinding(.speakNorwegian, "Speak selection — Norwegian"),
        ]),
        ("Read clipboard", [
            ShortcutBinding(.speakClipboardEnglish, "Speak clipboard — English"),
            ShortcutBinding(.speakClipboardNorwegian, "Speak clipboard — Norwegian"),
        ]),
        ("Transport", [
            ShortcutBinding(.pauseResume, "Pause / resume"),
            ShortcutBinding(.stop, "Stop"),
            ShortcutBinding(.previousSentence, "Previous sentence",
                            note: "Restarts the current sentence unless pressed right at its start."),
            ShortcutBinding(.nextSentence, "Next sentence"),
            ShortcutBinding(.seekBackward, "Back 5 seconds"),
            ShortcutBinding(.seekForward, "Forward 5 seconds"),
            ShortcutBinding(.restart, "Restart from the top"),
        ]),
        ("Speed", [
            ShortcutBinding(.speedDown, "Slower (−0.1×)"),
            ShortcutBinding(.speedUp, "Faster (+0.1×)",
                            note: "The reader overlay shows the current speed; these keys are how you change it."),
        ]),
        ("Reader", [
            ShortcutBinding(.toggleReaderOverlay, "Show / hide the reader overlay"),
        ]),
    ]

    static var allNames: [KeyboardShortcuts.Name] {
        groups.flatMap(\.bindings).map(\.name)
    }

    /// Shortcut for the hotkey that reads `language`, for menu hints.
    static func speakName(for language: SpeechLanguage) -> KeyboardShortcuts.Name {
        switch language {
        case .english: return .speakEnglish
        case .norwegian: return .speakNorwegian
        }
    }

    static func clipboardName(for language: SpeechLanguage) -> KeyboardShortcuts.Name {
        switch language {
        case .english: return .speakClipboardEnglish
        case .norwegian: return .speakClipboardNorwegian
        }
    }
}
