import Testing
@testable import sr

@Suite struct VoiceRecorderTests {
    /// Linear amplitude would spend almost the whole meter on the loudest few
    /// dB and sit near zero through ordinary speech, which reads as "the
    /// microphone is dead" exactly when it is working.
    @Test func theLevelMeterUsesADecibelScale() {
        // Full scale and silence anchor the ends.
        #expect(VoiceRecorder.normalizedLevel(0) == 1)
        #expect(VoiceRecorder.normalizedLevel(-50) == 0)
        #expect(VoiceRecorder.normalizedLevel(-160) == 0)

        // Speech lives around -30 to -12 dBFS and has to be visibly moving
        // there, not pinned to the bottom of the bar.
        let quiet = VoiceRecorder.normalizedLevel(-30)
        let normal = VoiceRecorder.normalizedLevel(-18)
        let loud = VoiceRecorder.normalizedLevel(-6)
        #expect(quiet > 0.3 && quiet < 0.5)
        #expect(normal > quiet)
        #expect(loud > normal)
        #expect(loud < 1)
    }

    @Test func absurdReadingsDoNotBreakTheMeter() {
        #expect(VoiceRecorder.normalizedLevel(20) == 1)
        #expect(VoiceRecorder.normalizedLevel(-.infinity) == 0)
        #expect(VoiceRecorder.normalizedLevel(.nan) == 0)
    }
}
