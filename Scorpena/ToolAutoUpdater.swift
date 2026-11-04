import Foundation

/// Silent, at-most-once-a-day update of the yt-dlp that ships inside the app.
///
/// The bundled yt-dlp is the official "onedir" build — `bin/yt-dlp` plus the
/// `bin/_internal` folder next to it. It starts in a fraction of a second
/// (the single-file build needed ~8 s per launch), but it can't update itself,
/// so this does it:
///
/// - Stable channel only: it only ever moves to the latest GitHub release
///   (never nightly), and only when that release is newer than what's installed.
/// - The download is checked against the SHA-256 list published with the release.
/// - Safe: the new build is unpacked beside the old one and must run, report
///   the expected version and read a known public video *before* anything is
///   swapped. If it can't but the old one still can, the old one stays and that
///   version is skipped from then on. The swap itself is two renames; the old
///   build is kept until the new one has started once more from its final place.
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

    /// The steps of an update, for the progress line in «Дополнительно».
    enum Stage: Int { case checking = 1, downloading, unpacking, verifying }

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

    // MARK: Folders next to the live binary

    private static func newDir(in bin: URL) -> URL { bin.appendingPathComponent(".ytdlp-new", isDirectory: true) }
    private static func oldDir(in bin: URL) -> URL { bin.appendingPathComponent(".ytdlp-old", isDirectory: true) }

    /// If the app was quit in the middle of a swap (the live yt-dlp is missing
    /// but the previous build is still parked aside), puts the previous build
    /// back; otherwise just clears leftovers. Call once at launch.
    static func recoverInterruptedSwap() {
        guard let binPath = ToolLocator.bundledBinDirectory else { return }
        let bin = URL(fileURLWithPath: binPath, isDirectory: true)
        let fm = FileManager.default
        let old = oldDir(in: bin)
        let liveOK = fm.isExecutableFile(atPath: bin.appendingPathComponent("yt-dlp").path)
            && fm.fileExists(atPath: bin.appendingPathComponent("_internal").path)
        if !liveOK, fm.fileExists(atPath: old.path) {
            for name in ["yt-dlp", "_internal"] {
                let live = bin.appendingPathComponent(name), parked = old.appendingPathComponent(name)
                if fm.fileExists(atPath: parked.path) {
                    try? fm.removeItem(at: live)
                    try? fm.moveItem(at: parked, to: live)
                }
            }
        }
        try? fm.removeItem(at: old)
        try? fm.removeItem(at: newDir(in: bin))
    }

    // MARK: Update flow (background queue)

    /// Starting a yt-dlp that macOS hasn't seen yet takes ~8 s once, so the
    /// installed version is passed in when it's already known and launches are
    /// kept to a minimum.
    private func update(ytDlp: String, knownVersion: String?, stage: ((Stage) -> Void)? = nil) -> Outcome {
        let defaults = UserDefaults.standard
        let fm = FileManager.default
        stage?(.checking)

        let bin = URL(fileURLWithPath: ytDlp).deletingLastPathComponent()
        guard fm.fileExists(atPath: bin.appendingPathComponent("_internal").path) else {
            log("this yt-dlp isn't the folder build — not updating it")
            return .failed
        }
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

        let fresh = Self.newDir(in: bin), parked = Self.oldDir(in: bin)
        try? fm.removeItem(at: fresh)
        try? fm.removeItem(at: parked)
        defer { try? fm.removeItem(at: fresh) }

        // 1. download + checksum
        stage?(.downloading)
        let download = supportDir.appendingPathComponent("Update", isDirectory: true)
        try? fm.removeItem(at: download)
        try? fm.createDirectory(at: download, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: download) }
        let zip = download.appendingPathComponent("yt-dlp_macos.zip")
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/\(latest)/"
        guard Self.download(URL(string: base + "yt-dlp_macos.zip")!, to: zip, timeout: 300) else {
            log("download failed")
            return .offline
        }
        guard let sums = Self.fetchText(URL(string: base + "SHA2-256SUMS")!),
              let expected = Self.expectedHash(in: sums, file: "yt-dlp_macos.zip"),
              let actual = Self.sha256(of: zip), expected == actual
        else {
            log("checksum of \(latest) did not match — not installing it")
            DiagnosticReporter.report(.ytDlpRolledBack,
                details: "yt-dlp \(current) → \(latest): контрольная сумма скачанного файла не совпала, обновление отменено.")
            return .keptOld(current: current, rejected: latest)
        }

        // 2. unpack beside the live copy (same volume → the swap is a rename)
        stage?(.unpacking)
        do {
            try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
            guard Self.runPlain("/usr/bin/ditto", ["-x", "-k", zip.path, fresh.path]) == 0 else { throw CocoaError(.fileReadCorruptFile) }
            try fm.moveItem(at: fresh.appendingPathComponent("yt-dlp_macos"), to: fresh.appendingPathComponent("yt-dlp"))
            _ = Self.runPlain("/usr/bin/xattr", ["-cr", fresh.path])
            guard fm.isExecutableFile(atPath: fresh.appendingPathComponent("yt-dlp").path),
                  fm.fileExists(atPath: fresh.appendingPathComponent("_internal").path)
            else { throw CocoaError(.fileReadCorruptFile) }
        } catch {
            log("unpacking failed: \(error.localizedDescription)")
            return .failed
        }

        // 3. the new build must work before it replaces anything
        stage?(.verifying)
        let candidate = fresh.appendingPathComponent("yt-dlp").path
        let reported = DownloadManager.captureOutput(candidate, ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == latest else {
            log("new build reports \(reported ?? "nothing"), expected \(latest) — not installing")
            DiagnosticReporter.report(.ytDlpRolledBack,
                details: "yt-dlp \(current) → \(latest): новая версия не запустилась (ответ: \(reported ?? "ничего")), осталась \(current).")
            defaults.set(latest, forKey: skippedVersionKey)
            return .keptOld(current: current, rejected: latest)
        }
        if !canary(candidate) {
            if canary(ytDlp) {
                log("\(latest) failed the self-check but \(current) works — keeping \(current)")
                DiagnosticReporter.report(.ytDlpRolledBack,
                    details: "yt-dlp \(latest) не прошёл самопроверку на YouTube, а \(current) работает — остаётся \(current).")
                defaults.set(latest, forKey: skippedVersionKey)
                return .keptOld(current: current, rejected: latest)
            }
            log("self-check failed for both versions (network or site problem) — installing \(latest) anyway")
        }

        // 4. swap: live → parked, new → live; undo everything if anything fails
        guard swap(bin: bin, fresh: fresh, parked: parked) else {
            log("could not swap the files in (is the app folder writable?) — keeping \(current)")
            return .failed
        }
        let after = DownloadManager.captureOutput(ytDlp, ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if after != latest {
            log("after the swap yt-dlp reports \(after ?? "nothing") — putting \(current) back")
            DiagnosticReporter.report(.ytDlpRolledBack,
                details: "yt-dlp \(current) → \(latest): после замены файлов версия \(after ?? "не определилась"), откат.")
            swapBack(bin: bin, parked: parked)
            defaults.set(latest, forKey: skippedVersionKey)
            return .keptOld(current: current, rejected: latest)
        }
        try? fm.removeItem(at: parked)
        log("updated to \(latest), self-check passed")
        return .updated(from: current, to: latest)
    }

    private func canary(_ binary: String) -> Bool {
        let args = ["--no-warnings", "--no-playlist", "--skip-download", "--print", "%(title)s"]
            + DownloadManager.jsRuntimeArgs() + [Self.canaryURL]
        guard let result = Self.run(binary, args, timeout: 90) else { return false }
        return result.status == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Swap / rollback

    private func swap(bin: URL, fresh: URL, parked: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: parked, withIntermediateDirectories: true)
            try fm.moveItem(at: bin.appendingPathComponent("yt-dlp"), to: parked.appendingPathComponent("yt-dlp"))
            try fm.moveItem(at: bin.appendingPathComponent("_internal"), to: parked.appendingPathComponent("_internal"))
            try fm.moveItem(at: fresh.appendingPathComponent("yt-dlp"), to: bin.appendingPathComponent("yt-dlp"))
            try fm.moveItem(at: fresh.appendingPathComponent("_internal"), to: bin.appendingPathComponent("_internal"))
            return true
        } catch {
            log("swap step failed: \(error.localizedDescription)")
            swapBack(bin: bin, parked: parked)
            return false
        }
    }

    /// Puts the parked (previous) build back in place of whatever is live.
    private func swapBack(bin: URL, parked: URL) {
        let fm = FileManager.default
        for name in ["yt-dlp", "_internal"] {
            let live = bin.appendingPathComponent(name), old = parked.appendingPathComponent(name)
            guard fm.fileExists(atPath: old.path) else { continue }
            try? fm.removeItem(at: live)
            do { try fm.moveItem(at: old, to: live) } catch { log("ROLLBACK FAILED for \(name): \(error.localizedDescription)") }
        }
        try? fm.removeItem(at: parked)
        let restored = DownloadManager.captureOutput(bin.appendingPathComponent("yt-dlp").path, ["--version"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        log("rolled back, installed version is now \(restored)")
    }

    // MARK: Network + hashing

    private static func download(_ url: URL, to destination: URL, timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = false
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let task = URLSession.shared.downloadTask(with: request) { temp, response, _ in
            defer { semaphore.signal() }
            guard let temp, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.removeItem(at: destination)
            ok = (try? FileManager.default.moveItem(at: temp, to: destination)) != nil
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut { task.cancel(); return false }
        return ok
    }

    private static func fetchText(_ url: URL) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var text: String?
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            text = String(data: data, encoding: .utf8)
        }.resume()
        _ = semaphore.wait(timeout: .now() + 25)
        return text
    }

    /// "<hash>  <file>" lines, as in yt-dlp's SHA2-256SUMS.
    private static func expectedHash(in sums: String, file: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "*" })
            if parts.count >= 2, parts.last.map(String.init) == file { return String(parts[0]).lowercased() }
        }
        return nil
    }

    private static func sha256(of file: URL) -> String? {
        run("/usr/bin/shasum", ["-a", "256", file.path], timeout: 120)?
            .output.split(separator: " ").first.map { String($0).lowercased() }
    }

    private static func runPlain(_ path: String, _ args: [String]) -> Int32 {
        run(path, args, timeout: 300)?.status ?? -1
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
