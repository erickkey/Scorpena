import AppKit

/// Version 3.0 renamed the app from VideoDownloader to Scorpena. People who
/// updated from 2.x still have `VideoDownloader.app` on disk (the old updater
/// swaps the new build in under the old name), so the first launch tells them
/// about the new name once and renames the file itself.
enum AppRenamer {
    static let noticeKey = "renameNoticeAcknowledged"
    private static let oldName = "VideoDownloader.app"
    private static let newName = "Scorpena.app"
    private static let firstScorpenaVersion = "3.0"

    private static var runningUnderOldName: Bool {
        AppInstaller.currentAppURL.lastPathComponent == oldName
    }

    private static var newURL: URL {
        AppInstaller.currentAppURL.deletingLastPathComponent().appendingPathComponent(newName)
    }

    /// Existing users only: someone who came from a build older than 3.0, or
    /// whose copy still carries the old file name. A brand-new install has
    /// nothing to be told.
    static var shouldShowNotice: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: noticeKey) else { return false }
        if runningUnderOldName { return true }
        guard let last = defaults.string(forKey: "lastSeenChangelogVersion"), !last.isEmpty else { return false }
        return UpdateChecker.isNewer(firstScorpenaVersion, than: last)
    }

    /// The file can only be renamed where the app could also replace itself,
    /// and only when the new name isn't already taken in that folder.
    static var canRename: Bool {
        runningUnderOldName
            && AppInstaller.cannotReplaceSelfReason() == nil
            && !FileManager.default.fileExists(atPath: newURL.path)
    }

    /// Starts the rename helper. First waits (up to ~30 s) for the previous
    /// version's update helper to finish its "did the new build stay running?"
    /// check — quitting before then would make it roll the update back.
    /// Returns false when it isn't safe to rename right now.
    static func startRename() async -> Bool {
        var waited = 0
        while AppInstaller.olderHelperStillWatching && waited < 30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            waited += 1
        }
        guard !AppInstaller.olderHelperStillWatching else { return false }
        do {
            try AppInstaller.launchRenamer(to: newURL)
            return true
        } catch {
            return false
        }
    }
}
