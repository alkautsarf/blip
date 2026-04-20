// Color tokens that shift with state — the pet glyph and badges pick
// their tint from here so semantic state mappings live in one place.
import SwiftUI

enum ScoutTint {
    static let running   = Color(red: 0.43, green: 0.62, blue: 1.0)   // working blue
    static let idle      = Color(red: 0.26, green: 0.91, blue: 0.42)  // idle green
    static let inactive  = Color.white.opacity(0.4)
    // Picker input = same green as the selected-option highlight. No
    // orange anywhere in the palette — the picker UI itself is the
    // "needs input" signal.
    static let inputGreen = Color(red: 0.45, green: 0.95, blue: 0.62)

    static func forState(_ state: ShapeState) -> Color {
        switch state {
        case .dormant, .sleep: return inactive
        case .working, .peek:  return running
        case .question:        return inputGreen
        default:               return idle
        }
    }
}
