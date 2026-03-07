import SwiftUI

@main
struct TranslateCallApp: App {
    @StateObject private var audioViewModel = AudioViewModel()

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                TranslationBridge()
            }
            .environmentObject(audioViewModel)
        }
        .windowResizability(.contentSize)
    }
}
