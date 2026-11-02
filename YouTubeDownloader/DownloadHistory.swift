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
    /// Where the finished file went, and the choices it was made with (format, quality,
    /// no-audio, clip): the same link with the same choices is «already downloaded».
    var filePath: String? = nil
    var settingsKey: String? = nil
    /// Length of the video in seconds (of the clip, for a clip).
    var duration: Double? = nil
    /// Size of the finished file in bytes.
    var fileSize: Int64? = nil

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
    func record(url: String, audioOnly: Bool, ytDlp: String?, cookieArgs: [String],
                filePath: String? = nil, settingsKey: String? = nil, clipLength: Double? = nil, fileSize: Int64? = nil) {
        // Same link: the new entry replaces the old one, unless the old one is a different file
        // (another clip, another format) — that one stays.
        func isSame(_ old: HistoryItem) -> Bool {
            old.url == url && !old.isPlaylist && (old.settingsKey == nil || settingsKey == nil || old.settingsKey == settingsKey)
        }
        let previous = items.first(where: isSame) ?? items.first { $0.url == url }
        items.removeAll(where: isSame)
        var item = HistoryItem(url: url,
                               title: previous?.title,
                               thumbnailFile: previous?.thumbnailFile,
                               audioOnly: audioOnly,
                               date: Date())
        item.filePath = filePath
        item.settingsKey = settingsKey
        item.fileSize = fileSize
        item.duration = clipLength ?? (previous?.settingsKey == nil || previous?.settingsKey == settingsKey ? previous?.duration : nil)
        items.insert(item, at: 0)
        prune()

        if item.title == nil || item.thumbnailFile == nil || item.duration == nil, let ytDlp {
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

    /// Where the file of an entry is now. Entries made before the path was kept are looked for by
    /// their title in the folder the downloads go to (and then remembered).
    func fileURL(for item: HistoryItem) -> URL? {
        let fm = FileManager.default
        if let path = item.filePath, fm.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        guard !item.isPlaylist, let title = item.title else { return nil }
        func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let wanted = plain(title)
        guard wanted.count >= 4 else { return nil }
        let folder = UserDefaults.standard.string(forKey: "destinationFolder")
            ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        let names = (try? fm.contentsOfDirectory(atPath: folder)) ?? []
        guard let name = names.first(where: { $0.contains("(Scorpena video downloader)") && plain($0).contains(wanted) }) else { return nil }
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].filePath = url.path; save() }
        return url
    }

    /// The file of an earlier download of this link with the same choices, if it is still there.
    func existingFile(url: String, settingsKey: String) -> URL? {
        let wanted = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for item in items where item.settingsKey == settingsKey
            && item.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted {
            if let path = item.filePath, FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// One entry out of the list.
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        prune()
    }

    /// Everything from one day.
    func removeDay(_ day: Date) {
        let calendar = Calendar.current
        items.removeAll { calendar.isDate($0.date, inSameDayAs: day) }
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
                           "--print", "%(title)s", "--print", "%(thumbnail)s", "--print", "%(duration)s"]
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
            let seconds = lines.count > 2 ? Double(lines[2]) : nil

            DispatchQueue.main.async { self?.apply(title: title, duration: seconds, to: id) }

            guard let thumbAddress, thumbAddress.scheme?.hasPrefix("http") == true else { return }
            var request = URLRequest(url: thumbAddress)
            request.timeoutInterval = 20
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data else { return }
                DispatchQueue.main.async { self?.storeThumbnail(data, for: id) }
            }.resume()
        }
    }

    private func apply(title: String?, duration: Double?, to id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let title { items[index].title = title }
        // A clip keeps its own length; a whole video gets the length the site reports.
        if let duration, items[index].duration == nil { items[index].duration = duration }
        save()
    }

    /// Entries made before lengths were kept get theirs, a few at a time, one after another.
    func fillMissingDurations(ytDlp: String?) {
        guard let ytDlp, !backfilling else { return }
        let missing = items.filter { $0.duration == nil && !$0.isPlaylist }.prefix(12).map { ($0.id, $0.url) }
        guard !missing.isEmpty else { return }
        backfilling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (id, url) in missing {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ytDlp)
                p.arguments = ["--no-warnings", "--no-playlist", "--skip-download", "--print", "%(duration)s"]
                    + DownloadManager.jsRuntimeArgs() + [url]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = DownloadManager.toolSearchPath(ytDlp: ytDlp)
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { continue }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
                      let seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                DispatchQueue.main.async { self?.apply(title: nil, duration: seconds, to: id) }
            }
            DispatchQueue.main.async { self?.backfilling = false }
        }
    }
    private var backfilling = false

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
    @State private var dayToClear: Date?
    @State private var hoveredItem: UUID?
    @State private var hoveredDay: Date?
    @State private var missingItem: UUID?
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
            .frame(maxHeight: .infinity, alignment: .top)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(tr("Очистить историю?"), isPresented: $confirmingClear) {
            Button(tr("Очистить"), role: .destructive) { history.clear() }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Список будет удалён. Скачанные файлы не затрагиваются."))
        }
        .alert(trf("Очистить записи за %@?", dayToClear.map { dayTitle($0).lowercased() } ?? ""),
               isPresented: Binding(get: { dayToClear != nil }, set: { if !$0 { dayToClear = nil } })) {
            Button(tr("Очистить"), role: .destructive) {
                if let day = dayToClear { history.removeDay(day) }
                dayToClear = nil
            }
            Button(tr("Отмена"), role: .cancel) { dayToClear = nil }
        } message: {
            Text(trf("Записи за %@ будут удалены из списка. Скачанные файлы не затрагиваются.",
                     dayToClear.map { dayTitle($0).lowercased() } ?? ""))
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
                Button { dayToClear = day } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Like the cross on an entry: only while the pointer is over this day.
                .opacity(hoveredDay == day ? 1 : 0)
                .allowsHitTesting(hoveredDay == day)
                .help(trf("Очистить записи за %@", dayTitle(day).lowercased()))
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
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hoveredDay = day } else if hoveredDay == day { hoveredDay = nil }
            }
        }
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
                        if let size = item.fileSize, size > 0 {
                            Text("·")
                            Text(ContentView.formatBytes(size))
                        }
                        if missingItem == item.id {
                            Text("·")
                            Text(tr("Файл не найден")).foregroundStyle(.red)
                        }
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
        .overlay(alignment: .topTrailing) {
            if hoveredItem == item.id {
                HStack(spacing: 6) {
                    // Show the file in Finder (or say that it isn't there any more).
                    Button {
                        if FileReveal.show(history.fileURL(for: item)) {
                            missingItem = nil
                        } else {
                            missingItem = item.id
                            let id = item.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if missingItem == id { missingItem = nil } }
                        }
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Показать в папке"))
                    Button { history.remove(id: item.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.primary.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(tr("Удалить из истории"))
                }
                .padding(8)
                .transition(.opacity)
            } else {
                Text(item.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.top, 11)
                    .padding(.trailing, 14)
                    .allowsHitTesting(false)
            }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside { hoveredItem = item.id } else if hoveredItem == item.id { hoveredItem = nil }
            }
        }
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
        // The length of the video, in the corner of the cover (not next to the time it was downloaded).
        .overlay(alignment: .bottomTrailing) {
            if !item.isPlaylist, let seconds = item.duration, seconds > 0 {
                Text(ClipSection.clock(seconds))
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72)))
                    .padding(4)
            }
        }
    }
}
