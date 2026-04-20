// Pill shape with concave top corners (curling inward toward the
// hardware notch) and convex bottom corners (curling outward).
//
// `topRadius` and `bottomRadius` animate independently so the pill can
// morph between closed (small radii) and opened (larger radii) without
// re-laying-out the surrounding view.
import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4, rect.height / 4)
        let br = min(bottomRadius, rect.width / 4, rect.height / 2)

        var path = Path()
        // Trace clockwise starting from the top-left corner.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // 1. Concave curl into the inset left edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr, y: rect.minY + tr),
            control: CGPoint(x: rect.minX + tr, y: rect.minY)
        )

        // 2. Down the inset left side to where the bottom curve begins.
        path.addLine(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br))

        // 3. Convex bottom-left corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tr + br, y: rect.maxY),
            control: CGPoint(x: rect.minX + tr, y: rect.maxY)
        )

        // 4. Across the bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY))

        // 5. Convex bottom-right corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br),
            control: CGPoint(x: rect.maxX - tr, y: rect.maxY)
        )

        // 6. Up the inset right side.
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr))

        // 7. Concave curl out to the top-right corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tr, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

extension NotchShape {
    // Validated in Phase 1 — these match seamlessly with the M-series
    // hardware notch geometry while still reading right on synthetic pills.
    static let closedTopRadius:    CGFloat = 6
    static let closedBottomRadius: CGFloat = 20
    static let openedTopRadius:    CGFloat = 22
    static let openedBottomRadius: CGFloat = 36
}
