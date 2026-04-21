// Assembles the `.app` wrapper at a stable user-owned path so macOS TCC
// can key Accessibility grants by bundle identity instead of brew's
// versioned cellar path.
//
// Before v0.4.0 blip shipped a raw Mach-O at `/opt/homebrew/bin/BlipApp`;
// every `brew upgrade` moved the binary to a new cellar (HEAD-<sha>/...)
// which TCC treated as a fresh app, invalidating the user's grant.
//
// Fix: ship `~/Applications/Blip.app` with a stable CFBundleIdentifier
// `com.elpabl0.blip`, ad-hoc signed with an explicit designated
// requirement `identifier "com.elpabl0.blip"`. TCC uses the DR as its
// identity key — two signatures with the same DR are "the same app" from
// its perspective, so future upgrades satisfy the existing grant.
import Foundation

public enum AppBundle {
    public static let bundleIdentifier = "com.elpabl0.blip"
    public static let bundleName = "Blip"
    public static let bundleExecutable = "BlipApp"

    public struct Paths: Sendable {
        public let app: URL
        public let contents: URL
        public let macos: URL
        public let infoPlist: URL
        public let binary: URL

        public static func defaultPaths() -> Paths {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let app = home
                .appendingPathComponent("Applications")
                .appendingPathComponent("\(bundleName).app")
            let contents = app.appendingPathComponent("Contents")
            let macos = contents.appendingPathComponent("MacOS")
            return Paths(
                app: app,
                contents: contents,
                macos: macos,
                infoPlist: contents.appendingPathComponent("Info.plist"),
                binary: macos.appendingPathComponent(bundleExecutable)
            )
        }
    }

    public enum BundleError: Error, LocalizedError {
        case sourceBinaryMissing(String)
        case codesignFailed(exitCode: Int32, stderr: String)

        public var errorDescription: String? {
            switch self {
            case .sourceBinaryMissing(let p):
                return "source binary not found at \(p) — brew install may be incomplete"
            case .codesignFailed(let code, let stderr):
                return "codesign exited \(code): \(stderr)"
            }
        }
    }

    /// Builds or refreshes the bundle from the given source binary, then
    /// ad-hoc signs it with the stable designated requirement.
    /// Idempotent: safe to call on every brew install/upgrade.
    @discardableResult
    public static func refresh(
        from sourceBinary: URL,
        paths: Paths = .defaultPaths(),
        version: String = BlipCore.version
    ) throws -> Paths {
        guard FileManager.default.isExecutableFile(atPath: sourceBinary.path) else {
            throw BundleError.sourceBinaryMissing(sourceBinary.path)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.macos, withIntermediateDirectories: true)

        try infoPlistXML(version: version).write(
            to: paths.infoPlist, atomically: true, encoding: .utf8
        )

        // Overwrite the binary atomically. codesign rewrites the embedded
        // signature blob at the end, so removing the old file first avoids
        // any "signature present but stale" weirdness.
        if fm.fileExists(atPath: paths.binary.path) {
            try fm.removeItem(at: paths.binary)
        }
        try fm.copyItem(at: sourceBinary, to: paths.binary)

        try codesign(bundle: paths.app)
        return paths
    }

    public static func remove(paths: Paths = .defaultPaths()) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.app.path) {
            try fm.removeItem(at: paths.app)
        }
    }

    public static func exists(paths: Paths = .defaultPaths()) -> Bool {
        FileManager.default.fileExists(atPath: paths.app.path)
    }

    // MARK: - Internals

    private static func infoPlistXML(version: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleIdentifier)</string>
            <key>CFBundleName</key>
            <string>\(bundleName)</string>
            <key>CFBundleDisplayName</key>
            <string>\(bundleName)</string>
            <key>CFBundleExecutable</key>
            <string>\(bundleExecutable)</string>
            <key>CFBundleVersion</key>
            <string>\(version)</string>
            <key>CFBundleShortVersionString</key>
            <string>\(version)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>LSUIElement</key>
            <true/>
            <key>NSHighResolutionCapable</key>
            <true/>
            <key>LSMinimumSystemVersion</key>
            <string>14.0</string>
        </dict>
        </plist>
        """
    }

    /// codesign's `-r` wants either a file path or a file path prefixed by
    /// `=` as a literal. The inline-literal variant is fiddly across
    /// versions; the file path form is bullet-proof, so we stage the
    /// requirement document in a temp file and point at that.
    private static func codesign(bundle: URL) throws {
        let reqTemp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("blip-codesign-\(UUID().uuidString).txt")
        let reqBody = "designated => identifier \"\(bundleIdentifier)\"\n"
        try reqBody.write(to: reqTemp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: reqTemp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = [
            "--sign", "-",
            "--identifier", bundleIdentifier,
            "-r", reqTemp.path,
            "--force", "--deep",
            bundle.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "(no stderr)"
            throw BundleError.codesignFailed(
                exitCode: process.terminationStatus, stderr: msg
            )
        }
    }
}
