// Resolves a Claude Code session's filesystem cwd to a tmux pane target,
// then optionally hops to it via `tmux switch-client`.
//
// Match priority (matches elpabl0's tmux conventions: panes set @cwd, and
// project windows are named `c:<repo>`):
//   1. Pane whose `@cwd` equals the hook event cwd exactly.
//   2. If multiple from (1), prefer the one whose window name is
//      `c:<basename cwd>` so multi-pane windows in the same repo resolve
//      deterministically.
//   3. If (1) finds nothing, fall back to window-name match (`c:<basename>`).
//   4. Otherwise return nil — caller should disable the jump hotkey and
//      surface a subtle "no pane" indicator in the notch.
import Foundation

public struct TmuxPane: Equatable, Sendable {
    public let session: String
    public let window: Int
    public let pane: Int
    public let cwd: String?
    public let windowName: String

    public var target: String { "\(session):\(window).\(pane)" }

    public init(session: String, window: Int, pane: Int, cwd: String?, windowName: String) {
        self.session = session
        self.window = window
        self.pane = pane
        self.cwd = cwd
        self.windowName = windowName
    }
}

public protocol TmuxClient: Sendable {
    func listPanes() throws -> [TmuxPane]
    func switchClient(to target: String) throws
}

public enum TmuxTargeter {
    public static func locate(cwd: String, using client: TmuxClient = DefaultTmuxClient()) throws -> TmuxPane? {
        let panes = try client.listPanes()
        let basename = (cwd as NSString).lastPathComponent
        let projectWindowName = "c:\(basename)"

        let cwdMatches = panes.filter { $0.cwd == cwd }
        if !cwdMatches.isEmpty {
            // Tiebreak on the project-naming convention.
            return cwdMatches.first(where: { $0.windowName == projectWindowName }) ?? cwdMatches.first
        }
        return panes.first(where: { $0.windowName == projectWindowName })
    }

    public static func jump(cwd: String, using client: TmuxClient = DefaultTmuxClient()) throws -> Bool {
        guard let pane = try locate(cwd: cwd, using: client) else { return false }
        try client.switchClient(to: pane.target)
        return true
    }
}

// MARK: - Default tmux invocation

public struct DefaultTmuxClient: TmuxClient {
    public init() {}

    public func listPanes() throws -> [TmuxPane] {
        let format = "#{session_name}:#{window_index}.#{pane_index}|#{@cwd}|#{window_name}"
        let output = try TmuxShell.run(["list-panes", "-a", "-F", format])
        return TmuxOutputParser.parsePaneList(output)
    }

    public func switchClient(to target: String) throws {
        _ = try TmuxShell.run(["switch-client", "-t", target])
    }
}

// MARK: - Shell-out + parsing (kept separate so tests can mock either layer)

public enum TmuxShell {
    public static func run(_ args: [String]) throws -> String {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["tmux"] + args

        // launchd spawns us with a bare PATH (/usr/bin:/bin:/usr/sbin:/sbin)
        // and tmux lives under /opt/homebrew/bin (Apple Silicon) or
        // /usr/local/bin (Intel). Prepend both so `env tmux` resolves
        // regardless of whether we were started by launchctl or a shell.
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + existing
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain stdout before waitUntilExit to avoid the pipe-buffer
        // deadlock: `tmux list-panes -a` on a heavily-populated server
        // can exceed the 64KB pipe buffer, at which point tmux blocks
        // on write and waitUntilExit never returns.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "(no stderr)"
            throw BridgeError.sendFailed("tmux \(args.joined(separator: " ")) failed: \(errMsg)")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

public enum TmuxOutputParser {
    public static func parsePaneList(_ output: String) -> [TmuxPane] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            parseLine(String(line))
        }
    }

    static func parseLine(_ line: String) -> TmuxPane? {
        let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let target = parts[0]
        let cwdRaw = parts[1]
        let windowName = parts[2]

        let targetParts = target.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard targetParts.count == 2 else { return nil }
        let session = targetParts[0]
        let windowPane = targetParts[1].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard windowPane.count == 2,
              let window = Int(windowPane[0]),
              let pane = Int(windowPane[1]) else { return nil }

        let cwd = cwdRaw.isEmpty ? nil : cwdRaw
        return TmuxPane(session: session, window: window, pane: pane, cwd: cwd, windowName: windowName)
    }
}
