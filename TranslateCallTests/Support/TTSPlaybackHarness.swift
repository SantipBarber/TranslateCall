import Foundation
@testable import TranslateCall

let english = Locale(identifier: "en-US")

/// A `TTSPlaybackService` wired to fakes, with recorders on both of its streams.
struct TTSPlaybackHarness {
    let primary: FakeSynthesizer
    let fallback: FakeSynthesizer?
    let output: FakeOutput
    let clock = TestClock()
    let metrics = TTSMetricsCollector(cap: 10)
    let service: TTSPlaybackService
    let speaking: StreamRecorder<Bool>
    let events: StreamRecorder<TTSEvent>

    init(primary: FakeSynthesizer = FakeSynthesizer(),
         fallback: FakeSynthesizer? = nil,
         output: FakeOutput = FakeOutput(),
         limits: TTSPlaybackLimits = .default) {
        self.primary = primary
        self.fallback = fallback
        self.output = output
        service = TTSPlaybackService(primary: primary, fallback: fallback, output: output,
                                     limits: limits, clock: clock, metrics: metrics)
        speaking = StreamRecorder(service.isSpeakingStream)
        events = StreamRecorder(service.events)
    }
}
