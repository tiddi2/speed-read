import Testing
@testable import SRCore

// No Foundation import — see KokoroTestSupport for why the CLT toolchain
// cannot take the _Testing_Foundation overlay.

/// The offline engines fail for reasons that have nothing to do with a
/// network or an account, and saying "Could not reach ElevenLabs" or
/// "HTTP 500" for them sends someone to check their wifi over a file on
/// their own disk.
@Suite struct LocalFailureMessageTests {
    @Test func cloudFailuresAreNotClaimedByTheOfflineSurface() {
        #expect(LocalVoices.failureMessage(for: .missingAPIKey) == nil)
        #expect(LocalVoices.failureMessage(for: .cancelled) == nil)
        #expect(LocalVoices.failureMessage(for: .budgetExceeded) == nil)
        #expect(LocalVoices.failureMessage(
            for: .http(status: 500, body: "upstream unavailable")) == nil)
        #expect(LocalVoices.failureMessage(
            for: .network(underlying: "timed out")) == nil)
        #expect(LocalVoices.failureMessage(
            for: .invalidAudio(historyItemID: nil, billedCharacters: nil)) == nil)
    }

    /// Both engines tag their failures, so neither is left to the cloud text.
    @Test func bothEnginesAreRecognised() {
        #expect(LocalVoices.failureMessage(
            for: .network(underlying: "f5: daemon unavailable")) != nil)
        #expect(LocalVoices.failureMessage(
            for: .network(underlying: "kokoro: daemon unavailable")) != nil)
        #expect(LocalVoices.failureMessage(
            for: .http(status: 500, body: "f5: RuntimeError")) != nil)
    }

    /// The regression this file exists for: a 500 from a local engine used to
    /// print its status and drop the daemon's message entirely.
    @Test func unrecognisedDaemonErrorsAreShownRatherThanSwallowed() {
        let message = LocalVoices.failureMessage(
            for: .http(status: 500, body: "f5: MemoryError"))
        #expect(message?.contains("MemoryError") == true)
        // And it says where the rest of the story is.
        #expect(message?.contains(LocalVoices.logHint) == true)
    }

    /// A missing recording is the one an ordinary user can actually fix, so
    /// the message has to name the place to fix it.
    @Test func setupFailuresNameTheirFix() {
        let missing = LocalVoices.failureMessage(
            for: .http(status: 500, body: "f5: voice is missing its reference recording"))
        #expect(missing?.contains("Settings → Voices") == true)

        let notInstalled = LocalVoices.failureMessage(
            for: .network(underlying: "f5: Norwegian voice not installed"))
        #expect(notInstalled?.contains("Settings → General") == true)

        let restart = LocalVoices.failureMessage(
            for: .network(underlying: "kokoro: incompatible daemon"))
        #expect(restart?.contains("reopen sr") == true)
    }

    /// No message may name the cloud provider: reaching it is never what
    /// went wrong here.
    @Test func noOfflineMessageMentionsTheCloudProvider() {
        let details = [
            "f5: daemon unavailable", "f5: socket I/O failed",
            "f5: language not installed", "f5: reference voice missing",
            "kokoro: local TTS not installed", "kokoro: incompatible daemon",
        ]
        for detail in details {
            let message = LocalVoices.failureMessage(
                for: .network(underlying: detail))
            #expect(message != nil, "unhandled: \(detail)")
            #expect(message?.contains("ElevenLabs") == false, "cloud in: \(detail)")
            #expect(message?.contains("HTTP") == false, "status in: \(detail)")
        }
    }

    /// The prefix is the whole identification mechanism, so a message that
    /// merely starts with the letters must not be mistaken for a tagged one.
    @Test func onlyTheTagCountsAsAnOfflineFailure() {
        #expect(LocalVoices.failureMessage(
            for: .network(underlying: "f5 is a great model")) == nil)
        #expect(LocalVoices.failureMessage(
            for: .network(underlying: "kokoroish")) == nil)
    }
}
