import Foundation

/// Silent, at-most-once-a-day update of the yt-dlp that ships inside the app.
///
/// - Stable channel only: it only ever moves to the latest GitHub release
///   (never nightly), and only when that release is newer than what's installed.
/// - Safe: the current binary is copied aside first. After updating, the new
///   one must run and report the expected version, and must be able to read a
///   known public video. If it can't but the old one still can, the old one
///   is put back and that version is skipped from then on.
/// - Everything is written to `tool-update.log` in Application Support, so a
///   "stopped working" report can be traced to an update.
final class ToolAutoUpdater {
    static let shared = ToolAutoUpdater()

    private let lastCheckKey = "lastAutoToolUpdateCheck"
    private let skippedVersionKey = "autoUpdateSkippedYtDlpVersion"
    private let queue = DispatchQueue(label: "tool-auto-updater", qos: .utility)
    private var running = false                       // main thread only

    /// A long-lived, public video — used only to tell "yt-dlp works" from
    /// "this yt-dlp is broken", never shown to the user.
    private static let canaryURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

    private let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VideoDownloader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The four steps of an update, for the progress line in «Дополнительно».
    enum Stage: Int { case checking = 1, backingUp, downloading, verifying }

    enum Outcome {
        case upToDate(String)
        case updated(from: String, to: String)
        case keptOld(current: String, rejected: String)   // new one failed the self-check
        case offline
        case failed
    }

    /// Main thread. `completion` runs on the main thread only if a new
    /// version was actually installed and kept.
    func runIfDue(ytDlp: String?, knownVersion: String?, completion: @escaping () -> Void) {
        guard !running, let ytDlp, ToolLocator.isBundled(ytDlp) else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }

        running = true
        queue.async { [self] in
            let outcome = update(ytDlp: ytDlp, knownVersion: knownVersion)
            DispatchQueue.main.async {
                self.running = false
                if case .updated = outcome { completion() }
            }
        }
    }

    /// The "Проверить сейчас" button: same safe update as the daily one,
    /// without the once-a-day limit. Main thread; `completion` also main.
    func updateNow(ytDlp: String, knownVersion: String?, onStage: @escaping (Stage) -> Void, completion: @escaping (Outcome) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let outcome = update(ytDlp: ytDlp, knownVersion: knownVersion) { stage in
                DispatchQueue.main.async { onStage(stage) }
            }
            DispatchQueue.main.async {
                self.running = false
                completion(outcome)
            }
        }
    }

    // MARK: Update flow (background queue)

    /// Starting yt-dlp takes ~8 s on its own (the single-file build unpacks
    /// itself and macOS scans every piece), so launches are kept to a minimum:
    /// the installed version is passed in when it's already known, and the
    /// result of the update is read from the updater's own output.
    private func update(ytDlp: String, knownVersion: String?, stage: ((Stage) -> Void)? = nil) -> Outcome {
        let defaults = UserDefaults.standard
        stage?(.checking)
        let cached = knownVersion?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = (cached?.isEmpty == false ? cached : nil)
                ?? DownloadManager.captureOutput(ytDlp, ["--version"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty
        else { return .failed }
        guard let latest = DownloadManager.fetchLatestYtDlpVersion() else { return .offline }

        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard Self.isNewer(latest, than: current) else {
            log("up to date (installed \(current), latest stable \(latest))")
            return .upToDate(current)
        }
        if defaults.string(forKey: skippedVersionKey) == latest {
            log("skipping \(latest): it failed the self-check earlier")
            return .keptOld(current: current, rejected: latest)
        }

        log("updating \(current) -> \(latest)")
        stage?(.backingUp)
        guard let backup = makeBackup(of: ytDlp, version: current) else {
            log("could not back up the current version — not updating")
            return .failed
        }

        stage?(.downloading)
        let result = Self.run(ytDlp, ["--update-to", "stable"], timeout: 240)
        var installed: String? = nil
        if let result, result.status == 0, result.output.contains("Updated yt-dlp to stable@\(latest)") {
            installed = latest
        } else {
            installed = DownloadManager.captureOutput(ytDlp, ["--version"])?   // slow path, only if the output wasn't recognised
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard installed == latest else {
            log("update did not produce \(latest) (got \(installed ?? "nothing")) — rolling back")
            DiagnosticReporter.report(.ytDlpRolledBack,
                details: "yt-dlp \(current) → \(latest): после обновления версия \(installed ?? "не определилась"), откат.")
            restore(backup, over: ytDlp)
            defaults.set(latest, forKey: skippedVersionKey)
            return .keptOld(current: current, rejected: latest)
        }

        stage?(.verifying)
        if canary(ytDlp) {
            log("updated to \(latest), self-check passed")
            return .updated(from: current, to: latest)
        }
        if canary(backup.path) {
            log("\(latest) failed the self-check but \(current) works — rolling back")
            DiagnosticReporter.report(.ytDlpRolledBack,
                details: "yt-dlp \(latest) не прошёл самопроверку на YouTube, а \(current) работает — откат на \(current).")
            restore(backup, over: ytDlp)
            defaults.set(latest, forKey: skippedVersionKey)
            return .keptOld(current: current, rejected: latest)
        }
        log("updated to \(latest); self-check failed for both versions (network or site problem) — keeping the new one")
        return .updated(from: current, to: latest)
    }

    private func canary(_ binary: String) -> Bool {
        let args = ["--no-warnings", "--no-playlist", "--skip-download", "--print", "%(title)s"]
            + DownloadManager.jsRuntimeArgs() + [Self.canaryURL]
        guard let result = Self.run(binary, args, timeout: 90) else { return false }
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Backup / rollback

    private func makeBackup(of ytDlp: String, version: String) -> URL? {
        let fm = FileManager.default
        let dir = supportDir.appendingPathComponent("Backup", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            try? fm.removeItem(at: dir.appendingPathComponent(old))
        }
        let target = dir.appendingPathComponent("yt-dlp-\(version)")
        do {
            try fm.copyItem(atPath: ytDlp, toPath: target.path)
            return target
        } catch {
            return nil
        }
    }

    /// Copies the backup next to the live file, then swaps it in with an
    /// atomic rename, so a download starting at that moment never finds the
    /// file missing.
    private func restore(_ backup: URL, over ytDlp: String) {
        let fm = FileManager.default
        let temp = ytDlp + ".rollback"
        try? fm.removeItem(atPath: temp)
        do {
            try fm.copyItem(atPath: backup.path, toPath: temp)
            guard rename(temp, ytDlp) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let restored = DownloadManager.captureOutput(ytDlp, ["--version"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
            log("rolled back, installed version is now \(restored)")
        } catch {
            try? fm.removeItem(atPath: temp)
            log("ROLLBACK FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    /// "2026.10.21" > "2026.08.19"; a nightly ("2026.10.23.233055") counts as
    /// newer than the stable of the same day, so we never "update" it back.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Runs a binary with a clean environment and a hard time limit.
    private static func run(_ path: String, _ args: [String], timeout: TimeInterval)
        -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [ToolLocator.bundledBinDirectory, "/usr/bin", "/bin"].compactMap { $0 }.joined(separator: ":")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func log(_ message: String) {
        let url = supportDir.appendingPathComponent("tool-update.log")
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 20_000 {
            try? FileManager.default.removeItem(at: url)
        }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
