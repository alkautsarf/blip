// Manages the per-user LaunchAgent that keeps blip running in the
// background. Installing the agent makes blip auto-start on login and
// respawn on crash; uninstalling removes it cleanly.
//
// The plist's `ProgramArguments` points inside the `.app` bundle
// (`Blip.app/Contents/MacOS/BlipApp`), not at the raw brew binary, so
// macOS can resolve bundle identity for TCC. See `AppBundle.swift` for
// why bundle identity matters.
import Foundation

public enum LaunchAgent {
    public static let label = "com.elpabl0.blip"

    public struct Paths: Sendable {
        public let plist: URL

        public static func defaultPaths() -> Paths {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            return Paths(
                plist: home
                    .appendingPathComponent("Library/LaunchAgents")
                    .appendingPathComponent("\(label).plist")
            )
        }
    }

    public enum LaunchAgentError: Error, LocalizedError {
        case launchctlFailed(exitCode: Int32, action: String, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .launchctlFailed(let code, let action, let stderr):
                return "launchctl \(action) exited \(code): \(stderr)"
            }
        }
    }

    /// Writes the plist (pointing at `bundleBinary`), bootstraps it with
    /// launchd, and triggers the initial launch. Idempotent: if an agent
    /// is already loaded we reload it so the new plist contents take
    /// effect.
    public static func install(
        bundleBinary: URL,
        paths: Paths = .defaultPaths()
    ) throws {
        try FileManager.default.createDirectory(
            at: paths.plist.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try plistXML(bundleBinary: bundleBinary)
            .write(to: paths.plist, atomically: true, encoding: .utf8)

        // If already loaded, bootout first so the new plist is re-read.
        if isLoaded() {
            _ = try? runLaunchctl(["bootout", domainTarget()])
        }
        try runLaunchctl(["bootstrap", guiDomain(), paths.plist.path])
        // Nudge it to start now (RunAtLoad should handle this, but kickstart
        // is a harmless insurance policy for fresh bootstraps on a logged-in
        // user session).
        _ = try? runLaunchctl(["kickstart", "-k", serviceTarget()])
    }

    public static func uninstall(paths: Paths = .defaultPaths()) throws {
        if isLoaded() {
            _ = try? runLaunchctl(["bootout", domainTarget()])
        }
        if FileManager.default.fileExists(atPath: paths.plist.path) {
            try FileManager.default.removeItem(at: paths.plist)
        }
    }

    public static func isLoaded() -> Bool {
        // `launchctl print <service>` succeeds for loaded services. `list`
        // would work too but `print` has less quirky matching.
        let (code, _) = (try? captureLaunchctl(["print", serviceTarget()])) ?? (1, "")
        return code == 0
    }

    public static func kickstart() throws {
        try runLaunchctl(["kickstart", "-k", serviceTarget()])
    }

    /// Sends a POSIX signal to the running service (e.g. "SIGTERM").
    /// Use this for stop instead of `bootout` so the launch agent stays
    /// installed; only the running process exits.
    public static func signal(_ name: String) throws {
        try runLaunchctl(["kill", name, serviceTarget()])
    }

    public static func exists(paths: Paths = .defaultPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.plist.path)
    }

    // MARK: - Plist content

    private static func plistXML(bundleBinary: URL) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(bundleBinary.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
                <key>Crashed</key>
                <true/>
            </dict>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>/tmp/blip-app.log</string>
            <key>StandardErrorPath</key>
            <string>/tmp/blip-app.err</string>
        </dict>
        </plist>
        """
    }

    // MARK: - launchctl plumbing

    /// Returns the GUI domain target for the current user (e.g. `gui/501`).
    private static func guiDomain() -> String { "gui/\(getuid())" }
    private static func domainTarget() -> String { "\(guiDomain())/\(label)" }
    private static func serviceTarget() -> String { domainTarget() }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) throws -> String {
        let (code, output) = try captureLaunchctl(args)
        if code != 0 {
            throw LaunchAgentError.launchctlFailed(
                exitCode: code, action: args.first ?? "?", stderr: output
            )
        }
        return output
    }

    private static func captureLaunchctl(_ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let combined = Pipe()
        process.standardOutput = combined
        process.standardError = combined
        try process.run()
        process.waitUntilExit()
        let data = combined.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, out)
    }
}
