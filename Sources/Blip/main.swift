// `blip` — unified CLI for the blip.vim notch app.
//
// Subcommands: start, stop, restart, status, install, uninstall, config,
// log, help. All shared logic (install, config, bridge) lives in
// BlipCore; this file is just argv parsing + process lifecycle.
import Foundation
import BlipCore
import Darwin

let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    Help.print(); exit(64)
}

switch command {
case "start":     Lifecycle.start()
case "stop":      Lifecycle.stop()
case "restart":   Lifecycle.restart()
case "status":    Lifecycle.status()
case "install":   Install.install()
case "uninstall": Install.uninstall()
case "config":    ConfigCmd.run(Array(args.dropFirst()))
case "log":       LogCmd.run(Array(args.dropFirst()))
case "doctor":    Doctor.run()
case "help", "-h", "--help": Help.print()
default:
    fputs("blip: unknown command '\(command)'\n", stderr)
    Help.print()
    exit(64)
}

// MARK: - Paths used by lifecycle / log commands.

enum LifecyclePaths {
    static let pidFile: URL = {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("blip/blip.pid")
    }()
    static let logFile: URL = {
        let logs = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs")
        return logs.appendingPathComponent("blip.log")
    }()
}

// MARK: - Help

enum Help {
    static func print() {
        Swift.print("""
        blip \(BlipCore.version) — macOS notch app for Claude Code

        usage: blip <command> [args]

        Lifecycle:
          start              launch the notch app in the background
          stop               kill the running notch app
          restart            stop then start
          status             show pid, socket, and install status

        Hook integration:
          install            wire the Stop hook into ~/.claude/settings.json
          uninstall          remove the hook (settings.json restored verbatim)

        Configuration (~/.config/blip/config.json):
          config show        print current config
          config get <key>   read one value
          config set <k> <v> write one value
          config reset       restore defaults

        Diagnostics:
          doctor             health checklist (hook, socket, tmux, accessibility, sounds)
          log                tail ~/Library/Logs/blip.log
          help               this message

        Valid config keys: \(BlipConfigStore.validKeys.joined(separator: ", "))
        """)
    }
}

// MARK: - Lifecycle

enum Lifecycle {
    static func start() {
        // Preferred path: LaunchAgent owns the process. If it's installed,
        // kickstart via launchd so the bundle identity is preserved and
        // crash-respawn stays wired.
        if LaunchAgent.isLoaded() {
            do {
                try LaunchAgent.kickstart()
                Swift.print("✓ blip started via launchd (\(LaunchAgent.label))")
                return
            } catch {
                fputs("warning: launchctl kickstart failed — falling back to direct spawn: \(error.localizedDescription)\n", stderr)
            }
        }

        if let runningPid = currentPid(), processAlive(pid: runningPid) {
            Swift.print("blip is already running (pid \(runningPid))")
            return
        }
        let appBinary: URL
        do {
            appBinary = try resolveSibling("BlipApp")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); exit(1)
        }

        // Open log file for append.
        do {
            try FileManager.default.createDirectory(
                at: LifecyclePaths.logFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: LifecyclePaths.logFile.path) {
                FileManager.default.createFile(atPath: LifecyclePaths.logFile.path, contents: nil)
            }
        } catch {
            fputs("warning: could not prepare log file: \(error)\n", stderr)
        }

