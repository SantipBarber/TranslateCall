import AVFoundation
import Speech
import SwiftUI
import Testing
import Translation
@testable import TranslateCall

struct MissingPrerequisite: Error, CustomStringConvertible {
    let description: String
}

/// Fails (never skips) when a prerequisite is missing (REQ-W-23).
func requirePrerequisite(_ isMet: Bool, _ what: String) throws {
    guard isMet else {
        Issue.record("Missing prerequisite: \(what) — run `just setup`; see specs/m8.5-stabilization/f8.5.0-dev-workflow")
        throw MissingPrerequisite(description: what)
    }
}

/// Speech Recognition permission for the test host (prompts once on a fresh machine).
func requireSpeechAuthorization() async throws {
    var status = SFSpeechRecognizer.authorizationStatus()
    if status == .notDetermined {
        status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
    }
    try requirePrerequisite(status == .authorized, "Speech Recognition permission for TranslateCall (status \(status.rawValue))")
}

/// Whether the Apple Translation pack for this pair is downloaded (`.supported` = not yet downloaded).
func isTranslationPackInstalled(from source: String, to target: String) async -> Bool {
    let status = await LanguageAvailability().status(from: Locale.Language(identifier: source),
                                                     to: Locale.Language(identifier: target))
    return status == .installed
}

/// Fails with the pack name instead of hanging on `.translationTask` when a pack is missing.
func requireTranslationPack(from source: String, to target: String) async throws {
    try requirePrerequisite(await isTranslationPackInstalled(from: source, to: target),
                            "Translation language pack \(source)→\(target) (System Settings → General → Language & Region → Translation Languages)")
}

/// Hosts a TranslationBridge in an offscreen window so `.translationTask` runs inside the test host.
/// Keep the returned window alive for the duration of the test.
@MainActor
func hostTranslationBridge() -> (TranslationBridgeModel, NSWindow) {
    let model = TranslationBridgeModel()
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = NSHostingView(rootView: TranslationBridge(model: model))
    window.orderBack(nil)
    return (model, window)
}

struct TranscriptRun {
    let result: TranscriptionResult
    /// End of speech in the fixture → VAD closed the segment.
    let vadMs: Double
    /// Segment closed → first transcript emitted.
    let sttMs: Double
}

/// fixture → FileAudioSource (real-time) → EnergyVAD → STT; returns the first transcript and stage timings.
@MainActor
func firstTranscript(of fixture: AudioFixture, using stt: any SpeechRecognizerService,
                     timeout: Duration = .seconds(30)) async throws -> TranscriptRun {
    let source = try FileAudioSource(url: Fixtures.url(for: fixture), realtime: true)
    let vad = EnergyVADService()

    // Tee VAD segments so we can timestamp when the segment closed.
    let (segments, segCont) = AsyncStream.makeStream(of: SpeechSegment.self, bufferingPolicy: .unbounded)
    var segmentClosedAt: ContinuousClock.Instant?
    let tee = Task { @MainActor in
        for await segment in vad.speechSegments {
            if segmentClosedAt == nil { segmentClosedAt = .now }
            segCont.yield(segment)
        }
        segCont.finish()
    }
    try await stt.activate(stream: segments)

    let started = ContinuousClock.now
    let audio = try await source.startCapture()
    try await vad.activate(stream: audio)
    let speechEnd = started + .seconds(fixture.durationSeconds)

    let result = try await withThrowingTaskGroup(of: TranscriptionResult?.self) { group in
        group.addTask { for await result in stt.transcriptionStream { return result }; return nil }
        group.addTask { try await Task.sleep(for: timeout); return nil }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
    let gotAt = ContinuousClock.now
    source.stopCapture()
    await vad.deactivate()
    await stt.deactivate()
    tee.cancel()

    guard let result else {
        Issue.record("No transcript for \(fixture.id) within \(timeout)")
        throw MissingPrerequisite(description: "transcript for \(fixture.id)")
    }
    let closed = segmentClosedAt ?? gotAt
    return TranscriptRun(result: result,
                         vadMs: speechEnd.duration(to: closed).milliseconds,
                         sttMs: closed.duration(to: gotAt).milliseconds)
}
