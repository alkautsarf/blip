// `blip doctor` — health checklist printed on demand. Read-only,
// deliberately verbose, and ordered from "most likely to break" to
// "almost never an issue" so the relevant signal is on top.
import Foundation
import BlipCore
import AppKit
import Darwin

enum Doctor {
    static func run() {
        print("blip doctor — \(BlipCore.version)\n")

        check("App is running", checkAppRunning)
        check("Socket exists", checkSocket)
        check("Hook installed in settings.json", checkInstalled)
        check("Bridge is reachable", checkBridge)
        check("tmux is running", checkTmux)
        check("Accessibility permission granted", checkAccessibility)
        check("Sound files present", checkSoundFiles)
        check("Flag files", checkFlagFiles)
        check("Config file", checkConfig)

        print("\nIf any check failed, see https://github.com/alkautsarf/blip#troubleshooting")
    }

    // MARK: - Result printing

    private struct Result {
        let ok: Bool
        let detail: String
    }

    private static func check(_ name: String, _ fn: () -> Result) {
        let r = fn()
        let icon = r.ok ? "✓" : "✗"
        print("  \(icon) \(name)")
        if !r.detail.isEmpty {
            for line in r.detail.split(separator: "\n") {
                print("      \(line)")
            }
        }
    }

    // MARK: - Checks

    private static func checkAppRunning() -> Result {
        // Prefer launchd's own view when the agent is loaded; fall back
        // to the pid file for direct-spawn flows.
        if let pid = LaunchAgent.runningPid(), kill(pid, 0) == 0 {
            return Result(ok: true, detail: "pid \(pid) (launchd)")
        }
        if let raw = try? String(contentsOf: LifecyclePaths.pidFile, encoding: .utf8),
           let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           kill(pid, 0) == 0 {
            return Result(ok: true, detail: "pid \(pid)")
        }
        return Result(ok: false, detail: "no live BlipApp pid — run `blip start`")
    }

    private static func checkSocket() -> Result {
        let path = SocketPath.resolved()
        if FileManager.default.fileExists(atPath: path.path) {
            return Result(ok: true, detail: path.path)
        }
        return Result(ok: false, detail: "missing: \(path.path)")
    }

    private static func checkInstalled() -> Result {
        let manifestPath = InstallPaths.defaultPaths().manifest
        guard let manifest = Installer.readManifest(at: manifestPath) else {
            return Result(ok: false, detail: "no manifest — run `blip install`")
        }
        let events = manifest.addedHooks.map(\.event).joined(separator: ", ")
        return Result(ok: true, detail: "events: \(events)\nhook: \(manifest.hookBinaryPath)")
    }

    private static func checkBridge() -> Result {
        // Try to send an empty hello envelope. If the app is running and
        // reachable, the connection succeeds even though we discard the
        // result. Don't actually wait for a response.
        let socket = SocketPath.resolved()
        let envelope = BridgeEnvelope(kind: .hello)
        do {
            try BridgeClient.send(envelope, to: socket, timeout: 1.0)
            return Result(ok: true, detail: "")
        } catch {
            return Result(ok: false, detail: error.localizedDescription)
        }
    }

    private static func checkTmux() -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "info"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return Result(ok: true, detail: "")
            }
        } catch {}
        return Result(ok: false, detail: "tmux not running — jump-to-tmux won't work until you start one")
    }

    private static func checkAccessibility() -> Result {
        // Read-only check (no prompt).
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: false] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            return Result(ok: true, detail: "")
        }
        return Result(
            ok: false,
            detail: "global hotkeys won't fire until granted in System Settings → Privacy & Security → Accessibility"
        )
    }

    private static func checkSoundFiles() -> Result {
        let library = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Sounds")
        let names = [
            "task-finished.wav",
            "important-notif.wav",
            "user-send-message.wav",
            "session-start-short.wav",
        ]
        let missing = names.filter { name in
            !FileManager.default.fileExists(atPath: library.appendingPathComponent(name).path)
        }
        if missing.isEmpty {
            return Result(ok: true, detail: "all 4 in \(library.path)")
        }
        return Result(
            ok: false,
            detail: "missing \(missing.count): \(missing.joined(separator: ", "))\nsounds will silently no-op for those events"
        )
    }

    private static func checkFlagFiles() -> Result {
        let flags = HookSideEffects.Flags.loadFromHome()
        var present: [String] = []
        if flags.soundDisabled     { present.append(".sound-disabled") }
        if flags.notifFileDisabled { present.append(".notif-file-disabled") }
        if flags.blipDisabled      { present.append(".blip-disabled") }
        if present.isEmpty {
            return Result(ok: true, detail: "none set (all subsystems enabled)")
        }
        return Result(ok: true, detail: "active: \(present.joined(separator: ", "))")
    }

    private static func checkConfig() -> Result {
        let path = BlipConfigStore.defaultPath()
        let cfg = BlipConfigStore.load()
        let exists = FileManager.default.fileExists(atPath: path.path)
        let detail = "display=\(cfg.display), logLevel=\(cfg.logLevel)" + (exists ? "" : " (defaults — file not yet written)")
        return Result(ok: true, detail: detail)
    }
}
