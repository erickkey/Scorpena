import AppKit
import Combine
import SwiftUI

/// Which playlist a queued video came from (the history keeps the playlist as one entry).
struct PlaylistInfo {
    let id: UUID
    let title: String?
    let listURL: String
    let thumbnail: URL?
}

/// One link waiting for its turn, with the choices made when it was added.
struct QueuedDownload: Identifiable {
    let id = UUID()
    let url: String
    let destination: URL
    let maxHeight: Int?
    let audioOnly: Bool
    let stripAudio: Bool
    let videoFormat: VideoFormat
    let audioFormat: AudioFormat
    /// Set for videos taken from a playlist: the title and cover are already known.
    var knownTitle: String? = nil
    var thumbnail: URL? = nil
    var playlist: PlaylistInfo? = nil

    var title: String { URL(string: url)?.host ?? url }
    var formatLabel: String { audioOnly ? audioFormat.title : videoFormat.title }
}

/// Title and cover picture of a link, fetched from the site in the background.
struct LinkPreview {
    var title: String?
    var image: NSImage?
}

/// A line in the «Недавно завершённые» list (this session only).
struct FinishedDownload: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let url: String
    let succeeded: Bool
    let note: String
    let image: NSImage?
    let fileURL: URL?
}

/// A download that is running (or paused) on one of the engines.
struct RunningJob: Identifiable {
    let item: QueuedDownload
    let manager: DownloadManager
    var id: UUID { item.id }
}

/// Keeps the list of links and runs up to three of them at once. Each running
/// download has its own `DownloadManager`: the main window's one first, then
/// up to two extra ones created on demand. The rest wait their turn.
final class DownloadQueue: ObservableObject {
    static let shared = DownloadQueue()
    static let maxParallel = 3

    @Published private(set) var items: [QueuedDownload] = [] { didSet { save() } }
    @Published private(set) var running: [RunningJob] = [] { didSet { save() } }
    @Published private(set) var finished: [FinishedDownload] = []
    @Published private(set) var extras: [DownloadManager] = []
    @Published private(set) var previews: [UUID: LinkPreview] = [:]
    /// One «batch» = everything added since the queue was last empty; it drives
    /// the common progress bar on the main window.
    @Published private(set) var batchTotal = 0
    @Published private(set) var batchDone = 0

    /// Links brought back from the last session (so the old «unfinished» offer can stay quiet).
    private(set) var restoredURLs: Set<String> = []

    /// Playlists still in the queue and how many of their videos came through.
    private var playlistSucceeded: [UUID: Int] = [:]
    private var playlistInfo: [UUID: PlaylistInfo] = [:]
    /// Restored downloads that were on pause: they come back paused, not running.
    private var startPaused: Set<UUID> = []

    private weak var primary: DownloadManager?
    private var watchers: [AnyCancellable] = []

    var managers: [DownloadManager] { (primary.map { [$0] } ?? []) + extras }
    var busyCount: Int { managers.filter { $0.isRunning || $0.isPaused }.count }

    func attach(_ manager: DownloadManager) {
        guard primary == nil else { return }
        primary = manager
        watch(manager)
        restore()
        DispatchQueue.global(qos: .utility).async { DownloadManager.cleanOldPartials() }
    }

    // MARK: Saved between launches

    /// Everything still to do — what is running now comes first, then what waits.
    private struct SavedItem: Codable {
        var url: String
        var destination: String
        var maxHeight: Int?
        var audioOnly: Bool
        var stripAudio: Bool
        var videoFormat: String
        var audioFormat: String
        var knownTitle: String?
        var thumbnail: String?
        var playlistID: UUID?
        var playlistTitle: String?
        var playlistURL: String?
        var playlistThumbnail: String?
        var playlistDone: Int?   // videos of this playlist already finished before the save
        var paused: Bool?        // was on pause when saved
    }

