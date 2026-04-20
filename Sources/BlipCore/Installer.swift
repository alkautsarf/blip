// Installs/uninstalls the blip hook entries in ~/.claude/settings.json.
// Phase 3 install consolidates the user's pre-existing sound + notif
// pipeline so blip is the only command per Claude Code event.
//
// Replaceable hooks (identified heuristically and absorbed by blip):
//   - Plays a system sound (`afplay`) gated on `~/.claude/.sound-disabled`
//   - Writes the tmux statusline file `/tmp/claude-notif-msg.txt`
//
// Non-replaceable hooks (left alone — these are user-specific routing
// rules like BROWSER/TEAM detection):
//   - Anything else (custom additionalContext, lint runners, etc.)
//
// Manifest tracks both removed and added hook groups so uninstall can
// restore the original settings.json byte-for-byte.
import Foundation

public struct InstallPaths: Sendable {
    public let settings: URL
    public let manifest: URL

    public init(settings: URL, manifest: URL) {
        self.settings = settings
        self.manifest = manifest
    }

    public static func defaultPaths() -> InstallPaths {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return InstallPaths(
            settings: home.appendingPathComponent(".claude/settings.json"),
            manifest: home.appendingPathComponent(".claude/blip-install-manifest.json")
        )
    }

    public static func under(home: URL) -> InstallPaths {
        InstallPaths(
            settings: home.appendingPathComponent(".claude/settings.json"),
            manifest: home.appendingPathComponent(".claude/blip-install-manifest.json")
        )
    }
}

public struct InstallManifest: Codable, Equatable, Sendable {
    public var version: String
    public var installedAt: Date
    public var hookBinaryPath: String
    /// Hook groups blip added — removed verbatim on uninstall.
    public var addedHooks: [HookEntry]
    /// Hook groups blip absorbed (sound + notif file) — restored verbatim.
    public var removedHooks: [HookEntry]

    public struct HookEntry: Codable, Equatable, Sendable {
        public var event: String
        public var group: HookGroup

        public struct HookGroup: Codable, Equatable, Sendable {
            public var matcher: String?
            public var hooks: [HookCmd]
            public struct HookCmd: Codable, Equatable, Sendable {
                public var type: String
                public var command: String
            }
        }
    }
}

public enum InstallerError: Error, LocalizedError {
    case alreadyInstalled
    case settingsCorrupt
    case encodingFailed
    case noManifest

    public var errorDescription: String? {
        switch self {
        case .alreadyInstalled: return "blip is already installed (manifest present); run `blip uninstall` first"
        case .settingsCorrupt:  return "settings.json is not a valid JSON object"
        case .encodingFailed:   return "could not encode hook group"
        case .noManifest:       return "no manifest found — nothing to uninstall"
        }
    }
}

/// Events blip's CLI listens for. We add a BlipHooks entry to every
/// event in this list and absorb any matching pre-existing hooks.
///
/// PreToolUse is included so AskUserQuestion / ExitPlanMode pickers can
/// be intercepted; for any other tool, BlipHooks early-exits with no
/// side-effects (negligible overhead per tool call).
public enum BlipHookCoverage {
    public static let events: [String] = [
        "Stop", "Notification", "UserPromptSubmit", "SessionStart", "PreToolUse"
    ]
}

public enum Installer {

    @discardableResult
    public static func install(
        hookBinaryPath: String,
        paths: InstallPaths = .defaultPaths(),
        version: String = BlipCore.version,
        now: Date = Date()
    ) throws -> InstallManifest {
        if let existing = readManifest(at: paths.manifest), !existing.addedHooks.isEmpty {
            throw InstallerError.alreadyInstalled
        }

        var settings = try readSettings(at: paths.settings)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        var added: [InstallManifest.HookEntry] = []
        var removed: [InstallManifest.HookEntry] = []

        let blipCommand = "\(hookBinaryPath) --source claude"

        for event in BlipHookCoverage.events {
            var groups = (hooks[event] as? [Any]) ?? []
            var keptGroups: [Any] = []
            for group in groups {
                guard let dict = group as? [String: Any] else {
                    keptGroups.append(group); continue
                }
                if isReplaceable(group: dict) {
                    if let entry = try? toHookEntry(event: event, group: dict) {
                        removed.append(entry)
                    }
                    // dropped from settings
                } else {
                    keptGroups.append(group)
                }
            }
            // Append blip's group at the end so user-specific routing
            // hooks fire first (their additionalContext gets to Claude
            // before blip's no-op stdout passthrough).
            //
            // PreToolUse needs a matcher — Claude Code only invokes hooks
            // for tools whose name matches. Without matcher the hook
            // never fires for any tool. We scope to just the tools blip
            // intercepts so we don't add latency on every Bash/Read/etc.
            var blipGroup: [String: Any] = [
                "hooks": [["type": "command", "command": blipCommand]]
            ]
            if event == "PreToolUse" {
                blipGroup["matcher"] = "AskUserQuestion|ExitPlanMode"
            }
            keptGroups.append(blipGroup)
            hooks[event] = keptGroups

            let entry = try toHookEntry(event: event, group: blipGroup)
            added.append(entry)

            _ = groups  // silence unused warning
        }

        settings["hooks"] = hooks
        try writeAtomically(json: settings, to: paths.settings)

        let manifest = InstallManifest(
            version: version,
            installedAt: now,
            hookBinaryPath: hookBinaryPath,
            addedHooks: added,
            removedHooks: removed
        )
        try writeManifest(manifest, to: paths.manifest)
        return manifest
    }

