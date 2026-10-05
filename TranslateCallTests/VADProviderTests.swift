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

    @Test("Review focus: Silero cannot load (no model, offline) → Energy, and the next session retries Silero in the background")
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
        #expect(await waitUntil { calls.values.count == 2 }, "the second session starts a background retry")
    }

    @Test("I2: after a failed load, Start never waits on the next Silero load; Silero once the retry succeeds")
    func failedLoadRetriesInBackground() async {
        let gate = AsyncGate()
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            switch calls.values.count {
            case 1: throw SileroUnavailable()          // e.g. offline at the first session
            case 2: await gate.wait()                  // the retry's download hangs
            default: break
            }
            return MockVADService(engine: .silero)
        }
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .energy)

        let engines = LockedArray<VADEngine>()
        let next = Task { engines.append(await provider.makeVAD(config: VADConfiguration()).engine) }
        #expect(await waitUntil { engines.values == [.energy] }, "makeVAD must not await the hanging load")
        #expect(await waitUntil { gate.waiterCount == 1 })

        // While the retry is still loading, sessions keep getting Energy and no second retry starts.
        #expect(await provider.makeVAD(config: VADConfiguration()).engine == .energy)
        #expect(calls.values.count == 2)

        gate.open()
        await next.value
        #expect(await waitUntil {
            await provider.makeVAD(config: VADConfiguration()).engine == .silero
        })
        #expect(provider.activeEngine == .silero)
    }

    @Test("I2: a failed launch preload → the next session gets Energy at once and retries in the background")
    func failedPreloadRetriesInBackground() async {
        let gate = AsyncGate()
        let calls = LockedArray<Int>()
        let provider = VADProvider { _ in
            calls.append(1)
            switch calls.values.count {
            case 1: throw SileroUnavailable()
            case 2: await gate.wait()
            default: break
            }
            return MockVADService(engine: .silero)
        }
        provider.preload()
        #expect(await waitUntil { calls.values.count == 1 })
        #expect(await waitUntil { !provider.isWarmingUp }, "the failed preload has settled")

        let engines = LockedArray<VADEngine>()
        let next = Task { engines.append(await provider.makeVAD(config: VADConfiguration()).engine) }
        #expect(await waitUntil { engines.values == [.energy] }, "makeVAD must not await the hanging load")
        #expect(await waitUntil { gate.waiterCount == 1 })

        gate.open()
        await next.value
        #expect(await waitUntil {
            await provider.makeVAD(config: VADConfiguration()).engine == .silero
        })
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
