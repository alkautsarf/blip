// Layout constants — pill widths, paddings, shadow insets. These numbers
// were validated in the Phase 1 prototype against real notched and
// synthetic displays. They are functional measurements, not creative
// expression.
import CoreGraphics

enum ChromeMetrics {
    // Drop-shadow breathing room around the card.
    static let openedShadowHorizontalInset: CGFloat = 18
    static let openedShadowBottomInset:     CGFloat = 22
    static let closedShadowHorizontalInset: CGFloat = 12
    static let closedShadowBottomInset:     CGFloat = 14

    // Closed-pill micro-tweaks.
    static let closedHoverScale:            CGFloat = 1.045
    static let closedIdleEdgeHeight:        CGFloat = 4

    // Opened panel sizing — narrow by default because we share the
    // menu bar with system status items on non-notched setups.
    static let minimumOpenedPanelWidth:     CGFloat = 500
    static let maximumOpenedPanelWidth:     CGFloat = 580
    static let openedPanelWidthFactor:      CGFloat = 0.34
    static let openedContentWidthPadding:   CGFloat = 28
    static let openedContentBottomPadding:  CGFloat = 0
    static let openedEmptyStateHeight:      CGFloat = 108

    // Outer paddings.
    static let outerHorizontalPadding:      CGFloat = 14
    static let outerBottomPadding:          CGFloat = 14
}
