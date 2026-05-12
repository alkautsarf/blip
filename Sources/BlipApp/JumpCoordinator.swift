// Translates "jump to the originating tmux pane" into a tmux
// switch-client invocation, then brings the host terminal app to the
// foreground so the user can immediately start typing without an
// app-switch chord.
import AppKit
import Foundation
import BlipCore

@MainActor
final class JumpCoordinator {
    private let model: AppModel

    /// Bundle IDs of terminals likely to host a tmux session, in
    /// preferred-order. The first one that's currently running gets
    /// activated after the tmux switch.
    private static let terminalBundleIds = [
        "com.mitchellh.ghostty",     // Ghostty
        "com.googlecode.iterm2",     // iTerm2
        "io.alacritty",              // Alacritty
        "net.kovidgoyal.kitty",      // kitty
        "com.apple.Terminal",        // Apple Terminal
        "dev.warp.Warp-Stable",      // Warp
    ]

    init(model: AppModel) { self.model = model }

    /// Switches the tmux client to the originating pane AND brings the
    /// host terminal app to the foreground. Routes by the focused
    /// entry's shape, applied uniformly across `.sessions`,
    /// `.preview`, `.stack`, and the other passive surfaces:
    ///   - tmux-anchored entry (`tmuxPane` set): switch via pane id.
    ///   - bg entry (no `tmuxPane`, id is a session UUID): open a
    ///     fresh tmux window running `claude attach <short>` and
    ///     switch to it. Otherwise the cwd fallback below would match
    ///     an unrelated interactive pane that happens to share the
    ///     bg session's cwd.
    ///   - cwd fallback: last resort when no entry is resolved or the
    ///     entry-based routes can't reach a usable target.
    func jumpToOriginating() {
        if let entry = model.currentJumpEntry() {
            if let paneId = entry.tmuxPane {
                if (try? TmuxTargeter.jump(paneId: paneId)) == true {
                    activateTerminal()
                    model.dismiss()
                    return
                }
            } else if !entry.id.hasPrefix("tmux:"), entry.id.contains("-") {
                let short = String(entry.id.prefix(8))
                do {
                    _ = try TmuxTargeter.attachBackground(shortId: short)
                    activateTerminal()
                    model.dismiss()
                    return
                } catch {
                    FileHandle.standardError.write(
                        Data("[blip] jump: bg attach failed for \(short): \(error); falling back to cwd\n".utf8)
                    )
                }
            }
        }
        let cwd: String?
        switch model.state {
        case .stack:    cwd = model.focusedStackCwd ?? model.lastCwd
        case .sessions: cwd = model.focusedSessionCwd ?? model.lastCwd
        default:        cwd = model.lastCwd
        }
        guard let cwd else {
            FileHandle.standardError.write(Data("[blip] jump: no cwd recorded yet\n".utf8))
            return
        }
        do {
            let jumped = try TmuxTargeter.jump(cwd: cwd)
            if jumped {
                activateTerminal()
                model.dismiss()
            } else {
                FileHandle.standardError.write(
                    Data("[blip] jump: no tmux pane matches cwd=\(cwd)\n".utf8)
                )
            }
        } catch {
            FileHandle.standardError.write(
                Data("[blip] jump: tmux failed — \(error)\n".utf8)
            )
        }
    }

    /// Brings the most-recently-used running terminal app forward.
    /// `tmux switch-client` only changes which session/window/pane the
    /// tmux client points at — it doesn't change OS-level focus.
    private func activateTerminal() {
        let running = NSWorkspace.shared.runningApplications
        for bundleId in Self.terminalBundleIds {
            if let app = running.first(where: { $0.bundleIdentifier == bundleId }) {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
        FileHandle.standardError.write(
            Data("[blip] jump: no known terminal running — focus stays put\n".utf8)
        )
    }
}