    public static func uninstall(paths: InstallPaths = .defaultPaths()) throws {
        guard let manifest = readManifest(at: paths.manifest) else {
            throw InstallerError.noManifest
        }
        var settings = try readSettings(at: paths.settings)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]

        // Step 1: remove blip's added groups.
        for added in manifest.addedHooks {
            let target = try jsonObject(from: added.group)
            var groups = (hooks[added.event] as? [Any]) ?? []
            groups.removeAll { JSONComparator.equal($0, target) }
            hooks[added.event] = groups
        }
        // Step 2: restore originally-replaced groups.
        for removed in manifest.removedHooks {
            var groups = (hooks[removed.event] as? [Any]) ?? []
            groups.append(try jsonObject(from: removed.group))
            hooks[removed.event] = groups
        }
        // Step 3: cull empty event keys to keep settings.json tidy.
        for (event, value) in hooks {
            if let arr = value as? [Any], arr.isEmpty {
                hooks.removeValue(forKey: event)
            }
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try writeAtomically(json: settings, to: paths.settings)
        try? FileManager.default.removeItem(at: paths.manifest)
    }

    public static func readManifest(at url: URL) -> InstallManifest? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallManifest.self, from: data)
    }

    // MARK: - Replaceability heuristic

    /// A group is replaceable if EVERY command in it matches one of the
    /// patterns blip absorbs. A mixed group (sound + custom logic) is
    /// left alone to avoid breaking the user's routing rules.
    static func isReplaceable(group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]], !hooks.isEmpty else { return false }
        return hooks.allSatisfy { hook in
            guard let cmd = hook["command"] as? String else { return false }
            return matchesSoundHook(cmd) || matchesNotifFileHook(cmd)
        }
    }

    static func matchesSoundHook(_ command: String) -> Bool {
        // Pattern: `[ -f ~/.claude/.sound-disabled ] || afplay /path/to/sound`
        return command.contains("afplay") && command.contains(".sound-disabled")
    }

    static func matchesNotifFileHook(_ command: String) -> Bool {
        // Pattern: shell pipeline that writes /tmp/claude-notif-msg.txt
        return command.contains("/tmp/claude-notif-msg.txt")
    }

    // MARK: - File I/O

    private static func readSettings(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.settingsCorrupt
        }
        return obj
    }

    private static func writeAtomically(json: [String: Any], to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        )
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    private static func writeManifest(_ manifest: InstallManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func jsonObject<T: Encodable>(from value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallerError.encodingFailed
        }
        return obj
    }

    private static func toHookEntry(
        event: String,
        group: [String: Any]
    ) throws -> InstallManifest.HookEntry {
        let data = try JSONSerialization.data(withJSONObject: group, options: [.sortedKeys])
        let decoded = try JSONDecoder().decode(InstallManifest.HookEntry.HookGroup.self, from: data)
        return InstallManifest.HookEntry(event: event, group: decoded)
    }
}

/// Recursive deep-equality on JSON-deserialized values.
enum JSONComparator {
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        if let l = lhs as? [String: Any], let r = rhs as? [String: Any] {
            guard Set(l.keys) == Set(r.keys) else { return false }
            for key in l.keys {
                guard let lv = l[key], let rv = r[key] else { return false }
                if !equal(lv, rv) { return false }
            }
            return true
        }
        if let l = lhs as? [Any], let r = rhs as? [Any] {
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { equal($0, $1) }
        }
        if let l = lhs as? String, let r = rhs as? String { return l == r }
        if let l = lhs as? Int,    let r = rhs as? Int    { return l == r }
        if let l = lhs as? Double, let r = rhs as? Double { return l == r }
        if let l = lhs as? Bool,   let r = rhs as? Bool   { return l == r }
        return (lhs is NSNull) && (rhs is NSNull)
    }
}
