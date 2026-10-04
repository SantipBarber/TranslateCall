import Foundation
import Synchronization
@testable import TranslateCall

/// Scripted `EdgeTransport` (design §5.1): no network. After each `connect` it pushes the next list of
/// `onConnect` events, after each SSML write the next list of `onSSML` events (the last list repeats).
/// Tests can also `push` events themselves. Closing events end the connection, as Starscream does.
final class FakeEdgeTransport: EdgeTransport, Sendable {
    private struct State {
        var continuation: AsyncStream<EdgeSocketEvent>.Continuation?
        var written: [String] = []
        var connectCount = 0
        var disconnectCount = 0
        var onConnect: [[EdgeSocketEvent]]
        var onSSML: [[EdgeSocketEvent]]
    }

    private let state: Mutex<State>

    init(onConnect: [[EdgeSocketEvent]] = [[.connected]], onSSML: [[EdgeSocketEvent]] = []) {
        state = Mutex(State(onConnect: onConnect, onSSML: onSSML))
    }

    var written: [String] { state.withLock { $0.written } }
    var ssmlCount: Int { written.filter { $0.contains("Path:ssml") }.count }
    var connectCount: Int { state.withLock { $0.connectCount } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }

    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EdgeSocketEvent.self, bufferingPolicy: .unbounded)
        let events: [EdgeSocketEvent] = state.withLock { current in
            current.continuation?.finish()
            current.continuation = continuation
            current.connectCount += 1
            return Self.next(&current.onConnect)
        }
        events.forEach(push)
        return stream
    }

    func write(string: String) {
        let events: [EdgeSocketEvent] = state.withLock { current in
            current.written.append(string)
            return string.contains("Path:ssml") ? Self.next(&current.onSSML) : []
        }
        events.forEach(push)
    }

    func disconnect() {
        let continuation: AsyncStream<EdgeSocketEvent>.Continuation? = state.withLock { current in
            current.disconnectCount += 1
            defer { current.continuation = nil }
            return current.continuation
        }
        continuation?.finish()
    }

    /// Delivers `event` on the current connection; a closing event also ends the connection.
    func push(_ event: EdgeSocketEvent) {
        let continuation: AsyncStream<EdgeSocketEvent>.Continuation? = state.withLock { current in
            defer { if event.isClosing { current.continuation = nil } }
            return current.continuation
        }
        continuation?.yield(event)
        if event.isClosing { continuation?.finish() }
    }

    /// An Edge binary audio frame: 2-byte header length, header, MP3 bytes.
    static func audioFrame(_ audio: Data) -> Data {
        let header = Data("X-RequestId:test\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n".utf8)
        var frame = Data([UInt8(header.count >> 8), UInt8(header.count & 0xFF)])
        frame.append(header)
        frame.append(audio)
        return frame
    }

    static let turnEnd = EdgeSocketEvent.text("X-RequestId:test\r\nPath:turn.end\r\n\r\n{}")

    private static func next(_ queue: inout [[EdgeSocketEvent]]) -> [EdgeSocketEvent] {
        guard let first = queue.first else { return [] }
        if queue.count > 1 { queue.removeFirst() }
        return first
    }
}

/// The committed MP3 fixture (24 kHz mono, 48 kbit/s like Edge's `audio-24khz-48kbitrate-mono-mp3`).
func edgeMP3FixtureURL() -> URL {
    URL(fileURLWithPath: #filePath)            // …/TranslateCallTests/Support/FakeEdgeTransport.swift
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MP3/hello-24k-mono.mp3")
}

func edgeMP3Fixture() throws -> Data {
    try Data(contentsOf: edgeMP3FixtureURL())
}
