import Foundation
import Testing
@preconcurrency import Translation
@testable import TranslateCall

// `Translation` also declares a `TranslationError`: the app's is spelled `TranslateCall.TranslationError` here.

private let esLanguage = Locale.Language(identifier: "es")
private let enLanguage = Locale.Language(identifier: "en")

private struct SessionFailure: Error {}

@Suite("TranslationBridgeModel (F8.5.4)", .serialized) @MainActor
struct TranslationBridgeModelTests {

    private func makeModel(_ clock: TestClock = TestClock()) -> (TranslationBridgeModel, TranslationSessionDriver) {
        let model = TranslationBridgeModel(timeout: .seconds(5), clock: clock)
        return (model, TranslationSessionDriver(model: model))
    }

    @Test("sentences share one session: the configuration is set once (REQ-TR-01, T4)")
    func persistentSession() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        for text in ["uno", "dos", "tres"] {
            #expect(try await model.translate(text, from: esLanguage, to: enLanguage) == "EN:\(text)")
        }
        #expect(driver.runs == 1)
        #expect(driver.session.translated == ["uno", "dos", "tres"])
    }

    @Test("concurrent requests are answered in submission order (REQ-TR-03)")
    func fifoOrder() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })
        let second = Task { try await model.translate("dos", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 2 })
        let third = Task { try await model.translate("tres", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 3 })

        driver.session.release(with: "EN:uno")
        #expect(try await first.value == "EN:uno")
        #expect(try await second.value == "EN:dos")
        #expect(try await third.value == "EN:tres")
        #expect(driver.session.translated == ["uno", "dos", "tres"])
    }

    @Test("a new pair opens a new session that serves the request (REQ-TR-02a, REQ-TR-04)")
    func pairChange() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        _ = try await model.translate("hola", from: esLanguage, to: enLanguage)
        #expect(try await model.translate("hello", from: enLanguage, to: esLanguage) == "EN:hello")
        #expect(driver.runs == 2)
        #expect(model.configuration?.source == enLanguage)
    }

    @Test("warm-up opens the session and loads the model with a probe; the first sentence reuses it (REQ-TR-05)")
    func warmUp() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        model.warmUp(from: esLanguage, to: enLanguage)
        #expect(model.configuration?.source == esLanguage)
        #expect(driver.runs == 1)
        #expect(await waitUntil { driver.session.translated == [TranslationBridgeModel.warmUpProbe] })
        #expect(await waitUntil { model.queuedCount == 0 })
        _ = try await model.translate("hola", from: esLanguage, to: enLanguage)
        #expect(driver.runs == 1)
        #expect(driver.session.translated == [TranslationBridgeModel.warmUpProbe, "hola"])
    }

    @Test("warm-up does nothing while sentences are queued (REQ-TR-05)")
    func warmUpSkippedWhileBusy() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })

        model.warmUp(from: enLanguage, to: esLanguage)
        #expect(model.queuedCount == 1)
        #expect(model.configuration?.source == esLanguage)
        driver.session.release(with: "EN:uno")
        #expect(try await first.value == "EN:uno")
        #expect(driver.session.translated == ["uno"])
    }

    @Test("a timeout rebuilds the session and the retry answers (REQ-TR-11)")
    func timeoutThenRetry() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hang, .answer("retried")]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 && clock.sleeperCount == 1 })

        clock.advance(by: .seconds(5))
        #expect(try await result.value == "retried")
        #expect(driver.runs == 2)
    }

    @Test("two timeouts fail with timedOut; the next request is served by a rebuilt session (REQ-TR-11/12)")
    func timeoutTwice() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hang, .hang]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.translated.count == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { driver.session.translated.count == 2 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))

        await #expect(throws: TranslateCall.TranslationError.timedOut) { try await result.value }
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
        #expect(driver.runs == 3)
    }

    @Test("with no session ever delivered (no view), the request times out (REQ-TR-10, A8)")
    func neverFires() async throws {
        let clock = TestClock()
        let model = TranslationBridgeModel(timeout: .seconds(5), clock: clock)
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        await #expect(throws: TranslateCall.TranslationError.timedOut) { try await result.value }
        #expect(model.queuedCount == 0)
    }

    @Test("a session error is retried once on a rebuilt session (D-1)")
    func sessionErrorRetried() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.fail(SessionFailure()), .answer("ok")]
        #expect(try await model.translate("hola", from: esLanguage, to: enLanguage) == "ok")
        #expect(driver.runs == 2)
    }

    @Test("a second session error fails with sessionError; later requests still work")
    func sessionErrorTwice() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.fail(SessionFailure()), .fail(SessionFailure())]
        await #expect(throws: TranslateCall.TranslationError.sessionError(SessionFailure())) {
            try await model.translate("hola", from: esLanguage, to: enLanguage)
        }
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
    }

    @Test("an answer from a replaced session after the retry answered is ignored (NFR-TR-02)")
    func lateAnswerIgnored() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hangIgnoringCancel, .answer("retried")]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 && clock.sleeperCount == 1 })
        clock.advance(by: .seconds(5))
        #expect(try await result.value == "retried")

        driver.session.release(with: "late")   // a second resume would trap
        #expect(try await model.translate("adiós", from: esLanguage, to: enLanguage) == "EN:adiós")
    }

    @Test("cancelling the in-flight head caller throws CancellationError; its late answer is ignored (REQ-TR-13)")
    func inFlightHeadCancelled() async throws {
        let clock = TestClock()
        let (model, driver) = makeModel(clock)
        defer { driver.stop() }
        driver.session.script = [.hangIgnoringCancel]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })
        let second = Task { try await model.translate("dos", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 2 })

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        driver.session.release(with: "late")   // the session answers the cancelled head: must be ignored
        #expect(try await second.value == "EN:dos")
        #expect(model.queuedCount == 0)
    }

    @Test("cancelling a caller removes only its request (REQ-TR-13)")
    func callerCancellation() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let first = Task { try await model.translate("uno", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })
        let second = Task { try await model.translate("dos", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { model.queuedCount == 2 })

        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(model.queuedCount == 1)
        driver.session.release(with: "EN:uno")
        #expect(try await first.value == "EN:uno")
        #expect(driver.session.translated == ["uno"])
    }

    @Test("a request in flight when the session's task is cancelled is served by the next session (REQ-TR-03)")
    func inFlightSurvivesSessionRestart() async throws {
        let (model, driver) = makeModel()
        defer { driver.stop() }
        driver.session.script = [.hang]
        let result = Task { try await model.translate("hola", from: esLanguage, to: enLanguage) }
        #expect(await waitUntil { driver.session.hungCount == 1 })

        driver.restart()   // SwiftUI cancelled and restarted the task (e.g. the view re-appeared)
        #expect(try await result.value == "EN:hola")
        #expect(driver.session.translated == ["hola", "hola"])
    }

    @Test("AppleTranslationService.warmUp opens the model's session for the pair (REQ-TR-05)")
    func serviceWarmUpOpensSession() async {
        let model = TranslationBridgeModel()
        let driver = TranslationSessionDriver(model: model)
        defer { driver.stop() }
        let service = AppleTranslationService(model: model)
        await service.warmUp(from: esLanguage, to: enLanguage)
        #expect(model.configuration?.source == esLanguage)
        #expect(model.configuration?.target == enLanguage)
        #expect(await waitUntil { driver.session.translated == [TranslationBridgeModel.warmUpProbe] })
    }
}
