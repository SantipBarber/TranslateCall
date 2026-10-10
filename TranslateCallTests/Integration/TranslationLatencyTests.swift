import AppKit
import Combine
import SwiftUI
import Testing
@preconcurrency import Translation
@testable import TranslateCall

/// Test-only stand-in for the bridge (F8.5.4 D-6): runs a job inside `.translationTask`, either on a
/// fresh session (the configuration is invalidated first, as the pre-F8.5.4 bridge did per sentence)
/// or on the session the previous job left open.
@MainActor
final class TranslationProbe: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private var job: (@MainActor (TranslationSession) async -> Void)?
    private var done: CheckedContinuation<Void, Never>?

    /// Runs `job` inside a `.translationTask` session. `freshSession` invalidates the configuration
    /// first (one session per job); otherwise the first call opens the session and `job` keeps it.
    func run(source: Locale.Language, target: Locale.Language, freshSession: Bool,
             _ job: @escaping @MainActor (TranslationSession) async -> Void) async {
        await withCheckedContinuation { continuation in
            self.job = job
            self.done = continuation
            if configuration == nil {
                configuration = .init(source: source, target: target)
            } else if freshSession {
                configuration?.invalidate()
            }
        }
    }

    func fired(_ session: TranslationSession) async {
        guard let job else { return }
        self.job = nil
        await job(session)
        done?.resume()
        done = nil
    }
}

struct TranslationProbeView: View {
    @ObservedObject var probe: TranslationProbe
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(probe.configuration) { session in await probe.fired(session) }
    }
}

/// Short ES sentences (≤ 15 words), like what the VAD hands over after each pause.
let latencySentences = [
    "Hola, ¿me oyes bien?",
    "Vamos a revisar el presupuesto del próximo trimestre.",
    "Creo que la reunión puede durar media hora.",
    "¿Puedes compartir la pantalla, por favor?",
    "El equipo de ventas ha cerrado tres contratos.",
    "Necesitamos una decisión antes del viernes.",
    "Te envío el documento después de la llamada.",
    "No estoy de acuerdo con esa cifra.",
    "Perfecto, lo hablamos mañana por la mañana.",
    "Gracias a todos por venir.",
]

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let mid = sorted.count / 2
    return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
}

func percentile90(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.9).rounded(.up)) - 1)]
}

/// Hosts a view off-screen the same way the app hosts its bridges (`orderBack`, borderless, far away).
@MainActor
func hostOffscreen(_ view: some View) -> NSWindow {
    let window = NSWindow(contentRect: .init(x: -10_000, y: -10_000, width: 10, height: 10),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: view)
    window.orderBack(nil)
    return window
}

extension IntegrationTests {
    /// F8.5.4 D-6: is the translation latency the session start-up (one session per sentence) or the
    /// translation itself? Both numbers go to build/reports/latency.json; nothing is asserted here.
    @Suite("Translation latency (session reuse)", .serialized) @MainActor
    struct TranslationLatencyTests {
        @Test("one session per sentence (pre-F8.5.4 bridge)")
        func sessionPerSentence() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let probe = TranslationProbe()
            let window = hostOffscreen(TranslationProbeView(probe: probe))
            defer { window.close() }
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")

            var samples: [Double] = []
            var failures: [String] = []
            for sentence in latencySentences {
                let start = ContinuousClock.now
                await probe.run(source: src, target: dst, freshSession: true) { session in
                    do { _ = try await session.translate(sentence) } catch { failures.append("\(error)") }
                }
                samples.append(start.duration(to: .now).milliseconds)
            }
            await LatencyReport.shared.record(fixture: "es→en session per sentence (median)", stage: .translate,
                                              ms: median(samples))
            await LatencyReport.shared.record(fixture: "es→en session per sentence (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(samples.count == latencySentences.count)
            #expect(failures.isEmpty, "translation failures would skew the latency: \(failures)")
        }

        @Test("one session kept open (F8.5.4 bridge), first sentence excluded")
        func persistentSession() async throws {
            try await requireTranslationPack(from: "es", to: "en")
            let probe = TranslationProbe()
            let window = hostOffscreen(TranslationProbeView(probe: probe))
            defer { window.close() }
            let src = Locale.Language(identifier: "es"), dst = Locale.Language(identifier: "en")

            var first: Double = 0
            var samples: [Double] = []
            var failures: [String] = []
            let opened = ContinuousClock.now
            await probe.run(source: src, target: dst, freshSession: false) { session in
                for (index, sentence) in latencySentences.enumerated() {
                    let start = index == 0 ? opened : ContinuousClock.now
                    do { _ = try await session.translate(sentence) } catch { failures.append("\(error)") }
                    let elapsed = start.duration(to: .now).milliseconds
                    if index == 0 { first = elapsed } else { samples.append(elapsed) }
                }
            }
            await LatencyReport.shared.record(fixture: "es→en kept session, first sentence", stage: .translate,
                                              ms: first)
            await LatencyReport.shared.record(fixture: "es→en kept session (median)", stage: .translate,
                                              ms: median(samples))
            await LatencyReport.shared.record(fixture: "es→en kept session (p90)", stage: .translate,
                                              ms: percentile90(samples))
            #expect(samples.count == latencySentences.count - 1)
            #expect(failures.isEmpty, "translation failures would skew the latency: \(failures)")
        }
    }
}
