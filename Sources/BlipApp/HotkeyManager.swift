// Wraps NSEvent monitors so the rest of the app can subscribe to global
// chord presses without touching AppKit directly. `start()` requires
// Accessibility permission for global monitoring; `localMonitor` always
// works while the app has focus.
import AppKit

@MainActor
final class HotkeyManager {
    typealias GlobalHandler = (NSEvent) -> Void
    typealias LocalHandler  = (NSEvent) -> Bool

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private let onGlobal: GlobalHandler
    private let onLocal: LocalHandler

    init(onGlobal: @escaping GlobalHandler, onLocal: @escaping LocalHandler) {
        self.onGlobal = onGlobal
        self.onLocal = onLocal
    }

    /// Begins listening. Global monitor only fires for ⌃⌥ chords (with or
    /// without ⇧) — anything else is dropped at the system level so we
    /// don't churn on every keystroke the user types.
    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCtrlOpt = mods.contains(.control) && mods.contains(.option)
            guard isCtrlOpt else { return }
            self.onGlobal(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.onLocal(event) ? nil : event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor  { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor  = nil
    }

    /// Prompts for Accessibility permission if not granted. Returns the
    /// current trust state regardless of prompting.
    static func accessibilityTrusted(prompt: Bool = true) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
