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
}

/// The last 20 finished downloads, kept across launches (a JSON file plus
/// small JPEG previews in Application Support). Only the newest 20 are ever
/// kept — older entries and their preview images are dropped on every add,
/// at launch and again on quit.
final class DownloadHistory: ObservableObject {
    static let shared = DownloadHistory()
    static let limit = 20

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

    func clear() {
        items.removeAll()
        prune()
    }

    /// Keeps only the newest `limit` entries and deletes preview files that
    /// no entry refers to any more.
    func prune() {
        if items.count > Self.limit { items = Array(items.prefix(Self.limit)) }
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

/// Own window (like «Дополнительно» / «Что нового»): newest download first;
/// clicking a row hands its link back and closes the window.
final class HistoryPanel {
    static let shared = HistoryPanel()
    private var window: NSWindow?

    func show(onPick: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        window?.close()
        let hosting = NSHostingController(
            rootView: HistoryView(
                onPick: { [weak self] url in
                    self?.window?.close()
                    onPick(url)
                },
                onClose: { [weak self] in self?.window?.close() })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = tr("История скачиваний")
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(NSSize(width: 540, height: 580))
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

struct HistoryView: View {
    var onPick: (String) -> Void
    var onClose: () -> Void

    @ObservedObject private var history = DownloadHistory.shared
    @ObservedObject private var languageSettings = LanguageSettings.shared

    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                    if history.items.isEmpty {
                        Text(tr("Пока нет скачиваний"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(history.items) { item in row(item) }
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(tr("Очистить историю")) { confirmingClear = true }
                    .buttonStyle(.link)
                    .foregroundStyle(history.items.isEmpty ? Color.secondary : Color.red)
                    .disabled(history.items.isEmpty)
                Spacer()
                Button(tr("Закрыть")) { onClose() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
            .padding(14)
        }
        .frame(width: 540, height: 580)
        .alert(tr("Очистить историю?"), isPresented: $confirmingClear) {
            Button(tr("Очистить"), role: .destructive) { history.clear() }
            Button(tr("Отмена"), role: .cancel) {}
        } message: {
            Text(tr("Список будет удалён. Скачанные файлы не затрагиваются."))
        }
    }

    private func row(_ item: HistoryItem) -> some View {
        Button { onPick(item.url) } label: {
            HStack(spacing: 12) {
                thumbnail(item)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title ?? URL(string: item.url)?.host ?? item.url)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Image(systemName: item.audioOnly ? "music.note" : "film")
                        Text(item.audioOnly ? tr("Звук") : tr("Видео"))
                        Text("·")
                        Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func thumbnail(_ item: HistoryItem) -> some View {
        Group {
            if let url = history.thumbnailURL(for: item), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.2)
                    Image(systemName: item.audioOnly ? "music.note" : "film")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 96, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
