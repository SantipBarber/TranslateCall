import Foundation

/// Which pipeline an utterance went through (M9 REQ-BH-10).
nonisolated enum TraceDirection: String, Sendable, Codable {
    case outgoing, incoming
}

/// The points of an utterance's way through the pipeline that the trace stamps (M9 design §2.1).
nonisolated enum TraceStage: String, Sendable, Codable {
    case speechStart, vadEnd, sttFinal, translated, ttsFirstBuffer, ttsEnd, dropped
}

/// One stamp of one utterance. `seq` counts utterances per direction from 0 in each session.
nonisolated struct TraceEvent: Sendable, Equatable {
    let direction: TraceDirection
    let seq: Int
    let stage: TraceStage
    let time: ContinuousClock.Instant
    /// Stage data: `segmentAudioMs`/`trailingSilenceMs` (vadEnd), `text`/`engine`/`confidence`
    /// (sttFinal), `text` (translated), `mergedSeqs` (ttsFirstBuffer), `reason` (dropped).
    let detail: [String: String]
}

/// Where trace events go. Called synchronously from the pipeline's tasks, never from the audio
/// render thread; must not block (REQ-BH-11/12).
nonisolated protocol TraceSink: Sendable {
    func record(_ event: TraceEvent)
}

/// The production default: tracing off.
nonisolated struct NoopTraceSink: TraceSink {
    func record(_ event: TraceEvent) {}
}
