import SRCore
import Testing
@testable import sr

@Suite @MainActor struct CLIValidationTests {
    @Test(arguments: [
        ["--speak", "article.md", "--locla"],
        ["--speak-clipboard", "--unknown"],
        ["--speak", "article.md", "extra.md"],
        ["--speak", "article.md", "--speak-clipboard"],
        ["--speak", "article.md", "--speak", "other.md"],
        ["--install-kokoro", "--speak-clipboard"],
        ["--install-kokoro", "--local"],
        ["--local"],
        ["--speak", "article.md", "--lang"],
        ["--speak", "article.md", "--lang", "de"],
        ["--speak", "article.md", "--lang", "en", "--lang", "no"],
        ["--install-kokoro", "--lang", "en"],
        ["--lang", "no"],
    ])
    func rejectsAmbiguousOrUnknownArguments(_ args: [String]) {
        guard case .usage(let error) = HeadlessCLI.Mode(arguments: ["sr"] + args) else {
            Issue.record("unsafe arguments accepted: \(args)")
            return
        }
        #expect(error != nil)
    }

    @Test(arguments: [["--speak", "--help"], ["--help", "--speak"], ["--unknown", "-h"]])
    func helpDoesNotRequireACompleteCommand(_ args: [String]) {
        guard case .usage(let error) = HeadlessCLI.Mode(arguments: ["sr"] + args) else {
            Issue.record("help attempted to execute a command")
            return
        }
        #expect(error == nil)
    }

    @Test func acceptsFlagsBeforeCommandAndStdin() {
        guard case .speak(let source, let language, let local, let override) = HeadlessCLI.Mode(
            arguments: ["sr", "--local", "--speak", "-", "--override-cost-controls"]) else {
            Issue.record("valid stdin invocation rejected")
            return
        }
        #expect(source == "-")
        #expect(language == .english)
        #expect(local)
        #expect(override)
    }

    @Test(arguments: [SpeechLanguage.english, SpeechLanguage.norwegian])
    func languageFlagSelectsTheProfile(_ expected: SpeechLanguage) {
        guard case .speak(_, let language, _, _) = HeadlessCLI.Mode(
            arguments: ["sr", "--speak", "article.md", "--lang", expected.rawValue]) else {
            Issue.record("valid --lang invocation rejected")
            return
        }
        #expect(language == expected)

        guard case .speakClipboard(let clipboardLanguage, _, _) = HeadlessCLI.Mode(
            arguments: ["sr", "--lang", expected.rawValue, "--speak-clipboard"]) else {
            Issue.record("valid --lang clipboard invocation rejected")
            return
        }
        #expect(clipboardLanguage == expected)
    }
}
