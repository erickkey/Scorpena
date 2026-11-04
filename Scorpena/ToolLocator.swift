import Foundation

/// Finds the command-line tools (yt-dlp, ffmpeg) the app needs: the copies shipped
/// inside the .app (`Contents/Resources/bin`). Nothing is picked up from the rest of
/// the system, so the app behaves the same on every Mac.
enum ToolLocator {

    /// Directory of the binaries shipped inside the app bundle, if present.
    static var bundledBinDirectory: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("bin", isDirectory: true).path
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// True if `path` points at a binary we ship inside the bundle.
    static func isBundled(_ path: String) -> Bool {
        guard let bundled = bundledBinDirectory else { return false }
        return path.hasPrefix(bundled + "/")
    }

    /// Returns an absolute path to the bundled `name`, or nil if it isn't there.
    static func find(_ name: String, userOverride: String?) -> String? {
        let fm = FileManager.default

        if let override = userOverride,
           !override.isEmpty,
           fm.isExecutableFile(atPath: override) {
            return override
        }

        if let bundled = bundledBinDirectory {
            let candidate = "\(bundled)/\(name)"
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
