import SwiftUI

@main
struct TranslateCallApp: App {
    @StateObject private var container = AppContainer()
    @State private var menuBarController: MenuBarController?

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
            .onAppear {
                guard menuBarController == nil else { return }
                menuBarController = MenuBarController(viewModel: container.audioViewModel)
            }
        }
        .windowResizability(.contentSize)
    }
}
