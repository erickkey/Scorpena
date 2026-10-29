import Foundation
import AppKit
import Combine
import SwiftUI

struct HistoryItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var url: String
    var title: String?
    var thumbnailFile: String?
    var audioOnly: Bool
    var date: Date
    /// Set for a whole playlist: how many of its videos were downloaded.
    var playlistCount: Int? = nil

    var isPlaylist: Bool { playlistCount != nil }
}

/// Finished downloads, kept across launches (a JSON file plus small JPEG
/// previews in Application Support) and shown by day. Nothing is dropped
/// automatically; when a day gets past `dayLimit` entries the window offers to
/// clear it. A whole playlist is ONE entry.
final class DownloadHistory: ObservableObject {
    static let shared = DownloadHistory()
    /// A day with more entries than this gets a «clear it» notice.
    static let dayLimit = 100

    @Published private(set) var items: [HistoryItem] = []

    private let dir: URL
    private var storeURL: URL { dir.appendingPathComponent("history.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("VideoDownloader/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        prune()
    }

    func thumbnailURL(for item: HistoryItem) -> URL? {
        item.thumbnailFile.map { dir.appendingPathComponent($0) }
    }

    /// Call on the main thread right after a download finishes successfully.
    func record(url: String, audioOnly: Bool, ytDlp: String?, cookieArgs: [String]) {
        let previous = items.first { $0.url == url }
        items.removeAll { $0.url == url }
        let item = HistoryItem(url: url,
                               title: previous?.title,
                               thumbnailFile: previous?.thumbnailFile,
                               audioOnly: audioOnly,
                               date: Date())
        items.insert(item, at: 0)
        prune()

        if item.title == nil || item.thumbnailFile == nil, let ytDlp {
            fetchMetadata(for: item.id, url: url, ytDlp: ytDlp, cookieArgs: cookieArgs)
        }
    }

    /// One entry for a whole playlist (its link, name, cover and how many videos came down).
    func recordPlaylist(url: String, title: String?, count: Int, thumbnail: URL?) {
        items.removeAll { $0.url == url && $0.isPlaylist }
        let item = HistoryItem(url: url, title: title, thumbnailFile: nil, audioOnly: false,
                               date: Date(), playlistCount: count)
        items.insert(item, at: 0)
        prune()
        guard let thumbnail else { return }
        URLSession.shared.dataTask(with: URLRequest(url: thumbnail, timeoutInterval: 20)) { [weak self] data, _, _ in
            guard let data else { return }
            DispatchQueue.main.async { self?.storeThumbnail(data, for: item.id) }
        }.resume()
    }

    func clear() {
        items.removeAll()
        prune()
    }

    /// What entries older than `cutoff` would free: how many, and the size of their pictures.
    func staleSummary(olderThan cutoff: Date) -> (count: Int, bytes: Int64) {
        let old = items.filter { $0.date < cutoff }
        let bytes = old.compactMap { item -> Int64? in
            guard let url = thumbnailURL(for: item),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return Int64(size)
        }.reduce(0, +)
        return (old.count, bytes)
    }

    func removeEntries(olderThan cutoff: Date) {
        items.removeAll { $0.date < cutoff }
        prune()
    }

    /// Deletes preview files that no entry refers to any more.
    func prune() {
        save()
        let used = Set(items.compactMap(\.thumbnailFile))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in files where name.hasSuffix(".jpg") && !used.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Title + preview picture

    /// Asks yt-dlp for the title and thumbnail address of the link we just
    /// downloaded (same cookies that worked for the download), fetches the
    /// picture once and stores a small copy, so the history works offline.
    private func fetchMetadata(for id: UUID, url: String, ytDlp: String, cookieArgs: [String]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ytDlp)
            p.arguments = ["--no-warnings", "--no-playlist", "--skip-download",
                           "--print", "%(title)s", "--print", "%(thumbnail)s"]
                + DownloadManager.jsRuntimeArgs() + cookieArgs + [url]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = DownloadManager.toolSearchPath(ytDlp: ytDlp)
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)
            else { return }

            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let title = lines.first.flatMap { $0.isEmpty || $0 == "NA" ? nil : $0 }
            let thumbAddress = lines.count > 1 ? URL(string: lines[1]) : nil

            DispatchQueue.main.async { self?.apply(title: title, to: id) }

            guard let thumbAddress, thumbAddress.scheme?.hasPrefix("http") == true else { return }
            var request = URLRequest(url: thumbAddress)
            request.timeoutInterval = 20
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async { self?.storeThumbnail(data, for: id) }
            }.resume()
        }
    }

    private func apply(title: String?, to id: UUID) {
        guard let title, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = title
        save()
    }

    private func storeThumbnail(_ data: Data, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let jpeg = Self.smallJPEG(from: data)
        else { return }
        let name = "\(id.uuidString).jpg"
        guard (try? jpeg.write(to: dir.appendingPathComponent(name), options: .atomic)) != nil else { return }
        items[index].thumbnailFile = name
        save()
    }

    private static func smallJPEG(from data: Data, maxWidth: CGFloat = 320) -> Data? {
        guard let image = NSImage(data: data),
              let source = image.representations.first
        else { return nil }
        let width = CGFloat(source.pixelsWide > 0 ? source.pixelsWide : Int(image.size.width))
        let height = CGFloat(source.pixelsHigh > 0 ? source.pixelsHigh : Int(image.size.height))
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxWidth / width)
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}

