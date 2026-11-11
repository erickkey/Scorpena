import SwiftUI
import Combine

@main
struct ScorpenaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 560, idealWidth: 640, minHeight: 280, idealHeight: 590)
        }
        .windowResizability(.contentMinSize)
        .commands { AppMenuCommands() }
    }
}

/// Standard items this app has no use for.
struct RemovedMenuItems: Commands {
    var body: some Commands {
        CommandGroup(replacing: .systemServices) {}
        CommandGroup(replacing: .appVisibility) {}
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .saveItem) {}
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {}
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .windowArrangement) {}
        CommandGroup(replacing: .help) {}
    }
}

/// The menu bar holds only what this app really has: Scorpena (About, Quit), Advanced, Downloads
/// (queue, history), Clip, Help (what's new, feedback, legal) and Support. Everything else macOS
/// adds (Edit, View, Window, Services, Hide…) is removed; titles follow the language chosen in the app.
struct AppMenuCommands: Commands {
    @ObservedObject private var language = LanguageSettings.shared

    var body: some Commands {
        RemovedMenuItems()
        CommandGroup(replacing: .appInfo) {
            Button(tr("О программе")) { InfoPanel.about.show() }
        }
        CommandMenu(tr("Дополнительно")) {
            Button(tr("Дополнительно")) { AdvancedSettingsPanel.shared.show() }
                .keyboardShortcut(",")
        }
        CommandMenu(tr("Загрузки")) {
            Button(tr("Очередь")) { NotificationCenter.default.post(name: .scorpenaOpenQueue, object: nil) }
                .keyboardShortcut("j")
            Button(tr("История")) { NotificationCenter.default.post(name: .scorpenaOpenHistory, object: nil) }
                .keyboardShortcut("y")
        }
        CommandMenu(tr("Вырезать фрагмент")) {
            Button(tr("Вырезать фрагмент")) { NotificationCenter.default.post(name: .scorpenaOpenTrim, object: nil) }
                .keyboardShortcut("t")
        }
        CommandMenu(tr("Справка")) {
            Button(tr("Что нового")) {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    WhatsNewPanel.shared.show(version: version, closeTitle: tr("Закрыть"), onAcknowledge: {})
                }
            }
            Button(tr("Обратная связь")) { InfoPanel.feedback.show() }
            Button(tr("Правовая информация")) { InfoPanel.legal.show() }
        }
        CommandMenu(tr("Поддержать")) {
            Button(tr("Поддержать")) { DonateLink.open() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// This is a single-window utility app — closing that window (the red
    /// traffic light) should quit the app like Calculator or Preview do,
    /// not leave it running with no visible window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No tabs, and none of the system's extra Edit items (dictation, emoji) in the menu bar.
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledAutoFillMenuItem")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftUI builds its menus a moment after launch, so the clean-up repeats a few times.
        // (Autofill, for instance, is added only once a text field gets focus.)
        // macOS fills Edit in when a menu is opened, so it is trimmed again right then.
        menuTracking = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { _ in
            Self.tidyMenus()
            DispatchQueue.main.async { Self.tidyMenus() }
        }
        menuTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in Self.tidyMenus() }
        menuCleanup = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in Self.tidyMenus() }
        ToolAutoUpdater.recoverInterruptedSwap()
        DiagnosticReporter.reportPreviousCrashIfAny()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { DiagnosticReporter.checkBundledTools() }
        installEscapeToClose()
        // Windows that are open when the language is changed get their titles in the new language too.
        languageTitles = LanguageSettings.shared.$language.dropFirst().sink { _ in
            DispatchQueue.main.async { NSApp.windows.forEach { $0.refreshLocalizedTitle() } }
        }
    }

    private var languageTitles: AnyCancellable?
    private var menuCleanup: Any?
    private var menuTimer: Timer?
    private var menuTracking: Any?

    /// Keeps the app menu and our own menus; removes anything else macOS or SwiftUI puts in the bar
    /// (Edit, View, Window, an empty system Help…). Runs repeatedly because some of it appears late.
    private static func tidyMenus() {
        guard let menu = NSApp.mainMenu else { return }
        NSApp.helpMenu = nil   // no search field in Help
        let ours = [tr("Дополнительно"), tr("Загрузки"), tr("Вырезать фрагмент"), tr("Справка"), tr("Поддержать")]
        for item in menu.items.dropFirst() {
            guard let sub = item.submenu else { continue }
            let real = sub.items.filter { !$0.isSeparatorItem && !$0.isHidden }
            if real.isEmpty || !ours.contains(item.title) { menu.removeItem(item) }
        }
        if let app = menu.items.first?.submenu {
            for alt in app.items where alt.isAlternate { app.removeItem(alt) }   // «Quit and keep windows»
        }
    }

    private var escapeMonitor: Any?

    /// Esc closes every window the app opens by itself (downloads, clip, settings, questions…) —
    /// but not the main window (a SwiftUI window of its own class), not windows without a close
    /// button (the language choice must be answered), and not while text is being composed.
    /// Question windows treat closing as their «cancel», so nothing is left hanging.
    private func installEscapeToClose() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Copy, paste & co. lived in the Edit menu, which is gone: the keys go straight to the text field.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
               !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control),
               NSApp.keyWindow?.firstResponder is NSTextView {
                // By key position, not by letter: with the Russian layout «V» is «М».
                let shift = event.modifierFlags.contains(.shift)
                let action: Selector? = switch (event.keyCode, shift) {
                case (8, false): NSSelectorFromString("copy:")
                case (9, false): NSSelectorFromString("paste:")
                case (7, false): NSSelectorFromString("cut:")
                case (0, false): NSSelectorFromString("selectAll:")
                case (6, false): NSSelectorFromString("undo:")
                case (6, true): NSSelectorFromString("redo:")
                default: nil
                }
                if let action, NSApp.sendAction(action, to: nil, from: nil) { return nil }
            }
            // The menu's own keys, by key position too, so they work on every layout.
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                switch event.keyCode {
                case 38: NotificationCenter.default.post(name: .scorpenaOpenQueue, object: nil); return nil     // J
                case 16: NotificationCenter.default.post(name: .scorpenaOpenHistory, object: nil); return nil   // Y
                case 17: NotificationCenter.default.post(name: .scorpenaOpenTrim, object: nil); return nil      // T
                case 43: AdvancedSettingsPanel.shared.show(); return nil                                        // ,
                default: break
                }
            }
            // ⌘W still closes the window although the Window menu is gone.
            if event.keyCode == 13, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               let window = event.window ?? NSApp.keyWindow, window.styleMask.contains(.closable) {
                window.performClose(nil)
                return nil
            }
            guard event.keyCode == 53,
                  let window = event.window ?? NSApp.keyWindow,
                  type(of: window) == NSWindow.self,
                  window.styleMask.contains(.closable),
                  NSApp.modalWindow == nil else { return event }
            if let text = window.firstResponder as? NSTextView, text.hasMarkedText() { return event }
            window.performClose(nil)
            return nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard QuitWarningPanel.shared.needsWarning else { return .terminateNow }
        QuitWarningPanel.shared.ask { quit in
            NSApp.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
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
