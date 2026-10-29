import AppKit
import SwiftUI

/// At launch, as often as the user chose: if old history pictures and abandoned partial
/// downloads add up to a lot of space, offer to remove them.
enum Cleanup {
    private static let lastCheckKey = "lastCleanupCheck"
    private static let threshold: Int64 = 100_000_000
    /// What counts as old.
    private static let age: TimeInterval = 7 * 24 * 3600

    private static var cutoff: Date { Date().addingTimeInterval(-age) }

    /// Partial-download items not touched for a week, with their total size.
    /// Nothing is offered while downloads are waiting or running: their pieces are in use.
    private static func stalePartials() -> (urls: [URL], bytes: Int64) {
        let fm = FileManager.default
        var urls: [URL] = []
        var bytes: Int64 = 0
        let roots = [DownloadManager.partialDir, DownloadManager.partialDir.appendingPathComponent("temp", isDirectory: true)]
        for root in roots {
            let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for entry in entries where entry.lastPathComponent != "temp" {
                let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                guard date < cutoff else { continue }
                urls.append(entry)
                bytes += size(of: entry)
            }
        }
        return (urls, bytes)
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let file as URL in walker {
                total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return total
    }

    /// How often the offer comes (Дополнительно → «Напоминание об очистке»).
    enum Reminder: String, CaseIterable, Identifiable {
        case weekly, monthly, never
        static let key = "cleanupReminder"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .weekly: return tr("Раз в неделю")
            case .monthly: return tr("Раз в месяц")
            case .never: return tr("Никогда")
            }
        }
        var period: TimeInterval? {
            switch self {
            case .weekly: return 7 * 24 * 3600
            case .monthly: return 30 * 24 * 3600
            case .never: return nil
            }
        }
    }

    static func checkOnLaunch(queue: DownloadQueue) {
        let defaults = UserDefaults.standard
        let now = Date()
        let reminder = Reminder(rawValue: defaults.string(forKey: Reminder.key) ?? "") ?? .weekly
        guard let period = reminder.period else { return }
        guard let last = defaults.object(forKey: lastCheckKey) as? Date else {
            defaults.set(now, forKey: lastCheckKey)   // the first period is quiet
            return
        }
        guard now.timeIntervalSince(last) >= period else { return }
        defaults.set(now, forKey: lastCheckKey)
        offer(queue: queue, minimum: threshold) { _ in }
    }

    /// «Очистить сейчас»: asks regardless of size; says so (false) when there is nothing to remove.
    static func cleanNow(queue: DownloadQueue, completion: @escaping (Bool) -> Void) {
        offer(queue: queue, minimum: 1, completion: completion)
    }

    private static func offer(queue: DownloadQueue, minimum: Int64, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let idle = DispatchQueue.main.sync { queue.items.isEmpty && queue.busyCount == 0 }
            let partials = idle ? stalePartials() : (urls: [URL](), bytes: Int64(0))
            let history = DispatchQueue.main.sync { DownloadHistory.shared.staleSummary(olderThan: cutoff) }
            let total = partials.bytes + history.bytes
            let hasEntries = history.count > 0
            guard total >= minimum || (minimum == 1 && hasEntries) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            DispatchQueue.main.async {
                completion(true)
                CleanupPanel.shared.show(bytes: total) {
                    DownloadHistory.shared.removeEntries(olderThan: cutoff)
                    DispatchQueue.global(qos: .utility).async {
                        for url in partials.urls { try? FileManager.default.removeItem(at: url) }
                    }
                }
            }
        }
    }
}

final class CleanupPanel {
    static let shared = CleanupPanel()
    private var window: NSWindow?

    func show(bytes: Int64, onClean: @escaping () -> Void) {
        window?.close()
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        let win = makeDialogWindow(CleanupView(size: size, onLater: { [weak self] in
            self?.window?.close()
        }, onClean: { [weak self] in
            onClean()
            self?.window?.close()
        }))
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

private struct CleanupView: View {
    let size: String
    let onLater: () -> Void
    let onClean: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        DialogLayout(title: tr("Пора прибраться"),
                     message: trf("Старые записи истории и недокачанные видео занимают %@. Удалить их? Твои скачанные файлы останутся на месте.", size)) {
            DialogButton(title: tr("Позже"), action: onLater)
            DialogButton(title: tr("Почистить"), primary: true, action: onClean)
        }
    }
}
