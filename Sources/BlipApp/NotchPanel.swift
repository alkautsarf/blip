// AppKit panel and controller. The panel is sized once to its maximum
// expected dimensions; the SwiftUI view morphs inside without resizing
// the window itself, which keeps the Mission Control / Spaces behavior
// stable across state transitions.
import AppKit
import SwiftUI

@MainActor
final class NotchPanel: NSPanel {
    init(contentRect: NSRect, hosting: NSView) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        contentView = hosting
        isReleasedWhenClosed = false
    }

    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    let panel: NotchPanel
    let model: AppModel
    private let hosting: NSHostingView<AnyView>

    init(model: AppModel) {
        self.model = model
        let root = AnyView(NotchView(model: model).environment(\.colorScheme, .dark))
        self.hosting = NSHostingView(rootView: root)

        let rect = NSRect(x: 0, y: 0, width: 900, height: 300)
        self.panel = NotchPanel(contentRect: rect, hosting: hosting)
        hosting.frame = rect
    }

    /// Snaps the panel to the requested display. Logs geometry so we can
    /// debug positioning issues by tailing stderr.
    func reposition(target: DisplayTarget) {
        guard let pick = ScreenPicker.pick(target: target) else {
            panel.orderOut(nil)
            return
        }
        model.notchSize = pick.screen.notchSize
        model.hasHardwareNotch = pick.hasHardwareNotch
        model.screen = pick.screen

        logGeometry(screen: pick.screen, notchSize: pick.screen.notchSize, hasHardwareNotch: pick.hasHardwareNotch)

        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: pick.screen.frame.midX - panelSize.width / 2,
            y: pick.screen.frame.maxY - panelSize.height
        )
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    private func logGeometry(screen: NSScreen, notchSize: CGSize, hasHardwareNotch: Bool) {
        let gap = screen.frame.maxY - screen.visibleFrame.maxY
        let msg = "[blip.geom] screen=\(Int(screen.frame.width))x\(Int(screen.frame.height)) " +
            "safeAreaTop=\(screen.safeAreaInsets.top) visibleFrameGap=\(gap) " +
            "statusThickness=\(NSStatusBar.system.thickness) " +
            "→ notchSize=\(notchSize) hardwareNotch=\(hasHardwareNotch)\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }
}
