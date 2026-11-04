import AppKit
import SwiftUI

/// Shown when the app is closed while something is downloading or waiting.
/// The queue is saved, so nothing is lost — but the downloads stop until the next launch.
final class QuitWarningPanel {
    static let shared = QuitWarningPanel()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var answered = false

    /// True when there is something unfinished worth warning about.
    var needsWarning: Bool {
        let queue = DownloadQueue.shared
        return queue.busyCount > 0 || !queue.items.isEmpty
    }

    func ask(onAnswer: @escaping (_ quit: Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        window?.close()
        answered = false

        func finish(_ quit: Bool) {
            guard !answered else { return }
            answered = true
            window?.close()
            onAnswer(quit)
        }

        let win = makeDialogWindow(QuitWarningView(onChoose: finish))
        win.makeKeyAndOrderFront(nil)
        window = win

        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in finish(false) }
    }
}

private struct QuitWarningView: View {
    let onChoose: (Bool) -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        DialogLayout(title: tr("Идёт скачивание"),
                     message: tr("Если закрыть программу сейчас, скачивание остановится. Оно продолжится, когда ты откроешь программу снова.")) {
            DialogButton(title: tr("Всё равно закрыть")) { onChoose(true) }
            DialogButton(title: tr("Остаться"), primary: true) { onChoose(false) }
        }
    }
}
