import AVFoundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Mic capture (BlackHole as controlled mic)", .serialized) @MainActor
    struct MicCaptureIntegrationTests {

        private func fixtureURL() throws -> URL {
            try Fixtures.url(for: #require(Fixtures.lang("en").first))
        }

        private func isolatedDefaults() -> UserDefaults {
            UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        }

        @Test("the selected input device is applied to the engine and its audio arrives (A5)")
        func selectedDeviceIsUsed() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)

            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            #expect(manager.activeInputDeviceID == blackHole.id)

            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 },
                    "no audio above -50 dBFS from BlackHole within 3 s")
        }

        @Test("switching mic mid-session keeps the same stream delivering audio (A5b, ≤ 500 ms gap)")
        func hotSwapKeepsStream() async throws {
            try await requireMicrophoneAuthorization()
            let probe = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: probe.inputDevices)
            let aggregate = try TemporaryAggregateDevice(wrapping: blackHole.uid)
            #expect(await aggregate.waitUntilListed(), "private aggregate device not listed by the HAL within 2 s")

            let manager = AudioManager(defaults: isolatedDefaults())   // enumerates after the aggregate exists
            let aggregateDevice = try #require(manager.inputDevices.first { $0.uid == aggregate.uid },
                                               "private aggregate device not visible in inputDevices")
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }

            try manager.selectInput(aggregateDevice)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 })

            let switchAt = ContinuousClock.now
            try manager.selectInput(blackHole)

            #expect(manager.activeInputDeviceID == blackHole.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: switchAt) > 0 },
                    "no audio on the same stream after switching to BlackHole")
            #expect(!log.finished)
            let gap = try #require(log.gapAround(switchAt))
            #expect(gap <= .milliseconds(500), "hot swap gap \(gap) exceeds 500 ms (NFR-C-01)")
        }

        @Test("hot swap to a device at another sample rate keeps the stream alive (A5b regression)")
        func hotSwapAcrossSampleRates() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            let other = try requireInputDevice(in: manager.inputDevices, rateDifferentFrom: blackHole)
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }

            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 })

            // Before the fix the engine kept the old 48 kHz client format: silence on a 16 kHz mic,
            // an installTap format-mismatch exception (crash) on a 44.1 kHz stereo one.
            let toOther = ContinuousClock.now
            try manager.selectInput(other)
            #expect(manager.activeInputDeviceID == other.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.count(since: toOther) > 0 },
                    "no buffers from \(other.name) after switching sample rate")

            let back = ContinuousClock.now
            try manager.selectInput(blackHole)
            #expect(manager.activeInputDeviceID == blackHole.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: back) > 0 },
                    "no audio from BlackHole after switching back")
            #expect(!log.finished)
        }

        @Test("hot swap between a stereo and a mono input keeps the stream alive (Important 4)")
        func hotSwapAcrossChannelCounts() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            let other = try requireInputDevice(in: manager.inputDevices, channelsDifferentFrom: blackHole)
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }

            try manager.selectInput(blackHole)
            let log = BufferLog(try await manager.startCapture())
            defer { log.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: start) > 0 })

            // The stale client format keeps BlackHole's channel count; tapping more channels than
            // the bound hardware has would raise an uncatchable installTap NSException.
            let toOther = ContinuousClock.now
            try manager.selectInput(other)
            #expect(manager.activeInputDeviceID == other.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.count(since: toOther) > 0 },
                    "no buffers from \(other.name) (\(CoreAudioDevices.inputChannelCount(of: other.id)) ch)")

            let back = ContinuousClock.now
            try manager.selectInput(blackHole)
            #expect(manager.activeInputDeviceID == blackHole.id)
            #expect(await waitUntil(timeout: .seconds(3)) { log.loudCount(since: back) > 0 },
                    "no audio from BlackHole after switching back from a mono input")
            #expect(!log.finished)
        }

        @Test("Stop → Start gives a new live stream and ends the old one")
        func stopStartGivesFreshStream() async throws {
            try await requireMicrophoneAuthorization()
            let manager = AudioManager(defaults: isolatedDefaults())
            let blackHole = try requireBlackHole(in: manager.inputDevices)
            let player = try BlackHolePlayer(fixtureURL: try fixtureURL(), deviceID: blackHole.id)
            defer { player.stop() }
            try manager.selectInput(blackHole)

            let first = BufferLog(try await manager.startCapture())
            manager.stopCapture()
            #expect(await waitUntil(timeout: .seconds(2)) { first.finished })

            let second = BufferLog(try await manager.startCapture())
            defer { second.cancel(); manager.stopCapture() }
            let start = ContinuousClock.now
            #expect(await waitUntil(timeout: .seconds(3)) { second.loudCount(since: start) > 0 })
        }
    }
}
