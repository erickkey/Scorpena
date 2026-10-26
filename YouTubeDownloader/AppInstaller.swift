import AppKit

/// Replaces the running app with a newer build from GitHub without the user
/// touching a browser or a DMG. Because *this process* downloads the file it
/// carries no "downloaded from the internet" quarantine flag, so macOS doesn't
/// put the usual Gatekeeper block in front of the new version.
///
/// Flow: download the release DMG → mount it read-only → copy the app next to
/// the installed one → verify it (same bundle id, newer version, valid
/// signature, all bundled tools present) → quit; a tiny shell helper swaps the
/// folders, relaunches, and puts the old version back if the new one doesn't
/// stay running.
enum AppInstaller {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let downloadURL = URL(string:
        "https://github.com/erickkey/Scorpena/releases/latest/download/Scorpena.dmg")!

    static var currentAppURL: URL { Bundle.main.bundleURL }

    private static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoDownloader", isDirectory: true)
    }()
    private static var updateDir: URL { supportDir.appendingPathComponent("Update", isDirectory: true) }
    private static var stagingURL: URL {
        currentAppURL.deletingLastPathComponent().appendingPathComponent(".Scorpena-update.app")
    }

    /// nil when the app can replace itself; otherwise why it can't (the caller
    /// then just opens the download page like before).
    static func cannotReplaceSelfReason() -> String? {
        let path = currentAppURL.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "running from a mounted or translocated location"
        }
        if !FileManager.default.isWritableFile(atPath: currentAppURL.deletingLastPathComponent().path) {
            return "the folder the app lives in isn't writable"
        }
        return nil
    }

    /// Removes anything a previous update attempt left behind.
    static func cleanupLeftovers() {
        let fm = FileManager.default
        try? fm.removeItem(at: updateDir)
        try? fm.removeItem(at: stagingURL)
        // left by 2.x updates
        try? fm.removeItem(at: currentAppURL.deletingLastPathComponent().appendingPathComponent(".VideoDownloader-update.app"))
    }

    private static var unpackMessage: String {
        tr("Скачанный файл не открылся — возможно, загрузка прервалась. Попробуй ещё раз.")
    }

    /// Human reason for any error the update can run into.
    static func friendlyMessage(for error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
                return tr("Нет связи с интернетом или GitHub недоступен. Проверь подключение и попробуй ещё раз.")
            default: break
            }
        }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace {
            return tr("Не хватает места на диске. Освободи около 1 ГБ и попробуй снова.")
        }
        return trf("Что-то пошло не так: %@", error.localizedDescription)
    }

    /// The update needs roughly the download plus an unpacked copy.
    static func ensureDiskSpace() throws {
        let needed: Int64 = 900_000_000
        for url in [supportDir, currentAppURL.deletingLastPathComponent()] {
            let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
            if let free = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, free < needed {
                throw Failure(message: tr("Не хватает места на диске. Освободи около 1 ГБ и попробуй снова."))
            }
        }
    }

    // MARK: Download

    static func download(from url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)
        let destination = updateDir.appendingPathComponent("Scorpena.dmg")
        try? fm.removeItem(at: destination)

        let delegate = DownloadDelegate(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    // MARK: Unpack + verify (blocking — call off the main thread)

    static func prepare(dmg: URL, currentVersion: String) throws -> URL {
        let fm = FileManager.default
        let mount = updateDir.appendingPathComponent("mnt", isDirectory: true)
        try? fm.removeItem(at: mount)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        guard run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noverify", "-noautoopen",
                                       "-readonly", "-mountpoint", mount.path]) == 0
        else { throw Failure(message: unpackMessage) }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? fm.removeItem(at: mount)
        }

        let source = mount.appendingPathComponent("Scorpena.app")
        guard fm.fileExists(atPath: source.path) else {
            throw Failure(message: unpackMessage)
        }
        try? fm.removeItem(at: stagingURL)
        guard run("/usr/bin/ditto", [source.path, stagingURL.path]) == 0 else {
            try? fm.removeItem(at: stagingURL)
            throw Failure(message: unpackMessage)
        }
        do {
            try verify(stagingURL, newerThan: currentVersion)
        } catch {
            try? fm.removeItem(at: stagingURL)
            throw error
        }
        return stagingURL
    }

    private static func verify(_ app: URL, newerThan current: String) throws {
        let bad = Failure(message: tr("Скачанный файл повреждён или не подходит к этому приложению."))
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let id = info?["CFBundleIdentifier"] as? String, id == Bundle.main.bundleIdentifier,
              let version = info?["CFBundleShortVersionString"] as? String,
              UpdateChecker.isNewer(version, than: current)
        else { throw bad }

        let fm = FileManager.default
        for relative in ["Contents/MacOS/VideoDownloader", "Contents/Resources/bin/yt-dlp",
                         "Contents/Resources/bin/ffmpeg", "Contents/Resources/bin/deno"] {
            guard fm.isExecutableFile(atPath: app.appendingPathComponent(relative).path) else { throw bad }
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { throw bad }
    }

    // MARK: Swap + relaunch

    /// Starts the helper that waits for this process to exit, swaps the app in
    /// place, relaunches it, and restores the old copy if the new one doesn't
    /// stay running. The caller must quit the app right after this returns.
    static func launchInstaller(staged: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)
        let script = updateDir.appendingPathComponent("install.sh")
        try installScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        // 3.0 renamed the app: swap it in under the new name when that's free.
        let renamed = currentAppURL.deletingLastPathComponent().appendingPathComponent("Scorpena.app")
        let final = (currentAppURL.lastPathComponent != "Scorpena.app" && !fm.fileExists(atPath: renamed.path))
            ? renamed : currentAppURL

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, currentAppURL.path, staged.path, String(getpid()),
                             supportDir.appendingPathComponent("app-update.log").path, final.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static let installScript = """
    #!/bin/sh
    APP="$1"; NEW="$2"; PID="$3"; LOG="$4"; FINAL="${5:-$1}"
    log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

    i=0
    while kill -0 "$PID" 2>/dev/null; do
        i=$((i+1))
        if [ "$i" -gt 100 ]; then log "app did not quit, giving up"; rm -rf "$NEW"; exit 1; fi
        sleep 0.3
    done

    OLD="${APP}.previous"
    rm -rf "$OLD"
    if ! mv "$APP" "$OLD"; then
        log "could not move the old app aside"; rm -rf "$NEW"; open "$APP"; exit 1
    fi
    if ! mv "$NEW" "$FINAL"; then
        log "could not move the new app into place, restoring"; mv "$OLD" "$APP"; open "$APP"; exit 1
    fi
    xattr -cr "$FINAL" 2>/dev/null
    log "installed as $FINAL, launching"
    open "$FINAL"

    sleep 10
    if pgrep -f "$FINAL/Contents/MacOS/" >/dev/null; then
        rm -rf "$OLD"
        log "new version is running, old copy removed"
    else
        log "new version did not stay running, restoring the previous one"
        rm -rf "$FINAL"
        mv "$OLD" "$APP"
        open "$APP"
    fi
    """

    /// Renames the installed `VideoDownloader.app` to its new name: a helper
    /// waits for this process to exit, renames the folder, relaunches, and
    /// puts the old name back if the renamed app doesn't stay running.
    static func launchRenamer(to newURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: updateDir, withIntermediateDirectories: true)
        let script = updateDir.appendingPathComponent("rename.sh")
        try renameScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, currentAppURL.path, newURL.path, String(getpid()),
                             supportDir.appendingPathComponent("app-update.log").path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    /// Set while an older version's update helper is still checking that this
    /// build stays running (it removes the `.previous` copy when satisfied).
    static var olderHelperStillWatching: Bool {
        FileManager.default.fileExists(atPath: currentAppURL.path + ".previous")
    }

    private static let renameScript = """
    #!/bin/sh
    OLD="$1"; NEW="$2"; PID="$3"; LOG="$4"
    log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >> "$LOG"; }

    i=0
    while kill -0 "$PID" 2>/dev/null; do
        i=$((i+1))
        if [ "$i" -gt 100 ]; then log "rename: app did not quit, giving up"; exit 1; fi
        sleep 0.3
    done

    if ! mv "$OLD" "$NEW"; then
        log "rename: could not rename, relaunching under the old name"; open "$OLD"; exit 1
    fi
    log "renamed to $NEW, launching"
    open "$NEW"

    sleep 8
    if pgrep -f "$NEW/Contents/MacOS/" >/dev/null; then
        log "renamed app is running"
    else
        log "renamed app did not stay running, restoring the old name"
        mv "$NEW" "$OLD"
        open "$OLD"
    fi
    """

    // MARK: Helpers

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    private var finished = false

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            finish(.failure(AppInstaller.Failure(
                message: trf("GitHub не отдал файл обновления (код %d). Попробуй позже или скачай вручную.", code))))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
