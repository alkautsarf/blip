// Resolves the bridge socket path. Defaults to the user's Application
// Support directory; overridable via BLIP_SOCKET_PATH for tests and
// alternate setups.
import Foundation

public enum SocketPath {
    public static let environmentOverride = "BLIP_SOCKET_PATH"

    public static func resolved() -> URL {
        if let override = ProcessInfo.processInfo.environment[environmentOverride], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("blip/bridge.sock")
    }

    /// Ensures the parent directory exists. Throws on filesystem failure.
    public static func ensureParentExists() throws {
        let parent = resolved().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
}
