// User-editable configuration for blip. Persisted as JSON at
// `~/.config/blip/config.json`. Missing file or missing keys fall back
// to `BlipConfig.default`, so the app never refuses to start because of
// a config issue.
import Foundation

public struct BlipConfig: Codable, Equatable, Sendable {
    /// Which display the notch attaches to: "laptop" (notched only),
    /// "main" (synthetic pill on NSScreen.main), or "auto" (prefer
    /// notched, fall back to main).
    public var display: String

    /// Optional override for the bridge socket path. nil → default
    /// (`~/Library/Application Support/blip/bridge.sock`).
    public var socketPath: String?

    /// Verbosity for stderr logs: "debug" | "info" | "warn" | "error".
    public var logLevel: String

    /// Show a menu-bar item for quick display switching. Off by default
    /// so users who already get everything they need from the `blip`
    /// CLI aren't cluttering their menu bar.
    public var menuBarEnabled: Bool

    /// Message written to `/tmp/claude-notif-msg.txt` when a Stop hook
    /// fires without a visible assistant reply. Consumed by tmux
    /// statusline scripts. Truncated to ~60 chars for the one-line pane.
    public var stopFallbackMessage: String

    public static let `default` = BlipConfig(
        display: "main",
        socketPath: nil,
        logLevel: "info",
        menuBarEnabled: false,
        stopFallbackMessage: "Claude finished"
    )

    public init(
        display: String,
        socketPath: String?,
        logLevel: String,
        menuBarEnabled: Bool = false,
        stopFallbackMessage: String = "Claude finished"
    ) {
        self.display = display
        self.socketPath = socketPath
        self.logLevel = logLevel
        self.menuBarEnabled = menuBarEnabled
        self.stopFallbackMessage = stopFallbackMessage
    }

    // Backward-compatible decode for configs missing newer fields.
    enum CodingKeys: String, CodingKey {
        case display, socketPath, logLevel, menuBarEnabled, stopFallbackMessage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display             = try c.decodeIfPresent(String.self, forKey: .display) ?? "main"
        socketPath          = try c.decodeIfPresent(String.self, forKey: .socketPath)
        logLevel            = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
        menuBarEnabled      = try c.decodeIfPresent(Bool.self, forKey: .menuBarEnabled) ?? false
        stopFallbackMessage = try c.decodeIfPresent(String.self, forKey: .stopFallbackMessage) ?? "Claude finished"
    }
}

public enum BlipConfigStore {
    /// Default location: `~/.config/blip/config.json` (XDG-friendly).
    public static func defaultPath() -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent(".config/blip/config.json")
    }

    public static func load(from url: URL = defaultPath()) -> BlipConfig {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(BlipConfig.self, from: data)
        else { return .default }
        return config
    }

    public static func save(_ config: BlipConfig, to url: URL = defaultPath()) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    /// Read-modify-write helper. Used by `blip config set`.
    @discardableResult
    public static func update(
        at url: URL = defaultPath(),
        _ mutate: (inout BlipConfig) -> Void
    ) throws -> BlipConfig {
        var current = load(from: url)
        mutate(&current)
        try save(current, to: url)
        return current
    }

    /// Returns the value of a single key as a string, for `blip config get`.
    public static func value(of key: String, in config: BlipConfig) -> String? {
        switch key {
        case "display":             return config.display
        case "socketPath":          return config.socketPath ?? ""
        case "logLevel":            return config.logLevel
        case "menuBarEnabled":      return config.menuBarEnabled ? "true" : "false"
        case "stopFallbackMessage": return config.stopFallbackMessage
        default:                    return nil
        }
    }

    /// Sets a single key from a string, for `blip config set`.
    public static func setValue(_ value: String, for key: String, in config: inout BlipConfig) -> Bool {
        switch key {
        case "display":
            guard ["laptop", "main", "auto"].contains(value) else { return false }
            config.display = value
        case "socketPath":
            config.socketPath = value.isEmpty ? nil : value
        case "logLevel":
            guard ["debug", "info", "warn", "error"].contains(value) else { return false }
            config.logLevel = value
        case "menuBarEnabled":
            switch value.lowercased() {
            case "true", "1", "yes", "on":  config.menuBarEnabled = true
            case "false", "0", "no", "off": config.menuBarEnabled = false
            default: return false
            }
        case "stopFallbackMessage":
            guard !value.isEmpty else { return false }
            config.stopFallbackMessage = value
        default:
            return false
        }
        return true
    }

    public static let validKeys = ["display", "socketPath", "logLevel", "menuBarEnabled", "stopFallbackMessage"]
}
