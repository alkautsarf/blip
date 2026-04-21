// Shared executable-sibling lookup for the CLI binaries. Both `Blip`
// and `BlipSetup` need to invoke sibling binaries (BlipApp, BlipHooks)
// and must resolve the real on-disk location even when invoked via a
// PATH symlink — `_NSGetExecutablePath` + `resolvingSymlinksInPath()`
// is the standard macOS pattern.
import Foundation

public enum ExecutableLookup {
    public struct MissingBinaryError: LocalizedError {
        public let name: String
        public let resolvedPath: String?
        public var errorDescription: String? {
            let path = resolvedPath ?? name
            return "binary not found at \(path) — did you run `swift build -c release`?"
        }
    }

    /// Locates a sibling binary next to the currently-running executable.
    /// Returns the URL or throws `MissingBinaryError`.
    public static func sibling(named name: String) throws -> URL {
        var buffer = [CChar](repeating: 0, count: 4096)
        var size = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw MissingBinaryError(name: name, resolvedPath: nil)
        }
        let current = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let sibling = current.deletingLastPathComponent().appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw MissingBinaryError(name: name, resolvedPath: sibling.path)
        }
        return sibling
    }

    /// Like `sibling(named:)` but prefers a brew-stable symlink path
    /// (e.g. `/opt/homebrew/bin/BlipHooks`) when the resolved binary
    /// lives under a versioned cellar. Settings files (hook registration,
    /// LaunchAgent plist) should use this so paths stay valid across
    /// `brew upgrade` cellar rotations.
    public static func stableSibling(named name: String) throws -> URL {
        let resolved = try sibling(named: name)
        let path = resolved.path
        // Detect brew cellar installs (both /opt/homebrew and /usr/local
        // Intel prefixes). Rewrite to the prefix/bin symlink if it
        // points back at the same file.
        for prefix in ["/opt/homebrew", "/usr/local"] {
            let cellarPrefix = "\(prefix)/Cellar/"
            guard path.hasPrefix(cellarPrefix) else { continue }
            let stable = URL(fileURLWithPath: "\(prefix)/bin/\(name)")
            if FileManager.default.isExecutableFile(atPath: stable.path) {
                return stable
            }
        }
        return resolved
    }
}
