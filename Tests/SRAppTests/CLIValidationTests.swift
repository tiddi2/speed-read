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

    @Test(arguments: [
        ["--speak", "article.md", "--language"],
        ["--speak", "article.md", "--language", "klingon"],
        ["--speak-clipboard", "--language", "norwegian"],
        ["--install-kokoro", "--language", "nb"],
    ])
    func rejectsMalformedLanguageArguments(_ args: [String]) {
        guard case .usage(let error) = HeadlessCLI.Mode(arguments: ["sr"] + args) else {
            Issue.record("unsafe arguments accepted: \(args)")
            return
        }
        #expect(error != nil)
    }

    @Test func parsesReadingLanguage() {
        guard case .speak(_, _, _, let language) = HeadlessCLI.Mode(
            arguments: ["sr", "--speak", "artikkel.md", "--language", "nb"]) else {
            Issue.record("valid --language invocation rejected")
            return
        }
        #expect(language == .norwegian)
    }

    /// No --language means "use the saved preference", which the read
    /// resolves — the parser must not substitute a default of its own.
    @Test func languageIsUnsetWhenNotRequested() {
        guard case .speakClipboard(_, _, let language) = HeadlessCLI.Mode(
            arguments: ["sr", "--speak-clipboard"]) else {
            Issue.record("valid clipboard invocation rejected")
            return
        }
        #expect(language == nil)
    }

    @Test func acceptsFlagsBeforeCommandAndStdin() {
        guard case .speak(let source, let local, let override, _) = HeadlessCLI.Mode(
            arguments: ["sr", "--local", "--speak", "-", "--override-cost-controls"]) else {
            Issue.record("valid stdin invocation rejected")
            return
        }
        #expect(source == "-")
        #expect(local)
        #expect(override)
    }
}
