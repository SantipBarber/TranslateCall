import SwiftUI

@main
struct TranslateCallApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                TranslationBridge(model: container.outgoingBridgeModel)
                TranslationBridge(model: container.incomingBridgeModel)
            }
            .environmentObject(container.audioViewModel)
            .environmentObject(container.languagePairManager)
            .environmentObject(container.setupManager)
        }
        .windowResizability(.contentSize)
    }
}