    private static var storeURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("VideoDownloader/queue.json")
    }

    private func save() {
        let pending = running.map(\.item) + items
        let pausedIDs = Set(running.filter { $0.manager.isPaused }.map(\.item.id))
        let url = Self.storeURL
        guard !pending.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let saved = pending.map {
            SavedItem(url: $0.url, destination: $0.destination.path, maxHeight: $0.maxHeight,
                      audioOnly: $0.audioOnly, stripAudio: $0.stripAudio,
                      videoFormat: $0.videoFormat.rawValue, audioFormat: $0.audioFormat.rawValue,
                      knownTitle: $0.knownTitle, thumbnail: $0.thumbnail?.absoluteString,
                      playlistID: $0.playlist?.id, playlistTitle: $0.playlist?.title,
                      playlistURL: $0.playlist?.listURL, playlistThumbnail: $0.playlist?.thumbnail?.absoluteString,
                      playlistDone: $0.playlist.flatMap { playlistSucceeded[$0.id] },
                      paused: pausedIDs.contains($0.id))
        }
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url, options: .atomic) }
    }

    /// Picks the queue up where the last session left it; downloads carry on from their partial files.
    private func restore() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = try? JSONDecoder().decode([SavedItem].self, from: data), !saved.isEmpty else { return }
        let restored = saved.map { item in
            QueuedDownload(url: item.url, destination: URL(fileURLWithPath: item.destination, isDirectory: true),
                           maxHeight: item.maxHeight, audioOnly: item.audioOnly, stripAudio: item.stripAudio,
                           videoFormat: VideoFormat(rawValue: item.videoFormat) ?? .mp4,
                           audioFormat: AudioFormat(rawValue: item.audioFormat) ?? .mp3,
                           knownTitle: item.knownTitle, thumbnail: item.thumbnail.flatMap(URL.init(string:)),
                           playlist: item.playlistID.map { id in
                               PlaylistInfo(id: id, title: item.playlistTitle, listURL: item.playlistURL ?? "",
                                            thumbnail: item.playlistThumbnail.flatMap(URL.init(string:)))
                           })
        }
        for item in saved {
            if let id = item.playlistID, let done = item.playlistDone, done > 0 {
                playlistSucceeded[id] = max(playlistSucceeded[id] ?? 0, done)
            }
        }
        for (item, was) in zip(restored, saved) where was.paused == true { startPaused.insert(item.id) }
        restoredURLs = Set(restored.map(\.url))
        // A beat after launch, so the start-up windows come first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.submit(restored)
        }
    }

    private func watch(_ manager: DownloadManager) {
        manager.speedShare = { [weak self] engine in
            guard let self else { return 1 }
            return self.managers.filter { $0.isRunning || $0 === engine }.count
        }
        watchers.append(manager.$phase.sink { [weak self, weak manager] phase in
            guard let manager else { return }
            self?.phaseChanged(manager, phase)
        })
    }

    /// Starts the download right away when there is a free slot, otherwise queues it.
    func submit(_ item: QueuedDownload) {
        submit([item])
    }

    /// The same link, as video or as audio, that is already downloading or waiting.
    /// Two of those at once would fight over the same partial files.
    func isActive(url: String, audioOnly: Bool) -> Bool {
        let wanted = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func same(_ item: QueuedDownload) -> Bool {
            item.audioOnly == audioOnly && item.url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
        return items.contains(where: same) || running.contains { same($0.item) }
    }

    func submit(_ newItems: [QueuedDownload]) {
        let newItems = newItems.filter { !isActive(url: $0.url, audioOnly: $0.audioOnly) }
        guard !newItems.isEmpty else { return }
        if busyCount == 0 && items.isEmpty {
            batchTotal = 0
            batchDone = 0
        }
        batchTotal += newItems.count
        for item in newItems {
            if let playlist = item.playlist { playlistInfo[playlist.id] = playlist }
        }
        items.append(contentsOf: newItems)
        for item in newItems {
            if let title = item.knownTitle {
                previews[item.id] = LinkPreview(title: title, image: nil)   // the picture loads when its card comes into view
            } else {
                fetchPreview(for: item)
            }
        }
        startWhilePossible()
    }

    /// Fetches a playlist video's cover once its card is about to be shown.
    func loadThumbnailIfNeeded(_ item: QueuedDownload) {
        guard let thumbnail = item.thumbnail, previews[item.id]?.image == nil,
              !imageRequested.contains(item.id) else { return }
        imageRequested.insert(item.id)
        loadImage(thumbnail, for: item.id)
    }

    private var imageRequested: Set<UUID> = []

    private func loadImage(_ address: URL, for id: UUID) {
        URLSession.shared.dataTask(with: URLRequest(url: address, timeoutInterval: 20)) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.previews[id] != nil else { return }
                self.previews[id]?.image = image
            }
        }.resume()
    }

    /// Asks the site for the title and cover picture, so the queue can show
    /// each download as a card with its own picture.
    private func fetchPreview(for item: QueuedDownload) {
        guard let ytDlp = primary?.ytDlpPath else { return }
        let cookieSets = DownloadManager.metadataCookieArgs()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var lines: [String] = []
            // YouTube, Vimeo and TikTok hand out title and picture publicly —
            // faster than yt-dlp, and no browser cookies are needed.
            if let (title, picture) = Self.publicPreview(for: item.url) {
                lines = [title, picture]
            }
            for cookies in (lines.isEmpty ? cookieSets : []) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ytDlp)
                p.arguments = ["--no-warnings", "--no-playlist", "--skip-download",
                               "--print", "%(title)s", "--print", "%(thumbnail)s"]
                    + DownloadManager.jsRuntimeArgs() + cookies + [item.url]
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = DownloadManager.toolSearchPath(ytDlp: ytDlp)
                p.environment = env
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                guard (try? p.run()) != nil else { continue }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
                    lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    break
                }
            }
            guard !lines.isEmpty else { return }
            let title = lines.first.flatMap { $0.isEmpty || $0 == "NA" ? nil : $0 }
            DispatchQueue.main.async { self?.previews[item.id] = LinkPreview(title: title, image: nil) }
            guard lines.count > 1, let address = URL(string: lines[1]), address.scheme?.hasPrefix("http") == true else { return }
            var request = URLRequest(url: address)
            request.timeoutInterval = 20
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async { self?.previews[item.id] = LinkPreview(title: title, image: image) }
            }.resume()
        }
    }

    func remove(_ id: UUID) {
        let playlist = items.first { $0.id == id }?.playlist
        if items.contains(where: { $0.id == id }) { batchTotal = max(batchDone, batchTotal - 1) }
        items.removeAll { $0.id == id }
        if let playlist { finishPlaylistIfDone(playlist.id) }
    }

    /// When the last video of a playlist is over, the history gets ONE entry for the whole playlist.
    private func finishPlaylistIfDone(_ id: UUID) {
        let stillGoing = items.contains { $0.playlist?.id == id } || running.contains { $0.item.playlist?.id == id }
        guard !stillGoing, let info = playlistInfo[id] else { return }
        let succeeded = playlistSucceeded[id] ?? 0
        playlistInfo[id] = nil
        playlistSucceeded[id] = nil
        if succeeded > 0 {
            DownloadHistory.shared.recordPlaylist(url: info.listURL, title: info.title,
                                                  count: succeeded, thumbnail: info.thumbnail)
        }
    }

    /// More than one download in the current batch, and something still to do.
    var batchActive: Bool { batchTotal > 1 && busyCount + items.count > 0 }

    /// Share of the whole batch that is done, counting the running ones part-way.
    func batchFraction() -> Double {
        guard batchTotal > 0 else { return 0 }
        let partial = managers.filter { $0.isRunning || $0.isPaused }.map(\.progress).reduce(0, +)
        return min(1, (Double(batchDone) + partial) / Double(batchTotal))
    }

    /// Something is running that can be paused right now.
    var canPauseAll: Bool { managers.contains { $0.isRunning && $0.canPause } }
    var hasPaused: Bool { managers.contains { $0.isPaused } }

    /// Pauses everything that is downloading (nothing is lost; «Продолжить все» carries on).
    func pauseAll() {
        for manager in managers where manager.isRunning && manager.canPause { manager.pause() }
    }

    func resumeAll() {
        for manager in managers where manager.isPaused { manager.resume() }
    }

    /// Cancels what is running and empties the waiting list.
    func cancelAll() {
        let playlists = Set(items.compactMap { $0.playlist?.id })
        items.removeAll()
        batchTotal = batchDone + busyCount
        for manager in managers where manager.isRunning || manager.isPaused { manager.cancel() }
        for id in playlists { finishPlaylistIfDone(id) }
    }

    func clearFinished() {
        finished.removeAll()
    }

    func removeFinished(_ id: UUID) {
        finished.removeAll { $0.id == id }
    }

    /// The «готово» sound is for the end of the whole list, not for each file.
    func shouldChime(whenFinishing manager: DownloadManager) -> Bool {
        items.isEmpty && !managers.contains { $0 !== manager && ($0.isRunning || $0.isPaused) }
    }

    private func idleManager() -> DownloadManager? {
        // An engine whose finished job hasn't been written up yet isn't free either.
        func idle(_ m: DownloadManager) -> Bool {
            !m.isRunning && !m.isPaused && !running.contains { $0.manager === m }
        }
        if let primary, idle(primary) { return primary }
        if let free = extras.first(where: idle) { return free }
        guard extras.count < Self.maxParallel - 1 else { return nil }
        let extra = DownloadManager()
        extra.tracksUnfinished = false
        extras.append(extra)
        watch(extra)
        return extra
    }

    private func startWhilePossible() {
        let limit = Self.maxParallel
        while !items.isEmpty, busyCount < limit, let manager = idleManager() {
            let item = items.removeFirst()
            running.append(RunningJob(item: item, manager: manager))
            manager.recordsHistory = item.playlist == nil
            if startPaused.remove(item.id) != nil {
                manager.restorePaused(UnfinishedDownload(
                    url: item.url, destination: item.destination.path, maxHeight: item.maxHeight,
                    audioOnly: item.audioOnly, stripAudio: item.stripAudio,
                    videoFormat: item.videoFormat.rawValue, audioFormat: item.audioFormat.rawValue, name: nil))
                continue
            }
            manager.start(urlString: item.url,
                          destination: item.destination,
                          maxHeight: item.maxHeight,
                          audioOnly: item.audioOnly,
                          stripAudio: item.stripAudio,
                          videoFormat: item.videoFormat,
                          audioFormat: item.audioFormat)
        }
    }

    /// (title, picture address) from the site's public oEmbed endpoint.
    private static func publicPreview(for link: String) -> (String, String)? {
        guard let host = URL(string: link)?.host?.lowercased(),
              let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        let endpoint: String
        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            endpoint = "https://www.youtube.com/oembed?format=json&url=\(encoded)"
        } else if host.hasSuffix("vimeo.com") {
            endpoint = "https://vimeo.com/api/oembed.json?url=\(encoded)"
        } else if host.hasSuffix("tiktok.com") {
            endpoint = "https://www.tiktok.com/oembed?url=\(encoded)"
        } else {
            return nil
        }
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let done = DispatchSemaphore(value: 0)
        var result: (String, String)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return }
            result = (title, (json["thumbnail_url"] as? String) ?? "")
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        return result
    }

    private func phaseChanged(_ manager: DownloadManager, _ phase: DownloadManager.Phase) {
        // Pause / resume is part of what is saved (the phase changes just after this sink fires).
        DispatchQueue.main.async { [weak self] in self?.save() }
        let succeeded: Bool
        var note = ""
        switch phase {
        case .finished:
            succeeded = true
            note = tr("Готово")
        case .cancelled:
            succeeded = false
            note = tr("Отменено")
        case .failed(let message):
            succeeded = false
            note = String(message.split(separator: "\n").first ?? "").prefix(110).description
        default:
            return
        }
        // The engine sets the finished file just after the phase, so look a beat later.
        let job = running.first { $0.manager === manager }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak manager] in
            guard let self else { return }
            if let job {
                // Counted before the job leaves `running`, so the saved queue already knows it.
                if let playlist = job.item.playlist, succeeded { self.playlistSucceeded[playlist.id, default: 0] += 1 }
                self.running.removeAll { $0.id == job.id }
                self.batchDone += 1
                if let playlist = job.item.playlist {
                    self.finishPlaylistIfDone(playlist.id)
                }
                let preview = self.previews[job.item.id]
                self.finished.insert(
                    FinishedDownload(title: preview?.title ?? job.item.title,
                                     subtitle: job.item.title + " – " + job.item.formatLabel,
                                     url: job.item.url,
                                     succeeded: succeeded,
                                     note: note,
                                     image: preview?.image,
                                     fileURL: succeeded ? manager?.lastDownloadedFile : nil),
                    at: 0)
                if self.finished.count > 8 { self.finished.removeLast(self.finished.count - 8) }
                self.previews[job.item.id] = nil
            }
            self.startWhilePossible()
        }
    }
}

