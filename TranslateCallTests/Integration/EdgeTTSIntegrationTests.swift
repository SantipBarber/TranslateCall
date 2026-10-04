import AVFoundation
import Foundation
import Testing
@testable import TranslateCall

extension IntegrationTests {
    @Suite("Edge TTS (network)", .serialized)
    struct EdgeTTSIntegrationTests {

        /// Any HTTP answer from the Edge host means the network path is there.
        private func requireEdgeNetwork() async throws {
            var request = URLRequest(url: URL(string: "https://\(EdgeTTSConstants.host)/")!, timeoutInterval: 5)
            request.httpMethod = "HEAD"
            let reachable = (try? await URLSession.shared.data(for: request)) != nil
            try requirePrerequisite(reachable, "network access to Edge TTS (speech.platform.bing.com)")
        }

        @Test("Edge \"hello\" (en-US) yields PCM within 10 s (A11)")
        func hello() async throws {
            try await requireEdgeNetwork()
            let edge = EdgeUtteranceSynthesizer()
            defer { Task { await edge.shutdown() } }
            let buffers = try #require(try await collect(edge.synthesize(text: "hello", locale: english),
                                                         within: .seconds(10)),
                                       "no audio from Edge within 10 s")
            #expect(buffers.reduce(0) { $0 + Int($1.frameLength) } > 0)
        }
    }
}
