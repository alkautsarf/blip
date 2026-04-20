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
}