        let process = Process()
        process.executableURL = appBinary
        // Detach: stdin from /dev/null, stdout/stderr → log file.
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        if let logHandle = try? FileHandle(forWritingTo: LifecyclePaths.logFile) {
            try? logHandle.seekToEnd()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        do {
            try process.run()
        } catch {
            fputs("error: failed to launch BlipApp: \(error)\n", stderr); exit(1)
        }

        try? FileManager.default.createDirectory(
            at: LifecyclePaths.pidFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? "\(process.processIdentifier)".write(to: LifecyclePaths.pidFile, atomically: true, encoding: .utf8)

        Swift.print("✓ blip started (pid \(process.processIdentifier))")
        Swift.print("  log: \(LifecyclePaths.logFile.path)")
    }

    static func stop() {
        // LaunchAgent-managed: SIGTERM via launchctl. With KeepAlive
        // `SuccessfulExit=false`, clean exit means no respawn — perfect
        // for an explicit `blip stop`.
        if LaunchAgent.isLoaded() {
            do {
                try LaunchAgent.signal("SIGTERM")
                Swift.print("✓ blip stopped (launchd, will stay down until `blip start`)")
                try? FileManager.default.removeItem(at: LifecyclePaths.pidFile)
                return
            } catch {
                fputs("warning: launchctl kill failed — falling back to PID kill: \(error.localizedDescription)\n", stderr)
            }
        }

        guard let pid = currentPid(), processAlive(pid: pid) else {
            Swift.print("blip is not running")
            try? FileManager.default.removeItem(at: LifecyclePaths.pidFile)
            return
        }
        kill(pid, SIGTERM)
        // Wait up to 3 seconds.
        for _ in 0..<30 {
            if !processAlive(pid: pid) { break }
            usleep(100_000)
        }
        if processAlive(pid: pid) {
            kill(pid, SIGKILL)
            Swift.print("✓ blip stopped (SIGKILL after timeout)")
        } else {
            Swift.print("✓ blip stopped")
        }
        try? FileManager.default.removeItem(at: LifecyclePaths.pidFile)
    }

    static func restart() {
        stop()
        // Tiny delay so the next start sees a clean state.
        usleep(200_000)
        start()
    }

    static func status() {
        let pid = currentPid()
        let alive = pid.map(processAlive(pid:)) ?? false
        if alive, let pid {
            Swift.print("running:    yes (pid \(pid))")
        } else {
            Swift.print("running:    no")
        }

        let socket = SocketPath.resolved()
        let socketExists = FileManager.default.fileExists(atPath: socket.path)
        Swift.print("socket:     \(socket.path) \(socketExists ? "(present)" : "(absent)")")

        let manifestPath = InstallPaths.defaultPaths().manifest
        if let manifest = Installer.readManifest(at: manifestPath) {
            Swift.print("installed:  yes")
            Swift.print("  hook:     \(manifest.hookBinaryPath)")
            Swift.print("  version:  \(manifest.version)")
        } else {
            Swift.print("installed:  no")
        }

        let config = BlipConfigStore.load()
        Swift.print("config:")
        Swift.print("  display:    \(config.display)")
        Swift.print("  socketPath: \(config.socketPath ?? "(default)")")
        Swift.print("  logLevel:   \(config.logLevel)")
    }

    // MARK: - PID + process helpers

    private static func currentPid() -> Int32? {
        guard let raw = try? String(contentsOf: LifecyclePaths.pidFile, encoding: .utf8) else {
            return nil
        }
        return Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func processAlive(pid: Int32) -> Bool {
        // kill(pid, 0) returns 0 if the process exists and we have permission.
        // ESRCH means no such process.
        kill(pid, 0) == 0
    }
}

// MARK: - Install

enum Install {
    static func install() {
        do {
            // 1. Assemble / refresh the .app bundle. Stable path +
            //    identifier is what makes the TCC grant persist across
            //    future brew upgrades. This is the step that needs to
            //    re-run on every `brew upgrade`.
            let sourceBinary = try resolveSibling("BlipApp")
            let bundlePaths = try AppBundle.refresh(from: sourceBinary)
            Swift.print("✓ bundle: \(bundlePaths.app.path)")

            // 2. Wire Claude Code hooks. Prefer the brew-stable symlink
            //    path (`/opt/homebrew/bin/BlipHooks`) over the cellar
            //    path so future `brew upgrade`s don't orphan the hook
            //    entry. Idempotent, but re-registers when the recorded
            //    path either vanished (stale cellar after brew cleanup)
            //    or no longer matches what we'd freshly resolve.
            let hookBinary = try ExecutableLookup.stableSibling(named: "BlipHooks")
            let manifestPath = InstallPaths.defaultPaths().manifest
            let existing = Installer.readManifest(at: manifestPath)
            let stale = existing.map { m in
                m.hookBinaryPath != hookBinary.path
                    || !FileManager.default.isExecutableFile(atPath: m.hookBinaryPath)
            } ?? false
            if let existing, !existing.addedHooks.isEmpty, !stale {
                Swift.print("✓ hooks:  already wired (\(existing.hookBinaryPath))")
            } else {
                if existing != nil { try? Installer.uninstall() }
                let manifest = try Installer.install(hookBinaryPath: hookBinary.path)
                Swift.print("✓ hooks:  \(manifest.hookBinaryPath)")
            }

            // 3. Install + bootstrap the LaunchAgent. LaunchAgent.install
            //    handles the "already loaded" case by bootout + reload, so
            //    re-runs always land on the current plist contents.
            try LaunchAgent.install(bundleBinary: bundlePaths.binary)
            Swift.print("✓ launchd: \(LaunchAgent.label) loaded")

            Swift.print("")
            Swift.print("blip is running. First launch triggers a one-time Accessibility")
            Swift.print("prompt — grant it once and the permission persists across every")
            Swift.print("future `brew upgrade` thanks to the stable bundle identifier.")
            Swift.print("")
            Swift.print("Restart any running `claude` sessions for the hook to pick up.")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }

    static func uninstall() {
        // Best-effort teardown — keep going through each step even if an
        // earlier one fails so we don't strand partially-cleaned state.
        var failed: [String] = []
        do {
            try LaunchAgent.uninstall()
            Swift.print("✓ launchd: unloaded")
        } catch {
            failed.append("launchd: \(error.localizedDescription)")
        }
        do {
            try Installer.uninstall()
            Swift.print("✓ hooks:   settings.json restored")
        } catch {
            failed.append("hooks: \(error.localizedDescription)")
        }
        do {
            try AppBundle.remove()
            Swift.print("✓ bundle:  ~/Applications/Blip.app removed")
        } catch {
            failed.append("bundle: \(error.localizedDescription)")
        }

        if !failed.isEmpty {
            fputs("warning: partial uninstall:\n", stderr)
            for msg in failed { fputs("  - \(msg)\n", stderr) }
            exit(1)
        }
    }
}

// MARK: - Config

enum ConfigCmd {
    static func run(_ args: [String]) {
        guard let sub = args.first else {
            fputs("usage: blip config show | get <key> | set <key> <value> | reset\n", stderr); exit(64)
        }
        switch sub {
        case "show":
            let cfg = BlipConfigStore.load()
            let path = BlipConfigStore.defaultPath()
            Swift.print("config file: \(path.path)\(FileManager.default.fileExists(atPath: path.path) ? "" : " (defaults — not yet written)")")
            let keyWidth = BlipConfigStore.validKeys.map(\.count).max() ?? 0
            for key in BlipConfigStore.validKeys {
                let v = BlipConfigStore.value(of: key, in: cfg) ?? ""
                let display = v.isEmpty ? "(default)" : v
                let padded = key.padding(toLength: keyWidth, withPad: " ", startingAt: 0)
                Swift.print("  \(padded)  \(display)")
            }

        case "get":
            guard args.count >= 2 else {
                fputs("usage: blip config get <key>\n", stderr); exit(64)
            }
            let key = args[1]
            let cfg = BlipConfigStore.load()
            if let v = BlipConfigStore.value(of: key, in: cfg) {
                Swift.print(v)
            } else {
                fputs("unknown config key: \(key) (valid: \(BlipConfigStore.validKeys.joined(separator: ", ")))\n", stderr)
                exit(1)
            }

        case "set":
            guard args.count >= 3 else {
                fputs("usage: blip config set <key> <value>\n", stderr); exit(64)
            }
            let key = args[1]
            let value = args[2]
            do {
                let updated = try BlipConfigStore.update { cfg in
                    _ = BlipConfigStore.setValue(value, for: key, in: &cfg)
                }
                if BlipConfigStore.value(of: key, in: updated) != (value.isEmpty ? "" : value)
                    && key != "socketPath" {
                    fputs("rejected: invalid value '\(value)' for key '\(key)'\n", stderr); exit(1)
                }
                Swift.print("✓ \(key) = \(value)")
                Swift.print("  (running app: restart with `blip restart` to pick up display changes)")
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr); exit(1)
            }

        case "reset":
            do {
                try BlipConfigStore.save(.default)
                Swift.print("✓ config reset to defaults")
            } catch {
                fputs("error: \(error.localizedDescription)\n", stderr); exit(1)
            }

        default:
            fputs("unknown subcommand: config \(sub)\n", stderr); exit(64)
        }
    }
}

// MARK: - Log tail

enum LogCmd {
    static func run(_ args: [String]) {
        let path = LifecyclePaths.logFile.path
        guard FileManager.default.fileExists(atPath: path) else {
            Swift.print("log file does not exist yet: \(path)")
            return
        }
        // Just exec `tail -f`; signals propagate cleanly that way.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-f", path]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr); exit(1)
        }
    }
}

// MARK: - Sibling-binary resolution

enum BlipCLIError: Error, LocalizedError {
    case siblingMissing(String)

    var errorDescription: String? {
        switch self {
        case .siblingMissing(let p): return "binary not found at \(p) — did you run `swift build -c release`?"
        }
    }
}

func resolveSibling(_ name: String) throws -> URL {
    try ExecutableLookup.sibling(named: name)
}