struct HistoryView: View {
    var onPick: (String) -> Void
    var onClose: () -> Void

    @ObservedObject private var history = DownloadHistory.shared
    @ObservedObject private var languageSettings = LanguageSettings.shared

    @State private var confirmingClear = false
    @State private var collapsedDays: Set<Date> = []

    /// Entries grouped by day, newest day first.
    private var days: [(day: Date, items: [HistoryItem])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: history.items) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    private var locale: Locale {
        Locale(identifier: languageSettings.language == .en ? "en" : "ru")
    }

    /// «Сегодня», «Вчера», then «27 октября» (with the year for earlier years).
    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return tr("Сегодня") }
        if calendar.isDateInYesterday(day) { return tr("Вчера") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let format: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.wide)
            : .dateTime.day().month(.wide).year()
        return day.formatted(format.locale(locale))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    WindowTitleRow(title: tr("История скачиваний"))
                        .padding(.bottom, 6)
                    if history.items.isEmpty {
                        Text(tr("Пока нет скачиваний"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                            dayHeader(group.day, count: group.items.count, isFirst: index == 0)
                            if !collapsedDays.contains(group.day) {
                                ForEach(group.items) { item in row(item) }
                            }
                        }
                    }
                }
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 8, trailing: 24))
                .background(AlwaysVisibleScroller())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button(tr("Очистить историю")) { confirmingClear = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(history.items.isEmpty ? Color.secondary : Color.red)
                    .disabled(history.items.isEmpty)
                Spacer()
                Button(tr("Закрыть")) { onClose() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 16, trailing: 24))
        }
        .frame(width: 560, height: 540)
        .alert(tr("Очистить историю?"), isPresented: $confirmingClear) {
            Button(tr("Очистить"), role: .destructive) { history.clear() }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Список будет удалён. Скачанные файлы не затрагиваются."))
        }
    }

    private func dayHeader(_ day: Date, count: Int, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
            Button {
                if collapsedDays.contains(day) { collapsedDays.remove(day) } else { collapsedDays.insert(day) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: collapsedDays.contains(day) ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text(dayTitle(day)).font(.subheadline.weight(.semibold))
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
                if isFirst {
                    let allCollapsed = collapsedDays.count >= days.count
                    Button(allCollapsed ? tr("Развернуть все") : tr("Свернуть все")) {
                        collapsedDays = allCollapsed ? [] : Set(days.map(\.day))
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if count > DownloadHistory.dayLimit {
                Text(tr("За этот день больше 100 записей. Можно очистить."))
                    .font(.caption)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.5)))
            }
        }
        .padding(.top, 10)
    }

    private func row(_ item: HistoryItem) -> some View {
        Button { onPick(item.url) } label: {
            HStack(spacing: 12) {
                thumbnail(item)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: item.isPlaylist ? "list.bullet.rectangle" : (item.audioOnly ? "music.note" : "film"))
                        if let count = item.playlistCount {
                            Text(trf("Плейлист · %d видео", count))
                        } else {
                            Text(item.audioOnly ? tr("Звук") : tr("Видео"))
                        }
                        Text("·")
                        Text(item.date.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    Text(item.title ?? URL(string: item.url)?.host ?? item.url)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ item: HistoryItem) -> some View {
        Group {
            if !item.isPlaylist, let url = history.thumbnailURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                if let url = Bundle.main.url(forResource: "HistoryPlaceholder", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
