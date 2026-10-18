import Foundation

/// The models line under the languages (M9 UI settings REQ-ST-05, 40, P12).
enum ModelsLabel {
    /// "Models: Recommended" / "Models: Custom", plus " · Cloud" when Edge will speak.
    static func text(hasChoice: Bool, usesCloud: Bool) -> String {
        switch (hasChoice, usesCloud) {
        case (false, false): String(localized: "Models: Recommended")
        case (true, false): String(localized: "Models: Custom")
        case (false, true): String(localized: "Models: Recommended · Cloud")
        case (true, true): String(localized: "Models: Custom · Cloud")
        }
    }
}
