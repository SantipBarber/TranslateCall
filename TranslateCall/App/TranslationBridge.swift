import SwiftUI

/// Invisible view that keeps the Apple Translation framework alive in the SwiftUI hierarchy.
/// Required by PoC1: the Translation framework needs a `.translationTask()` modifier
/// attached to a view that is part of the active window.
/// Full wiring (language session, request/response) happens in F2.x.
struct TranslationBridge: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
    }
}
