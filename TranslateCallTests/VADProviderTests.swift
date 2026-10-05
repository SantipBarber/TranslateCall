import Foundation
import Testing
@testable import TranslateCall

private struct SileroUnavailable: Error {}

@Suite("VADProvider") @MainActor
struct VADProviderTests {

    @Test("Silero when its model loads; the loader gets a validated configuration (REQ-V-01/06)")
    func usesSileroWhenLoaderSucceeds() async {
        let configs = LockedArray<VADConfiguration>()
        let provider = VADProvider { config in
            configs.append(config)
            return MockVADService(engine: .silero)
        }
        var config = VADConfiguration()
        config.minSilenceDuration = -1

        let vad = await provider.makeVAD(config: config)

        #expect(vad.engine == .silero)
        #expect(provider.activeEngine == .silero)
        #expect(configs.values.map(\.minSilenceDuration) == [0])
    }

    @Test("Review focus: Silero cannot load (no model, offline) → Energy, and the next session retries Silero")
    func fallsBackToEnergyWhenSileroFails() async {
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            throw SileroUnavailable()
        }
        let first = await provider.makeVAD(config: VADConfiguration())
        let second = await provider.makeVAD(config: VADConfiguration())
        #expect(first.engine == .energy)
        #expect(second.engine == .energy)
        #expect(provider.activeEngine == .energy)
        #expect(calls.values.count == 2)
    }

    @Test("Review focus: while the launch preload is still loading Silero, a session starts at once on Energy")
    func energyWhileWarming() async {
        let gate = AsyncGate()
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            if calls.values.count == 1 { await gate.wait() }   // the preload's load hangs
            return MockVADService(engine: .silero)
        }
        provider.preload()
        #expect(await waitUntil { gate.waiterCount == 1 })

        let during = await provider.makeVAD(config: VADConfiguration())
        #expect(during.engine == .energy)

        gate.open()
        #expect(await waitUntil {
            await provider.makeVAD(config: VADConfiguration()).engine == .silero
        })
    }

    @Test("preload runs once")
    func preloadOnce() async {
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            return MockVADService(engine: .silero)
        }
        provider.preload()
        provider.preload()
        #expect(await waitUntil { calls.values.count == 1 })
        // Negative check: bounded wait; a second preload must not load again.
        #expect(!(await waitUntil(timeout: .milliseconds(200)) { calls.values.count > 1 }))
    }
}
