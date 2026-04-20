// Answers "is the user currently looking at this session's tmux pane?"
// Used to suppress the notch preview for a session when the user is
// already watching it — other-session events still fire normally.
//
// Two-layer check, both must be true:
//   1. macOS frontmost app is a known terminal emulator, AND
//   2. the given tmux pane_id is the active pane of the active window
//      of an attached client.
//
// tmux query is the cheapest ground truth we have: `tmux list-panes -a`
// returns one row per pane with flags we can filter directly, avoiding
// fan-out over `display-message` per pane_id.
import AppKit
import BlipCore
import Foundation

enum TerminalFocusDetector {
    /// Bundle IDs of terminal emulators that commonly host tmux. We only
    /// suppress when one of these is frontmost — if the user Cmd-Tabbed
    /// to Slack/Finder/etc, Terminal isn't "looked at" and events fire.
    private static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
    ]

    /// True when a known terminal app holds focus on macOS. Must run on
    /// the main actor (NSWorkspace).
    @MainActor
    static func isTerminalFrontmost() -> Bool {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return terminalBundles.contains(bundle)
    }

    /// True when `paneId` is the active pane of the active window on an
    /// attached tmux client. Safe to call from a detached Task.
    static func isPaneFocused(paneId: String) -> Bool {
        guard !paneId.isEmpty else { return false }
        let text = (try? TmuxShell.run([
            "list-panes", "-a",
            "-F", "#{pane_id} #{pane_active} #{window_active} #{session_attached}",
        ])) ?? ""
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count >= 4,
               fields[0] == Substring(paneId),
               fields[1] == "1",
               fields[2] == "1",
               fields[3] == "1" {
                return true
            }
        }
        return false
    }

    /// Composite check: both layers true → suppress notch for that
    /// session. Tmux query runs off-main so we don't block the main
    /// actor while the hook is being processed.
    @MainActor
    static func shouldSuppress(paneId: String?) async -> Bool {
        guard let paneId, !paneId.isEmpty else { return false }
        guard isTerminalFrontmost() else { return false }
        return await Task.detached(priority: .userInitiated) {
            isPaneFocused(paneId: paneId)
        }.value
    }
}
