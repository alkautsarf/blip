// Detects fullscreen windows on the notch's target display so the panel
// can hide itself. The panel normally floats above fullscreen apps (via
// `.fullScreenAuxiliary`); this explicitly orderOuts it when another
// app goes fullscreen on the SAME display, keeping other displays free.
//
// Detection uses `CGWindowListCopyWindowInfo` to find layer-0 windows
// whose bounds cover the target screen frame. Re-evaluated on every
// `activeSpaceDidChange` notification plus a cheap 2s poll for apps
// that transition without a space change.
import AppKit

@MainActor
final class FullscreenMonitor {
    typealias Handler = (Bool) -> Void

    private(set) var targetScreen: NSScreen?
    private var spaceObserver: NSObjectProtocol?
    private var timer: Timer?
    private let handler: Handler
    private var isFullscreen = false

    init(handler: @escaping Handler) {
        self.handler = handler
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    deinit {
        if let obs = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        timer?.invalidate()
    }

    func setTarget(_ screen: NSScreen?) {
        targetScreen = screen
        evaluate()
    }

    private func evaluate() {
        guard let screen = targetScreen else {
            deliver(false)
            return
        }
        deliver(Self.hasFullscreenWindow(on: screen))
    }

    private func deliver(_ value: Bool) {
        guard value != isFullscreen else { return }
        isFullscreen = value
        handler(value)
    }

    /// Returns true if any non-blip app has a layer-0 window whose bounds
    /// cover the given screen. Fullscreen apps on macOS always produce
    /// such a window in their dedicated space.
    private static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        let ourPid = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // CGWindow bounds use top-left origin with Y=0 at the primary display's top.
        // Convert the target screen's frame into that coordinate space so we can
        // compare bounds directly.
        guard let primary = NSScreen.screens.first else { return false }
        let primaryHeight = primary.frame.height
        let screenCG = CGRect(
            x: screen.frame.origin.x,
            y: primaryHeight - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ourPid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            if abs(bounds.width  - screenCG.width)  < 2 &&
               abs(bounds.height - screenCG.height) < 2 &&
               abs(bounds.origin.x - screenCG.origin.x) < 2 &&
               abs(bounds.origin.y - screenCG.origin.y) < 2 {
                return true
            }
        }
        return false
    }
}
