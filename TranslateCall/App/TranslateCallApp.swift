import SwiftUI

@main
struct TranslateCallApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                TranslationBridge()
            }
            .environmentObject(container.audioViewModel)
            .environmentObject(container.translationBridgeModel)
        }
        .windowResizability(.contentSize)
    }
}
