// Side-effects BlipHooks performs in addition to forwarding the hook
// event to the long-running app:
//
//   - afplay a per-event sound, gated on ~/.claude/.sound-disabled
//   - write a tmux-statusline-friendly message to /tmp/claude-notif-msg.txt,
//     gated on ~/.claude/.notif-file-disabled
//
// These mirror the shell hooks elpabl0 used pre-blip; consolidation lets
// blip be the only command in ~/.claude/settings.json. All gating is via
// flag files so users can selectively disable any side-effect without
// reinstalling.
import Foundation

public enum HookSideEffects {

    public struct Flags: Sendable {
        public let soundDisabled: Bool
        public let notifFileDisabled: Bool
        public let blipDisabled: Bool

        public init(soundDisabled: Bool, notifFileDisabled: Bool, blipDisabled: Bool) {
            self.soundDisabled = soundDisabled
            self.notifFileDisabled = notifFileDisabled
            self.blipDisabled = blipDisabled
        }

        public static func loadFromHome() -> Flags {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return Flags(
                soundDisabled:     fileExists(home.appendingPathComponent(".claude/.sound-disabled")),
                notifFileDisabled: fileExists(home.appendingPathComponent(".claude/.notif-file-disabled")),
                blipDisabled:      fileExists(home.appendingPathComponent(".claude/.blip-disabled"))
            )
        }

        private static func fileExists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Per-event sound mapping. Files live in ~/Library/Sounds/ (the
    /// location elpabl0 already uses). Missing files are silently
    /// skipped — `afplay` complains but exits non-zero, which we ignore.
    public static func soundFile(for event: HookEventName) -> URL? {
        let library = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Sounds")
        switch event {
        case .stop:               return library.appendingPathComponent("task-finished.wav")
        case .notification:       return library.appendingPathComponent("important-notif.wav")
        case .userPromptSubmit:   return library.appendingPathComponent("user-send-message.wav")
        case .sessionStart:       return library.appendingPathComponent("session-start-short.wav")
        default:                  return nil
        }
    }

    /// Plays a sound asynchronously via afplay. Returns immediately;
    /// playback continues in the background process.
    public static func playSound(for event: HookEventName, flags: Flags = .loadFromHome()) {
        guard !flags.soundDisabled else { return }
        guard let sound = soundFile(for: event),
              FileManager.default.fileExists(atPath: sound.path) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [sound.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        // Don't wait — let it play in the background so the hook returns fast.
    }

    /// Path to the notification message file consumed by the user's
    /// tmux statusline.
    public static let notifFilePath = "/tmp/claude-notif-msg.txt"

    /// Composes the `[<repo> | w<N>] <msg>` line and writes it. Returns
    /// silently on any error so a hook never fails because of this.
    public static func writeNotifFile(
        cwd: String,
        message: String,
        tmuxWindow: String? = currentTmuxWindow(),
        flags: Flags = .loadFromHome()
    ) {
        guard !flags.notifFileDisabled else { return }
        let repo = (cwd as NSString).lastPathComponent
        var prefix = "[\(repo)"
        if let win = tmuxWindow, !win.isEmpty { prefix += " | w\(win)" }
        prefix += "]"
        let line = "\(prefix) \(message)\n"
        try? line.write(
            toFile: notifFilePath,
            atomically: true,
            encoding: .utf8
        )
    }

    /// Looks up the current tmux window index using `$TMUX_PANE` if set
    /// (Claude Code's hook process inherits the tmux env). Returns nil
    /// when the hook isn't running inside tmux.
    public static func currentTmuxWindow() -> String? {
        let env = ProcessInfo.processInfo.environment
        guard let pane = env["TMUX_PANE"], !pane.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "display-message", "-t", pane, "-p", "#I"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Trims an assistant message for the statusline. Same logic as the
    /// user's pre-blip shell hook: take the last 150 characters, drop
    /// the leading word so we don't show truncated noise.
    public static func trimForStatusline(_ message: String) -> String {
        guard !message.isEmpty else { return "" }
        let suffix = String(message.suffix(150))
        if let firstSpace = suffix.firstIndex(of: " ") {
            return String(suffix[suffix.index(after: firstSpace)...])
        }
        return suffix
    }
}
