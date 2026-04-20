// blip installer/uninstaller CLI. All logic lives in BlipCore.Installer
// so it can be unit-tested. This file is just argv parsing + pretty
// output.
import Foundation
import BlipCore

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    print("usage: BlipSetup <install|uninstall|status>")
    exit(64)
}

let paths = InstallPaths.defaultPaths()

do {
    switch arguments[1] {
    case "install":
        let binary = try resolveHookBinary()
        let manifest = try Installer.install(hookBinaryPath: binary.path, paths: paths)
        print("✓ blip installed")
        print("  hook binary: \(manifest.hookBinaryPath)")
        print("  manifest:    \(paths.manifest.path)")

    case "uninstall":
        try Installer.uninstall(paths: paths)
        print("✓ blip uninstalled — settings.json restored")

    case "status":
        if let manifest = Installer.readManifest(at: paths.manifest) {
            print("blip is INSTALLED")
            print("  version:       \(manifest.version)")
            print("  installed at:  \(manifest.installedAt)")
            print("  hook binary:   \(manifest.hookBinaryPath)")
            print("  hook entries:  \(manifest.addedHooks.count)")
        } else {
            print("blip is NOT installed (no manifest at \(paths.manifest.path))")
        }

    default:
        print("unknown subcommand: \(arguments[1])")
        exit(64)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

/// Locates the BlipHooks binary alongside the BlipSetup binary, working
/// even when BlipSetup is invoked via a PATH symlink.
func resolveHookBinary() throws -> URL {
    var buffer = [CChar](repeating: 0, count: 4096)
    var size = UInt32(buffer.count)
    guard _NSGetExecutablePath(&buffer, &size) == 0 else {
        struct MissingBinaryError: LocalizedError {
            var errorDescription: String? { "could not resolve BlipSetup executable path" }
        }
        throw MissingBinaryError()
    }
    let setupBinary = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    let hookBinary = setupBinary.deletingLastPathComponent().appendingPathComponent("BlipHooks")
    guard FileManager.default.isExecutableFile(atPath: hookBinary.path) else {
        struct MissingBinaryError: LocalizedError {
            let path: String
            var errorDescription: String? {
                "BlipHooks binary not found at \(path) — `swift build` first"
            }
        }
        throw MissingBinaryError(path: hookBinary.path)
    }
    return hookBinary
}
