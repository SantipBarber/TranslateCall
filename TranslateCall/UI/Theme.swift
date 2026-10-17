//  Prototype variable mapping (design/translatecall.pen)
//  -----------------------------------------------------
//  light / dark values are stand-ins; runtime uses semantic/system colours.
//
//  window-bg      #F2F2F4 / #1F1F21   → NSColor.windowBackgroundColor
//  group-bg       #FFFFFF / #2B2B2E   → NSColor.controlBackgroundColor
//  separator      #E3E3E6 / #3A3A3D   → NSColor.separatorColor
//  text-primary   #1D1D1F / #F5F5F7   → .primary
//  text-secondary #6E6E73 / #A1A1A6   → .secondary
//  text-tertiary  #8E8E93 / #8A8A8F   → .tertiary
//  accent         #0A66FF / #3D8BFF   → Color.accentColor
//  accent-soft    #E8F0FF / #1C2C4A   → Theme.soft(accent)
//  on-accent      #FFFFFF             → white text on accent buttons
//  green          #28A745 / #32D74B   → Theme.Status.green (.green)
//  green-soft     #E6F6EA / #16301D   → Theme.soft(.green)
//  orange         #C96A00 / #FF9F0A   → Theme.Status.orange (.orange)
//  purple         #7A4DDB / #BF8BFF   → Theme.Status.purple (.purple) — voice
//  purple-soft    #F0EAFC / #2E2242   → Theme.soft(.purple)
//  info blue chip (prototype accent blue for "Speaking"/"Translating…")
//                 #0A66FF / #3D8BFF   → Theme.Status.info (.blue)
//  control-bg     #EDEDF0 / #3A3A3D   → grey chip background → Theme.soft(.gray)
//  panel-bg       #F7F7F9E8 / #1C1C1EE6 → status panel material (NSVisualEffectView, StatusPanel)
//  panel-stroke   #FFFFFF99 / #FFFFFF1F → panel hairline → separator
//  font           Inter               → system font

import SwiftUI

enum Theme {
    static let accent = Color.accentColor

    enum Status {
        static let green = Color.green
        static let orange = Color.orange
        static let red = Color.red
        static let purple = Color.purple
        static let info = Color.blue
        static let neutral = Color.gray
    }

    static func soft(_ color: Color) -> Color {
        color.opacity(0.15)
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 12
    }

    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
    }
}
