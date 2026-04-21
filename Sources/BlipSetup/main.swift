// blip installer/uninstaller CLI. All logic lives in BlipCore.Installer
// so it can be unit-tested. This file is just argv parsing + pretty
// output.
import Foundation
import BlipCore

let arguments = CommandLine.arguments

guard arguments.count >= 2 else {
    print("usage: BlipSetup <install|uninstall|status|bundle-refresh>")
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

    case "bundle-refresh":
        // Called by the brew formula's post_install hook. Rebuilds the
        // `.app` bundle from the freshly-installed cellar binary and
        // re-signs with the stable designated requirement so the TCC
        // grant survives the upgrade. If the LaunchAgent is loaded we
        // also kickstart so the running process picks up the new binary.
        let source = try ExecutableLookup.sibling(named: "BlipApp")
        let bundlePaths = try AppBundle.refresh(from: source)
        print("✓ refreshed bundle at \(bundlePaths.app.path)")
        if LaunchAgent.isLoaded() {
            try LaunchAgent.kickstart()
            print("✓ launchd kickstarted — running process now on the new binary")
        }

    default:
        print("unknown subcommand: \(arguments[1])")
        exit(64)
    }
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}

/// Locates the BlipHooks binary alongside the BlipSetup binary.
func resolveHookBinary() throws -> URL {
    try ExecutableLookup.sibling(named: "BlipHooks")
}
