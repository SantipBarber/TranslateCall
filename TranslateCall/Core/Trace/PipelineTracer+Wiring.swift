import CoreAudio
import Foundation

/// Wraps the stage factories `AudioCoordinator` takes, so whoever builds the coordinator turns tracing
/// on without the coordinator knowing (M9 tasks.md P1). The app builds none of these today.
@MainActor
extension PipelineTracer {
    func tracingVAD(_ make: @escaping () async -> any VADService) -> () async -> any VADService {
        { TracingVADService(wrapping: await make(), tracer: self) }
    }

    func tracingSTT(
        _ make: @escaping (Locale) -> any SpeechRecognizerService
    ) -> (Locale) -> any SpeechRecognizerService {
        { TracingSTTService(wrapping: make($0), tracer: self) }
    }

    func tracing(_ service: any TranslationService) -> any TranslationService {
        TracingTranslationService(wrapping: service, tracer: self)
    }

    func tracingTTS(
        _ make: @escaping (Locale, AudioDeviceID?) throws -> any SynthesisService
    ) -> (Locale, AudioDeviceID?) throws -> any SynthesisService {
        { TracingSynthesisService(wrapping: try make($0, $1), tracer: self) }
    }

    func tracing(_ synthesizer: any UtteranceSynthesizer) -> any UtteranceSynthesizer {
        TracingUtteranceSynthesizer(inner: synthesizer, tracer: self)
    }

    func tracing(_ output: any AudioOutputting) -> any AudioOutputting {
        TracingAudioOutput(wrapping: output, tracer: self)
    }
}
