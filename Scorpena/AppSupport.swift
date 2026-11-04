import Foundation

/// Where the program keeps its own data (queue, history, caches, half-finished files).
/// Always the same folder — except when the tests say otherwise (`SCORPENA_SUPPORT_DIR`), so that
/// they never touch the real queue and history.
enum AppSupport {
    static var folder: URL {
        if let override = ProcessInfo.processInfo.environment["SCORPENA_SUPPORT_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoDownloader", isDirectory: true)
    }

    /// True when the folder is the real one.
    static var isReal: Bool { ProcessInfo.processInfo.environment["SCORPENA_SUPPORT_DIR"]?.isEmpty ?? true }
}
