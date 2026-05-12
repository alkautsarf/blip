// blip.vim — macOS notch app for terminal-native Claude Code users.
// Entry point: bootstraps the panel, hotkeys, bridge listener, and
// screen-config observers, then runs the AppKit event loop.
import AppKit
import SwiftUI
import BlipCore

@MainActor
final class BlipAppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var controller: NotchPanelController!
    private var hotkeys: HotkeyManager!
    private var router: HotkeyRouter!
    private var listener: BridgeListener!
    private var jump: JumpCoordinator!
    private var menuBar: MenuBarController!
    private var paneScanTimer: Timer?

    private func reconcileSessions() {
        let registry = model.sessions
        Task.detached(priority: .utility) {
            let panes = ClaudePaneScan.claudePanes().map { p -> SessionRegistry.ScannedPane in
                let displayTag: String? = p.role == .agentView ? "agents" : nil
                return SessionRegistry.ScannedPane(
                    paneId: p.paneId,
                    pid: p.pid,
                    cwd: p.cwd,
                    displayTag: displayTag
                )
            }
            // `claude agents` (CC 2.1.139+) background sessions don't
            // live in tmux, so they never show up in `panes`. Pull the
            // supervisor state so the registry can tell which hook-only
            // entries are still backed by a live worker, and so it has
            // each session's display name on hand for disambiguating
            // panes that share a cwd.
            let daemonState = SessionRegistry.loadDaemonState()
            await MainActor.run {
                registry.reconcileFromScan(panes, daemonState: daemonState)
                registry.recomputeActivity()
            }
        }
    }

    private var displayTarget: DisplayTarget {
        get {
            // Priority: UserDefaults override (set via ⌃⌥⇧ D at runtime) >
            // config file value > default `.main`. UserDefaults wins so
            // the runtime hotkey toggle persists across restarts.
            if UserDefaults.standard.object(forKey: Self.displayKey) != nil {
                let raw = UserDefaults.standard.integer(forKey: Self.displayKey)
                return DisplayTarget(rawValue: raw) ?? .main
            }
            return Self.parseDisplay(BlipConfigStore.load().display)
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.displayKey)
            model.displayTarget = newValue
            controller.reposition(target: newValue)
            print("[blip] display target → \(newValue.label)")
        }
    }

    private static let displayKey = "blip.displayTarget"

    private static func parseDisplay(_ raw: String) -> DisplayTarget {
        switch raw.lowercased() {
        case "laptop": return .laptop
        case "auto":   return .auto
        default:       return .main
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        controller = NotchPanelController(model: model)
        model.displayTarget = displayTarget
        controller.reposition(target: displayTarget)

        let trusted = HotkeyManager.accessibilityTrusted(prompt: true)
        if !trusted {
            print("[blip] Accessibility NOT granted — global hotkeys won't fire until granted.")
            print("[blip] System Settings → Privacy & Security → Accessibility, then relaunch.")
        }

        jump = JumpCoordinator(model: model)
        router = HotkeyRouter(
            model: model,
            onCycleDisplay: { [weak self] in
                guard let self else { return }
                self.displayTarget = self.displayTarget.next()
            },
            onJumpToTmux: { [weak self] in
                self?.jump.jumpToOriginating()
            }
        )

        hotkeys = HotkeyManager(
            onGlobal: { [weak self] event in
                MainActor.assumeIsolated { self?.router.handleGlobal(event) }
            },
            onLocal: { [weak self] event in
                MainActor.assumeIsolated { self?.router.handleLocal(event) ?? false }
            }
        )
        hotkeys.start()

        listener = BridgeListener(model: model)
        do {
            try listener.start()
        } catch {
            FileHandle.standardError.write(
                Data("[blip] bridge failed to start: \(error)\n".utf8)
            )
        }

        // PID + filesystem session reconcile: scans tmux+ps for live
        // panes, reconciles registry, then stats each transcript file
        // to recompute activeIds. Gives us OS-level ground truth so
        // the pet reflects reality even when hooks get dropped.
        // Ticks every 3s to match the transcript-active window.
        reconcileSessions()
        paneScanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcileSessions() }
        }

        // Menu-bar item is opt-in (blip config set menuBarEnabled true).
        if BlipConfigStore.load().menuBarEnabled {
            menuBar = MenuBarController(
                model: model,
                onCycleDisplay: { [weak self] in
                    guard let self else { return }
                    self.displayTarget = self.displayTarget.next()
                },
                onSelectDisplay: { [weak self] target in
                    self?.displayTarget = target
                }
            )
        }

        observeScreenChanges()
        observeWake()
        printHotkeyHelp()
    }

    func applicationWillTerminate(_ notification: Notification) {
        listener?.stop()
        hotkeys?.stop()
        paneScanTimer?.invalidate()
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.reposition(target: self.displayTarget)
                print("[blip] screen params changed — reposition")
            }
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.controller.reposition(target: self.displayTarget)
                print("[blip] woke from sleep — reposition")
            }
        }
    }

    private func printHotkeyHelp() {
        print("""
        [blip \(BlipCore.version)] running. target = \(displayTarget.label)

        Global hotkeys (require Accessibility permission):
          ⌃⌥ Space     — expand / collapse (state-aware)
          ⌃⌥ Enter     — jump to tmux pane / confirm pick (state-aware)
          ⌃⌥ X         — dismiss (close notch); ⌃⌥ Esc also works
          ⌃⌥ L         — toggle sessions overview
          ⌃⌥ 1..8      — pick option / jump to state (in dev)
          ⌃⌥ J / K     — focus ring
          ⌃⌥⇧ D        — cycle display target
          (⌃⌥⇧ Enter is unbound — left for Rectangle Maximize)

        Bridge socket: \(SocketPath.resolved().path)
        """)
    }
}

// Entry point. NSApplication is main-actor bound so we wrap startup in
// MainActor.assumeIsolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = BlipAppDelegate()
    app.delegate = delegate
    app.run()
}
