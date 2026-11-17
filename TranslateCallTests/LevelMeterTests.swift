import AVFoundation
import Testing
@testable import TranslateCall

@Suite("Level meter (REQ-FR-40/41)")
struct LevelMeterTests {
    @Test("peak of half scale is approximately −6.02 dBFS")
    func peakOfHalfScale() {
        let buffer = makePCMBuffer(frames: 64, fill: 0.5)
        #expect(abs(LevelMeter.peakDBFS(buffer) + 6.0206) < 0.01)
    }

    @Test("silence uses the dBFS floor")
    func silenceIsFloor() {
        let buffer = makePCMBuffer(frames: 64)
        #expect(LevelMeter.peakDBFS(buffer) == LevelMeter.silence)
    }

    @Test("a sustained run must meet the minimum duration")
    func sustainedNeedsDuration() {
        var detector = SustainedLevelDetector(threshold: -40, minDuration: .milliseconds(300))
        let sample = LevelSample(dbfs: -30, duration: .milliseconds(100))

        let first = detector.feed(sample)
        let second = detector.feed(sample)
        let third = detector.feed(sample)

        #expect(!first)
        #expect(!second)
        #expect(third)
    }

    @Test("a quiet sample resets a sustained run")
    func dipResets() {
        var detector = SustainedLevelDetector(threshold: -40, minDuration: .milliseconds(300))
        let loud = LevelSample(dbfs: -30, duration: .milliseconds(200))
        let quiet = LevelSample(dbfs: -80, duration: .milliseconds(10))

        let beforeDip = detector.feed(loud)
        let duringDip = detector.feed(quiet)
        let afterDip = detector.feed(loud)

        #expect(!beforeDip)
        #expect(!duringDip)
        #expect(!afterDip)
    }

    @Test("the detector stays true after reaching its threshold duration")
    func latches() {
        var detector = SustainedLevelDetector(threshold: -40, minDuration: .milliseconds(300))
        let loud = LevelSample(dbfs: -30, duration: .milliseconds(100))

        _ = detector.feed(loud)
        _ = detector.feed(loud)
        let reached = detector.feed(loud)
        let afterQuiet = detector.feed(LevelSample(dbfs: -80, duration: .milliseconds(100)))

        #expect(reached)
        #expect(afterQuiet)
    }
}
