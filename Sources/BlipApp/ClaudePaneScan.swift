// Scans tmux + `ps` for tmux panes currently running a Claude Code CLI
// process. Joins the two by TTY:
//   ps -eo pid,tty,command   → which pids are on which TTY
//   tmux list-panes -a ...   → which tmux panes own which TTY (+ cwd)
// Intersection = panes with Claude running, including their pid.
// Entries seeded from this are keyed by "tmux:%<paneId>" until real
// hook events arrive with the actual session id.
import Foundation
import BlipCore

enum ClaudePaneScan {
    /// Distinguishes regular Claude sessions from the `claude agents`
    /// agent-view dashboard. Both run as foreground `claude` processes
    /// inside a tmux pane but the dashboard isn't a session you'd want
    /// to peek at — it's a UI watching backgrounded workers, so the
    /// overview row labels it "agents" instead of the cwd basename.
    enum Role {
        case session
        case agentView
    }

    struct Pane {
        let paneId: String
        /// OS pid of the `claude` CLI process inside this pane. Used as
        /// liveness ground truth — when the pid vanishes, the session
        /// is definitively gone regardless of whether a Stop hook fired.
        let pid: Int
        let cwd: String
        let role: Role
    }

    /// Returns one `Pane` per tmux pane where a Claude Code CLI is
    /// currently running. Safe to call from a detached Task — no main
    /// actor work here. The `claude agents` dashboard pane is filtered
    /// out: it's a control surface watching other sessions, not a
    /// session itself, and the bg sessions it manages already surface
    /// individually via the hook events they fire. Surfacing the
    /// dashboard as a row would just double-count.
    static func claudePanes() -> [Pane] {
        let claudeByTty = runningClaudeByTty()
        guard !claudeByTty.isEmpty else { return [] }
        return tmuxPanes().compactMap { p in
            guard let info = claudeByTty[p.ptyPath] else { return nil }
            if info.role == .agentView { return nil }
            return Pane(paneId: p.paneId, pid: info.pid, cwd: p.cwd, role: info.role)
        }
    }

    /// Map from `/dev/ttys…` → (pid, role) of the `claude` CLI process
    /// on that TTY. Matches both `~/.local/bin/claude …` and bare
    /// `claude …` invocations; tags `claude agents` as `.agentView`.
    private static func runningClaudeByTty() -> [String: (pid: Int, role: Role)] {
        guard let psOut = runCommand("/bin/ps", ["-eo", "pid,tty,command"]) else { return [:] }
        var result: [String: (pid: Int, role: Role)] = [:]
        var first = true
        for line in psOut.split(separator: "\n", omittingEmptySubsequences: true) {
            if first { first = false; continue }  // skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Columns: pid, tty, command (command may contain spaces).
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int(parts[0])
            else { continue }
            let tty = String(parts[1])
            let cmd = String(parts[2])
            if tty == "?" || tty.isEmpty { continue }
            guard looksLikeClaude(command: cmd) else { continue }
            result["/dev/\(tty)"] = (pid, detectRole(command: cmd))
        }
        return result
    }

    private static func looksLikeClaude(command: String) -> Bool {
        // Matches the interactive CLI binary — not SDK bun workers
        // (those have `--input-format stream-json`) or plugin children
        // (those have `--cwd .../.claude/plugins/...`), and not the
        // daemon's bg-pty-host / bg-spare wrappers (they parent the
        // actual worker process, which fires hooks via the bridge so
        // hook-driven entries cover them — surfacing the wrappers as
        // panes would just double-list).
        if command.contains("--input-format") { return false }
        if command.contains(".claude/plugins/") { return false }
        if command.contains("--bg-pty-host") { return false }
        if command.contains("--bg-spare") { return false }
        if command.contains("/.local/bin/claude") { return true }
        if command.hasPrefix("claude ") || command == "claude" { return true }
        return false
    }

    /// Inspect the cmdline's first non-flag positional after the binary
    /// path. `claude agents` has subcommand "agents"; `claude` alone or
    /// `claude --foo …` has no subcommand and represents an interactive
    /// or attached session.
    private static func detectRole(command: String) -> Role {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let binaryIdx = tokens.firstIndex(where: { $0.hasSuffix("/claude") || $0 == "claude" })
        else { return .session }
        let next = tokens.dropFirst(binaryIdx + 1).first { !$0.hasPrefix("-") }
        if next == "agents" { return .agentView }
        return .session
    }

    private struct TmuxPane {
        let paneId: String
        let ptyPath: String
        let cwd: String
    }

    private static func tmuxPanes() -> [TmuxPane] {
        let out = (try? TmuxShell.run([
            "list-panes", "-a",
            "-F", "#{pane_id}|#{pane_tty}|#{pane_current_path}",
        ])) ?? ""
        var panes: [TmuxPane] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            panes.append(TmuxPane(
                paneId: String(parts[0]),
                ptyPath: String(parts[1]),
                cwd: String(parts[2])
            ))
        }
        return panes
    }

    private static func runCommand(_ exec: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exec)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        // Drain stdout BEFORE waitUntilExit. macOS pipe buffer is ~64KB;
        // `ps -eo pid,tty,command` on a busy system easily exceeds that
        // (~83KB here with many bun plugin workers), and ps blocks on
        // write when the buffer fills, deadlocking waitUntilExit.
        // readDataToEndOfFile returns when ps closes stdout on exit,
        // draining the pipe as it goes.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
