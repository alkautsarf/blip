// Resolves the target NSScreen for the notch panel based on the user's
// display preference (laptop / main / auto). Also exposes notch-size
// helpers used by the layout code.
import AppKit

enum DisplayTarget: Int, CaseIterable, Sendable {
    case laptop, main, auto

    var label: String {
        switch self {
        case .laptop: return "laptop (notched)"
        case .main:   return "main"
        case .auto:   return "auto"
        }
    }

    func next() -> DisplayTarget {
        let all = DisplayTarget.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

extension NSScreen {
    /// Logical size of the hardware notch (or a synthetic stand-in on
    /// non-notched displays). Width covers the full menu-bar gap so the
    /// pill blends into the cutout instead of floating beside it.
    var notchSize: CGSize {
        guard safeAreaInsets.top > 0 else {
            // Non-notched: pick the larger of the visible-frame gap and
            // NSStatusBar.thickness — visibleFrame can underreport on
            // secondaries, status bar can underreport on HiDPI.
            let visibleGap = max(0, frame.maxY - visibleFrame.maxY)
            let statusBar  = NSStatusBar.system.thickness
            return CGSize(width: 224, height: max(visibleGap, statusBar))
        }
        let leftAux  = auxiliaryTopLeftArea?.width ?? 0
        let rightAux = auxiliaryTopRightArea?.width ?? 0
        let width = frame.width - leftAux - rightAux + 4
        return CGSize(width: width, height: safeAreaInsets.top)
    }

    /// Top status-bar reserved height; falls back through measurements
    /// in case the system reports zero for some configurations.
    var topStatusBarHeight: CGFloat {
        let reserved = max(0, frame.maxY - visibleFrame.maxY)
        if reserved > 0 { return reserved }
        if safeAreaInsets.top > 0 { return safeAreaInsets.top }
        return 24
    }
}

@MainActor
enum ScreenPicker {
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
    }

    /// Returns the screen the panel should attach to plus whether that
    /// screen has a real hardware notch (controls the synthetic-pill
    /// rendering tweaks).
    static func pick(target: DisplayTarget) -> (screen: NSScreen, hasHardwareNotch: Bool)? {
        switch target {
        case .laptop:
            guard let screen = notchedScreen() else { return nil }
            return (screen, true)
        case .main:
            guard let screen = NSScreen.main else { return nil }
            return (screen, screen.safeAreaInsets.top > 0)
        case .auto:
            if let notched = notchedScreen() { return (notched, true) }
            guard let main = NSScreen.main else { return nil }
            return (main, false)
        }
    }
}
