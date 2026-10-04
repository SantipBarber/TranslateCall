import Foundation
import OSLog
import Starscream

nonisolated private let logger = Logger(subsystem: "com.spbarber.TranslateCall", category: "EdgeTransport")

// MARK: - EdgeSocketEvent

/// What one Edge TTS WebSocket connection reports (a Sendable mirror of Starscream's events).
nonisolated enum EdgeSocketEvent: Sendable, Equatable {
    case connected
    case text(String)
    case binary(Data)
    case disconnected(String)
    case cancelled
    case peerClosed
    case error(String)

    /// Bound of every per-connection event stream. One utterance is a few dozen frames.
    static let bufferLimit = 1_024

    /// The connection is over after this event (REQ-T-24).
    var isClosing: Bool {
        switch self {
        case .disconnected, .cancelled, .peerClosed, .error: return true
        case .connected, .text, .binary: return false
        }
    }
}

// MARK: - EdgeTransport

/// The socket under `EdgeTTSWebSocket` (REQ-T-27): Starscream in production, `FakeEdgeTransport` in tests.
nonisolated protocol EdgeTransport: AnyObject, Sendable {
    /// Opens a new connection (closing any previous one) and returns its events. The stream finishes
    /// after a closing event, or when `disconnect()` is called.
    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent>
    func write(string: String)
    func disconnect()
}

// MARK: - StarscreamTransport

/// Starscream lets us set `Origin`, which Apple's WebSocket APIs filter out.
///
/// `@unchecked Sendable`: `socket` and `bridge` are only touched under `lock`.
nonisolated final class StarscreamTransport: EdgeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var socket: WebSocket?
    private var bridge: StarscreamBridge?
    private let callbackQueue = DispatchQueue(label: "com.spbarber.TranslateCall.EdgeTTS.socket")

    func connect(request: URLRequest) -> AsyncStream<EdgeSocketEvent> {
        let (events, continuation) = AsyncStream.makeStream(
            of: EdgeSocketEvent.self, bufferingPolicy: .bufferingNewest(EdgeSocketEvent.bufferLimit)
        )
        let bridge = StarscreamBridge(continuation: continuation)
        let socket = WebSocket(request: request)
        socket.callbackQueue = callbackQueue
        socket.delegate = bridge          // weak in Starscream: `self.bridge` keeps it alive
        let previous = lock.withLock { () -> (WebSocket?, StarscreamBridge?) in
            defer {
                self.socket = socket
                self.bridge = bridge
            }
            return (self.socket, self.bridge)
        }
        previous.0?.disconnect()
        previous.1?.finish()
        socket.connect()
        return events
    }

    func write(string: String) {
        lock.withLock { socket }?.write(string: string)
    }

    func disconnect() {
        let current = lock.withLock { () -> (WebSocket?, StarscreamBridge?) in
            defer {
                socket = nil
                bridge = nil
            }
            return (socket, bridge)
        }
        current.0?.disconnect()
        current.1?.finish()
    }
}

/// Bridges Starscream's delegate callbacks into one connection's event stream.
///
/// `@unchecked Sendable`: it only holds the continuation, which is thread-safe.
nonisolated private final class StarscreamBridge: WebSocketDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<EdgeSocketEvent>.Continuation

    init(continuation: AsyncStream<EdgeSocketEvent>.Continuation) {
        self.continuation = continuation
    }

    func finish() {
        continuation.finish()
    }

    func didReceive(event: WebSocketEvent, client: any WebSocketClient) {
        switch event {
        case .connected:
            continuation.yield(.connected)
        case .disconnected(let reason, let code):
            logger.info("Edge TTS socket disconnected: \(reason, privacy: .public) (\(code))")
            end(with: .disconnected("\(reason) (\(code))"))
        case .text(let text):
            continuation.yield(.text(text))
        case .binary(let data):
            continuation.yield(.binary(data))
        case .cancelled:
            end(with: .cancelled)
        case .peerClosed:
            end(with: .peerClosed)
        case .error(let error):
            let message = error.map { String(describing: $0) } ?? "unknown error"
            logger.error("Edge TTS socket error: \(message, privacy: .public)")
            end(with: .error(message))
        case .ping, .pong, .viabilityChanged, .reconnectSuggested:
            break   // Starscream answers pings; reconnecting is EdgeUtteranceSynthesizer's job
        }
    }

    private func end(with event: EdgeSocketEvent) {
        continuation.yield(event)
        continuation.finish()
    }
}
