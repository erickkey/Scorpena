import SwiftUI
import AppKit

/// One alert-style window for the whole in-app update: the question, then the
/// progress (downloading → checking → installing), and — after the app has
/// restarted into the new version — the result. Same window, same look.
@MainActor
final class UpdatePanel: ObservableObject {
    static let shared = UpdatePanel()

    enum Phase: Equatable {
        case confirm(String)            // new version number
        case downloadRunning            // a video download is in progress
        case downloading(Double)
        case verifying
        case installing
        case finished(String)           // version now installed
        case rolledBack
        case failed(String)
        case renamed(canRename: Bool)   // 3.0: the app has a new name
        case renaming
    }

    @Published private(set) var phase: Phase = .confirm("")
    var onConfirm: () -> Void = {}
    var onClosed: () -> Void = {}

    private var window: NSWindow?

    func show(_ phase: Phase, onClosed: @escaping () -> Void = {}) {
        self.phase = phase
        if let window, window.isVisible {
            self.onClosed = onClosed
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.onClosed = onClosed
        NSApp.activate(ignoringOtherApps: true)
        let hosting = NSHostingController(rootView: UpdatePanelView(panel: self))
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled]          // no ✕: buttons decide, and it can't be closed mid-update
        win.title = "Scorpena – video downloader"
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(NSSize(width: 470, height: 180))
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
    }

    func update(_ phase: Phase) { self.phase = phase }

    /// One-time notice that the app is now called Scorpena. When the file on
    /// disk can be renamed, the button does that too (and restarts once).
    func showRenameNotice(canRename: Bool, onClosed: @escaping () -> Void) {
        onConfirm = { [weak self] in self?.acknowledgeRename(canRename: canRename) }
        show(.renamed(canRename: canRename), onClosed: onClosed)
    }

    private func acknowledgeRename(canRename: Bool) {
        let defaults = UserDefaults.standard
        guard canRename else {
            defaults.set(true, forKey: AppRenamer.noticeKey)
            close()
            return
        }
        update(.renaming)
        Task {
            if await AppRenamer.startRename() {
                defaults.set(true, forKey: AppRenamer.noticeKey)
                defaults.synchronize()
                NSApp.terminate(nil)
            } else {
                close()   // not now — the notice comes back next launch
            }
        }
    }

    func close() {
        window?.close()
        window = nil
        let callback = onClosed
        onClosed = {}
        callback()
    }

    fileprivate func confirm() { onConfirm() }
    fileprivate func openDownloadPage() {
        NSWorkspace.shared.open(AppInstaller.downloadURL)
        close()
    }
}

private struct UpdatePanelView: View {
    @ObservedObject var panel: UpdatePanel
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    progress
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Spacer()
                buttons
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 470)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var progress: some View {
        switch panel.phase {
        case .downloading(let fraction):
            ProgressView(value: fraction).progressViewStyle(.linear)
        case .verifying, .installing, .renaming:
            ProgressView().progressViewStyle(.linear)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var buttons: some View {
        switch panel.phase {
        case .confirm:
            Button(tr("Позже")) { panel.close() }
                .buttonStyle(SoftPillStyle())
            Button(tr("Обновить")) { panel.confirm() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        case .downloadRunning:
            Button(tr("Понятно")) { panel.close() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        case .finished:
            Button(tr("Отлично")) { panel.close() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        case .rolledBack, .failed:
            Button(tr("Закрыть")) { panel.close() }
                .buttonStyle(SoftPillStyle())
            Button(tr("Скачать вручную")) { panel.openDownloadPage() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        case .renamed:
            Button(tr("Ладно")) { panel.confirm() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
        case .downloading, .verifying, .installing, .renaming:
            EmptyView()
        }
    }

    private var title: String {
        switch panel.phase {
        case .confirm(let version):  return trf("Вышла новая версия %@", version)
        case .downloadRunning:       return tr("Сейчас идёт скачивание")
        case .downloading:           return tr("Загружаю новую версию…")
        case .verifying:             return tr("Проверяю загрузку…")
        case .installing:            return tr("Ставлю обновление…")
        case .finished(let version): return trf("Готово! Теперь у тебя версия %@ ✅", version)
        case .rolledBack, .failed:   return tr("Обновиться не получилось")
        case .renamed:               return tr("Программа переименована")
        case .renaming:              return tr("Переименовываю…")
        }
    }

    private var detail: String {
        switch panel.phase {
        case .confirm:
            return tr("Обновимся прямо сейчас? Займёт около минуты, программа сама перезапустится. Настройки и история сохранятся.")
        case .downloadRunning:
            return tr("Дождись окончания скачивания и нажми кнопку обновления ещё раз.")
        case .downloading(let fraction):
            return "\(Int(fraction * 100))%"
        case .verifying:
            return tr("Убеждаюсь, что всё скачалось без повреждений.")
        case .installing:
            return tr("Сейчас программа перезапустится.")
        case .finished:
            return ""
        case .rolledBack:
            return tr("Новая версия не запустилась, поэтому вернули прежнюю. Ничего не сломалось — можно скачать новую вручную.")
        case .failed(let reason):
            return reason + "\n" + tr("Ничего не сломалось: осталась прежняя версия.")
        case .renamed(let canRename):
            return canRename
                ? tr("Теперь она называется Scorpena – video downloader. Настройки и история на месте. Программа один раз перезапустится. Если рядом осталась старая копия, её можно удалить.")
                : tr("Теперь она называется Scorpena – video downloader. Настройки и история на месте. Если рядом осталась старая копия, её можно удалить.")
        case .renaming:
            return tr("Секунду, сейчас программа перезапустится.")
        }
    }
}