// MARK: - Window

enum DownloadsTab { case queue, history }

final class DownloadsTabState: ObservableObject {
    @Published var tab: DownloadsTab = .queue
}

/// One window for «Очередь» and «История»: what is downloading and waiting, and
/// what was downloaded before. Picking a line of the history hands its link back.
final class DownloadsPanel {
    static let shared = DownloadsPanel()
    private var window: NSWindow?
    private var activationObserver: NSObjectProtocol?
    private var clipboardAtOpen = 0
    private let tabState = DownloadsTabState()

    /// `tab: nil` picks the queue when something is going on, the history otherwise.
    func show(manager: DownloadManager, tab: DownloadsTab? = nil, onPick: @escaping (String) -> Void) {
        let queue = DownloadQueue.shared
        let busy = queue.busyCount > 0 || !queue.items.isEmpty || !queue.finished.isEmpty
        tabState.tab = tab ?? (busy ? .queue : .history)

        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: DownloadsView(
                manager: manager,
                tabState: tabState,
                onPick: { [weak self] url in
                    self?.window?.close()
                    onPick(url)
                },
                onClose: { [weak self] in self?.window?.close() })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = tr("Загрузки")
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(NSSize(width: 560, height: 590))
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win

        // Copying a new link means the next move is «Скачать» in the main window,
        // which this window would be covering — so it steps aside.
        clipboardAtOpen = NSPasteboard.general.changeCount
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window, window.isVisible,
                  NSPasteboard.general.changeCount != self.clipboardAtOpen else { return }
            window.close()
            NSApp.windows.first { $0 !== window && $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @ObservedObject var tabState: DownloadsTabState
    var onPick: (String) -> Void
    var onClose: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            PillSegments(options: [("queue", tr("Очередь")), ("history", tr("История"))],
                         selected: tabState.tab == .queue ? "queue" : "history") { picked in
                tabState.tab = picked == "queue" ? .queue : .history
            }
            .padding(.top, 14)
            .padding(.bottom, 2)
            switch tabState.tab {
            case .queue:   QueueView(manager: manager, onClose: onClose)
            case .history: HistoryView(onPick: onPick, onClose: onClose)
            }
        }
        .frame(width: 560, height: 590)
    }
}

