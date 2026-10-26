import SwiftUI

@main
struct YouTubeDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, idealWidth: 790, minHeight: 380, idealHeight: 590)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// This is a single-window utility app — closing that window (the red
    /// traffic light) should quit the app like Calculator or Preview do,
    /// not leave it running with no visible window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ToolAutoUpdater.recoverInterruptedSwap()
        DiagnosticReporter.reportPreviousCrashIfAny()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { DiagnosticReporter.checkBundledTools() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DownloadHistory.shared.prune()
    }

    /// Refuses macOS's own window-state restoration outright, at the
    /// earliest possible point (before any window — including the main
    /// one — is even created). Without this, a previous run's saved state
    /// (e.g. after a force-quit during development, or just an ordinary
    /// quit from an earlier version) can leave AppKit trying to restore
    /// stale window state on the next launch; that was caught directly
    /// causing two different failures on this exact app: the main window
    /// occasionally not appearing at all, and — more often — the language
    /// picker and "what's new" windows being created and self-reporting
    /// as visible/key, yet never actually composited on screen. Both
    /// vanished once stale saved state was cleared, so this stops AppKit
    /// from ever consulting it in the first place.
    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }
}