struct QueueView: View {
    @ObservedObject var manager: DownloadManager
    var onClose: () -> Void

    @ObservedObject private var queue = DownloadQueue.shared
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    WindowTitleRow(title: tr("Очередь загрузок"))
                        .padding(.bottom, 4)
                    if queue.busyCount == 0 && queue.items.isEmpty {
                        Text(tr("Очередь пуста"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                    ForEach(queue.managers.indices, id: \.self) { index in
                        RunningCard(manager: queue.managers[index],
                                    job: queue.running.first { $0.manager === queue.managers[index] })
                    }
                    ForEach(queue.items) { waitingCard($0) }
                    if !queue.finished.isEmpty {
                        HStack {
                            Text(tr("Недавно завершённые")).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(tr("Очистить")) { queue.clearFinished() }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                        ForEach(queue.finished) { finishedCard($0) }
                    }
                }
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 8, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                // The managers' own state isn't published through the queue, so look again twice a second.
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    HStack(spacing: 10) {
                        if queue.canPauseAll {
                            Button(tr("Остановить все")) { queue.pauseAll() }
                                .buttonStyle(SoftPillStyle())
                                .lineLimit(1).fixedSize()
                        } else if queue.hasPaused {
                            Button(tr("Продолжить все")) { queue.resumeAll() }
                                .buttonStyle(SoftPillStyle())
                                .lineLimit(1).fixedSize()
                        }
                        if queue.busyCount > 0 || !queue.items.isEmpty {
                            Button(tr("Удалить все")) { queue.cancelAll() }
                                .buttonStyle(SoftPillStyle())
                                .lineLimit(1).fixedSize()
                        }
                    }
                }
                Spacer()
                Button(tr("Закрыть")) { onClose() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(EdgeInsets(top: 12, leading: 24, bottom: 16, trailing: 24))
        }
        .frame(width: 560, height: 540)
    }

    private func waitingCard(_ item: QueuedDownload) -> some View {
        let preview = queue.previews[item.id]
        return DownloadCard(title: preview?.title ?? item.title,
                            subtitle: item.title + " – " + item.formatLabel,
                            image: preview?.image,
                            progress: nil,
                            statusIcon: "clock",
                            status: tr("Ждёт очереди")) {
            CardButton(systemImage: "xmark", help: tr("Убрать из очереди")) { queue.remove(item.id) }
        }
        .onAppear { queue.loadThumbnailIfNeeded(item) }
    }

    private func finishedCard(_ item: FinishedDownload) -> some View {
        DownloadCard(title: item.title,
                     subtitle: item.subtitle,
                     image: item.image,
                     progress: item.succeeded ? 1 : nil,
                     statusIcon: item.succeeded ? "checkmark.circle.fill" : "xmark.circle",
                     status: item.note) {
            if let file = item.fileURL {
                CardButton(title: tr("Показать файл")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            CardButton(systemImage: "xmark", help: tr("Убрать из списка")) { queue.removeFinished(item.id) }
        }
    }
}

/// One running (or paused) download, with its own pause and cancel.
private struct RunningCard: View {
    @ObservedObject var manager: DownloadManager
    let job: RunningJob?
    @ObservedObject private var queue = DownloadQueue.shared

    var body: some View {
        if manager.isRunning || manager.isPaused {
            let url = job?.item.url ?? UnfinishedDownload.saved?.url ?? ""
            let preview = job.flatMap { queue.previews[$0.item.id] }
            let savedName = UnfinishedDownload.saved.flatMap { $0.url == url ? $0.name : nil }
            let host = URL(string: url)?.host ?? url
            let format = job?.item.formatLabel
            DownloadCard(title: preview?.title ?? savedName ?? host,
                         subtitle: format.map { host + " – " + $0 } ?? host,
                         image: preview?.image,
                         progress: manager.progress,
                         statusIcon: manager.isPaused ? "pause.circle" : "arrow.down.circle",
                         status: manager.isPaused ? tr("Пауза — нажми «Продолжить»") : manager.statusLine) {
                if manager.isPaused {
                    CardButton(title: tr("Продолжить")) { manager.resume() }
                } else {
                    CardButton(title: tr("Пауза")) { manager.pause() }
                        .disabled(!manager.canPause)
                }
                CardButton(systemImage: "xmark", help: tr("Отменить")) { manager.cancel() }
            }
            .onAppear { if let item = job?.item { queue.loadThumbnailIfNeeded(item) } }
        }
    }
}

private struct CardButton: View {
    var title: String? = nil
    var systemImage: String? = nil
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
            } else if let title {
                Text(title).font(.caption.weight(.medium))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, systemImage == nil ? 8 : 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.18)))
        .help(help)
    }
}

/// A download as a rectangle with its cover picture behind the text.
private struct DownloadCard<Actions: View>: View {
    let title: String
    let subtitle: String
    let image: NSImage?
    let progress: Double?
    let statusIcon: String
    let status: String
    @ViewBuilder var actions: Actions

    /// Shown behind the text when the site gave no cover picture.
    private static var placeholder: NSImage? {
        Bundle.main.url(forResource: "CardPlaceholder", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    }

    var body: some View {
        ZStack {
            Color.clear
                .background(
                    Group {
                        if let picture = image ?? Self.placeholder {
                            Color.clear.overlay(Image(nsImage: picture).resizable().scaledToFill())
                        } else {
                            Color.gray.opacity(0.45)
                        }
                    }
                )
                .clipped()
            LinearGradient(colors: [.black.opacity(0.35), .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 6) { actions }
                }
                .padding(10)
                Spacer(minLength: 0)
                if let progress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color.white.opacity(0.25))
                            Rectangle().fill(Color.red).frame(width: proxy.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 3)
                }
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                    Text(status).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.35))
            }
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12)))
    }
}
