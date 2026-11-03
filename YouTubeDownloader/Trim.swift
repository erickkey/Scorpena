import SwiftUI
import AppKit
import AVFoundation
import AVKit
import Combine

// «Вырезать фрагмент»: a window where the video can be watched (with sound) and the
// beginning and the end of the wanted part are marked, then only that part is downloaded.

/// The link field of the clip window.
final class LinkField: ObservableObject {
    /// The clip window's own field. It keeps what was in it until the program is closed — nothing is
    /// copied into it from the other windows (that used to start preparing a preview by itself).
    static let clip = LinkField()
    @Published var text = ""
}

final class TrimPanel {
    static let shared = TrimPanel()
    private var window: NSWindow?
    private var model: TrimModel?
    private var closeObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    func show(manager: DownloadManager) {
        NSApp.activate(ignoringOtherApps: true)
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let model = TrimModel(manager: manager)
        self.model = model
        let hosting = NSHostingController(
            rootView: TrimView(model: model, onClose: { [weak self] in self?.window?.close() })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.setLocalizedTitle("Вырезать фрагмент")
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(NSSize(width: 660, height: 706))
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
        // Keys, as on YouTube, while a time is not being typed in:
        //  Space — play, pause;  ← / → — 5 s back / forward (Shift: 1 s);  , / . — one frame;
        //  0–9 — jump to that tenth of the video.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak win] event in
            guard let self, let win, event.window === win, let model = self.model, model.previewReady,
                  !(win.firstResponder is NSTextView),
                  !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return event }
            let shift = event.modifierFlags.contains(.shift)
            // The key codes do not depend on the keyboard layout.
            let digits: [UInt16: Int] = [29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
            switch event.keyCode {
            case 49: model.togglePlay()                                   // Space
            case 123: model.nudge(by: shift ? -1 : -5)                    // ←
            case 124: model.nudge(by: shift ? 1 : 5)                      // →
            case 43: model.stepFrame(-1)                                  // ,
            case 47: model.stepFrame(1)                                   // .
            default:
                guard let tenth = digits[event.keyCode] else { return event }
                model.jump(toTenth: tenth)
            }
            return nil
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            if let monitor = self?.keyMonitor { NSEvent.removeMonitor(monitor) }
            self?.keyMonitor = nil
            self?.model?.shutdown()
            self?.model = nil
            self?.window = nil
        }
    }
}

// MARK: - Model

final class TrimModel: ObservableObject {
    enum Phase: Equatable {
        case empty
        case preparing(Double?)            // nil = the percent isn't known yet
        case ready
        case failed(String, diskAccess: Bool)
    }

    /// One attempt to prepare the viewing copy; `cancelled` is read by the worker thread.
    private final class LoadJob {
        var cancelled = false
        var process: Process?
    }

    let manager: DownloadManager
    @Published private(set) var phase: Phase = .empty
    @Published private(set) var player: AVPlayer?
    @Published private(set) var duration: Double = 0
    @Published private(set) var current: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var title: String?
    @Published var start: Double = 0
    @Published var end: Double = 0
    @Published var startText = "0:00"
    @Published var endText = "0:00"
    @Published private(set) var queuedNote: String?
    /// A new link is being prepared while the old video stays on the screen (so a corrected typo does
    /// not make the preview vanish); the percent of that preparation, when known.
    @Published private(set) var refreshing = false
    @Published private(set) var refreshPercent: Double?

    private var job: LoadJob?
    private var tempDir: URL?
    private var loadedLink = ""
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var clipEnd: Double?          // while «Посмотреть фрагмент» is playing

    init(manager: DownloadManager) {
        self.manager = manager
        // A fresh link is looked at after a short pause; while a video is on the screen, the pause is
        // 3 seconds, so correcting a typo does not make anything happen halfway through.
        LinkField.clip.$text
            .removeDuplicates()
            .map { [weak self] _ in (self?.previewReady ?? false) ? 3.0 : 0.7 }
            .map { delay in Just(()).delay(for: .seconds(delay), scheduler: DispatchQueue.main) }
            .switchToLatest()
            .sink { [weak self] _ in self?.linkChanged() }
            .store(in: &cancellables)
    }

    var link: String { LinkField.clip.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var linkIsUsable: Bool { ContentView.isPlausibleURLString(link) }
    var section: ClipSection { ClipSection(start: start, end: end) }
    /// The length of the video: from the viewing copy when it is ready, from the quality check before that
    /// (0 = not known yet).
    var total: Double { duration > 0 ? duration : (manager.probedDuration ?? 0) }
    /// A part can be downloaded as soon as the link is usable and the times make sense — the preview
    /// does not have to be ready (the times may be typed in at once).
    var sectionIsValid: Bool {
        linkIsUsable && end - start >= 0.2 && start >= 0 && (total <= 0 || end <= total + 0.05)
    }
    /// Playing and the marks on the timeline need the viewing copy.
    var previewReady: Bool { phase == .ready }
    private var typedByUser = false

    // MARK: Loading the viewing copy

    func linkChanged() {
        guard linkIsUsable else {
            if link.isEmpty { reset() }
            return
        }
        if link != loadedLink { load() }
    }

    private func reset() {
        job?.cancelled = true
        job?.process?.terminate()
        job = nil
        removePlayer()
        removeTemp()
        loadedLink = ""
        title = nil
        duration = 0; start = 0; end = 0; current = 0
        typedByUser = false
        refreshing = false
        startText = "0:00"; endText = "0:00"
        phase = .empty
    }

    /// Prepares a light copy (about 360p, H.264 + AAC) for watching: it plays and scrubs
    /// instantly whatever the site, and the real download still uses the chosen quality.
    func load() {
        guard linkIsUsable else { return }
        let url = link
        // A video is on the screen already: it stays (dimmed, with «Готовлю просмотр…») until the new one is ready.
        let hadPreview = phase == .ready && player != nil
        if hadPreview {
            job?.cancelled = true
            job?.process?.terminate()
            job = nil
            removeTemp()
        } else {
            reset()
        }
        loadedLink = url
        manager.resetProbe()
        manager.probeQuality(urlString: url)     // the sizes shown next to the clip length come from here
        // Prepared a short while ago: shown at once.
        if let hit = PreviewCache.lookup(url) {
            title = hit.title
            show(file: hit.file)
            return
        }
        guard let ytDlp = manager.ytDlpPath, let ffmpeg = manager.ffmpegPath else {
            refreshing = false
            phase = .failed(tr("Внутри программы не хватает файлов. Скачай Scorpena заново."), diskAccess: false)
            return
        }
        let job = LoadJob()
        self.job = job
        if hadPreview { refreshing = true; refreshPercent = nil } else { phase = .preparing(nil) }

        let dir = DownloadManager.partialDir.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var log = ""
            var sawAuth = false
            var found: URL?
            var foundTitle: String?
            for cookieArgs in DownloadManager.metadataCookieArgs() {
                if job.cancelled { return }
                let result = Self.downloadViewingCopy(job: job, ytDlp: ytDlp, ffmpegDir: ffmpegDir, url: url, dir: dir,
                                                      cookieArgs: cookieArgs) { percent in
                    DispatchQueue.main.async {
                        guard let self, self.job === job, !job.cancelled else { return }
                        if self.refreshing { self.refreshPercent = percent } else { self.phase = .preparing(percent) }
                    }
                }
                log += result.log
                if let file = result.file { found = file; foundTitle = result.title; break }
                let lower = result.log.lowercased()
                if DownloadManager.isAuthWall(lower) || (lower.contains("operation not permitted") && lower.contains("cookie")) {
                    sawAuth = true
                    continue
                }
                break
            }
            if job.cancelled { return }
            var playable = found
            if let file = found {
                playable = Self.makePlayable(file: file, ffmpeg: ffmpeg)
            }
            // Kept for a day, so the same link does not have to be prepared again.
            let stored = playable.flatMap { PreviewCache.store(file: $0, link: url, title: foundTitle) }
            DispatchQueue.main.async {
                guard let self, self.job === job, !job.cancelled else { return }
                if let playable {
                    self.title = foundTitle
                    self.show(file: stored ?? playable)
                    if stored != nil { self.removeTemp() }
                } else {
                    self.refreshing = false
                    if hadPreview { self.removePlayer() }
                    let message = sawAuth
                        ? DownloadManager.authWallMessage(fdaBlocked: !DownloadManager.hasDiskAccess)
                        : (DownloadManager.friendlyDownloadError(in: log)
                           ?? tr("Не получилось открыть ролик для просмотра."))
                    self.phase = .failed(message, diskAccess: sawAuth && !DownloadManager.hasDiskAccess)
                }
            }
        }
    }

    /// Returns the file and the title, or nil with the log of what went wrong.
    private static func downloadViewingCopy(job: LoadJob, ytDlp: String, ffmpegDir: String, url: String, dir: URL,
                                            cookieArgs: [String], progress: @escaping (Double) -> Void)
        -> (file: URL?, title: String?, log: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytDlp)
        p.arguments = [
            "--newline", "--no-color", "--no-playlist", "--no-simulate", "--progress",
            "--ffmpeg-location", ffmpegDir,
            "--retries", "10", "--socket-timeout", "20", "--concurrent-fragments", "5",
            "--print", "before_dl:SCORPENA_TITLE|%(title)s",
            "-f", "bv*[height<=360][vcodec^=avc1]+ba[ext=m4a]/b[height<=360][vcodec^=avc1]/bv*[height<=360]+ba/b[height<=360]/bv*+ba/b",
            "-S", "res:360,vcodec:h264,acodec:aac,ext:mp4:m4a",
            "--merge-output-format", "mp4",
            "-P", "home:" + dir.path, "-o", "preview.%(ext)s",
        ] + DownloadManager.jsRuntimeArgs() + cookieArgs + [url]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = DownloadManager.toolSearchPath(ytDlp: ytDlp, extraFirst: [ffmpegDir])
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        job.process = p

        var log = ""
        var title: String?
        var buffer = Data()
        let queue = DispatchQueue(label: "trim.read")
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            queue.sync {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    log += line + "\n"
                    if line.hasPrefix("SCORPENA_TITLE|") { title = String(line.dropFirst("SCORPENA_TITLE|".count)) }
                    else if line.hasPrefix("[download]"), let percent = Self.percent(in: line) { progress(percent) }
                }
            }
        }
        guard (try? p.run()) != nil else { return (nil, nil, "yt-dlp не запустился") }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        queue.sync {}
        job.process = nil
        guard p.terminationStatus == 0 else { return (nil, nil, log) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let file = files.first { $0.lastPathComponent.hasPrefix("preview.") && !$0.lastPathComponent.hasSuffix(".part") }
        return (file, title, log)
    }

    private static func percent(in line: String) -> Double? {
        guard let range = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) else { return nil }
        return Double(line[range].dropLast()).map { min(1, $0 / 100) }
    }

    /// The viewing copy plays in the system player; if the site gave something else, it is converted.
    private static func makePlayable(file: URL, ffmpeg: String) -> URL? {
        if AVURLAsset(url: file).isPlayable { return file }
        let out = file.deletingLastPathComponent().appendingPathComponent("preview-play.mp4")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", file.path, "-vf", "scale=-2:360", "-c:v", "libx264", "-preset", "veryfast",
                       "-crf", "30", "-c:a", "aac", "-movflags", "+faststart", out.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return p.terminationStatus == 0 && AVURLAsset(url: out).isPlayable ? out : nil
    }

    private func show(file: URL) {
        refreshing = false
        let item = AVPlayerItem(url: file)
        let player = AVPlayer(playerItem: item)
        let seconds = item.asset.duration.seconds
        duration = seconds.isFinite ? seconds : 0
        if typedByUser, end > start + minimumGap {
            // The times were typed in while the preview was being prepared: they stay.
            start = min(start, max(0, duration - minimumGap))
            end = min(end, duration)
        } else {
            start = 0
            end = duration
        }
        startText = ClipSection.clock(start)
        endText = ClipSection.clock(end)
        current = 0
        removePlayer()
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.04, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in self?.tick(time.seconds) }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = (status == .playing) }
            .store(in: &cancellables)
        phase = duration > 0 ? .ready : .failed(tr("Не получилось открыть ролик для просмотра."), diskAccess: false)
    }

    private func tick(_ time: Double) {
        guard time.isFinite else { return }
        current = time
        if let clipEnd, time >= clipEnd {
            player?.pause()
            self.clipEnd = nil
        }
    }

    private func removePlayer() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        isPlaying = false
        clipEnd = nil
    }

    private func removeTemp() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    func shutdown() {
        reset()
        cancellables.removeAll()
    }

    // MARK: Watching

    func togglePlay() {
        guard let player else { return }
        clipEnd = nil
        if isPlaying { player.pause(); return }
        if current >= duration - 0.05 { seek(to: 0) }
        player.play()
    }

    func seek(to time: Double) {
        guard let player else { return }
        let t = min(max(0, time), duration)
        current = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// One button for the marked part: plays it (so it can be checked by ear before downloading),
    /// pauses it, and carries on from where it stopped. After the end it starts again from the start mark.
    func toggleClipPlayback() {
        guard let player, phase == .ready, sectionIsValid else { return }
        if isPlaying {
            player.pause()
            return
        }
        if current < start - 0.05 || current >= end - 0.05 { seek(to: start) }
        clipEnd = end
        player.play()
    }

    // MARK: Marking

    /// The two marks never cross: the start stays at least this far before the end.
    private let minimumGap = 0.2

    /// «Начало здесь»: if the video is already past the end mark, the end moves to the very end.
    func markStartHere() { place(start: current, pushingEnd: true) }

    /// «Конец здесь»: if the video is before the start mark, the start moves to the very beginning.
    func markEndHere() { place(end: current, pushingStart: true) }

    /// Dragging a handle: it stops against the other one.
    func dragStart(_ time: Double) {
        start = min(max(0, time), max(0, end - minimumGap))
        startText = ClipSection.clock(start)
        seek(to: start)
    }

    func dragEnd(_ time: Double) {
        end = max(min(duration, time), min(duration, start + minimumGap))
        endText = ClipSection.clock(end)
        seek(to: end)
    }

    private func place(start newStart: Double, pushingEnd: Bool) {
        var s = min(max(0, newStart), max(0, duration - minimumGap))
        if pushingEnd, s > end - minimumGap { end = duration }
        s = min(s, max(0, end - minimumGap))
        start = s
        startText = ClipSection.clock(start)
        endText = ClipSection.clock(end)
    }

    private func place(end newEnd: Double, pushingStart: Bool) {
        var e = min(max(0, newEnd), duration)
        if pushingStart, e < start + minimumGap { start = 0 }
        e = max(e, min(duration, start + minimumGap))
        end = e
        startText = ClipSection.clock(start)
        endText = ClipSection.clock(end)
    }

    /// Typing a time: it counts at once (so «Скачать фрагмент» can be pressed right after typing).
    func startTextEdited() {
        if let value = ClipSection.parse(startText) { start = max(0, value); typedByUser = true }
    }

    func endTextEdited() {
        if let value = ClipSection.parse(endText) { end = max(0, value); typedByUser = true }
    }

    func commitStartText() {
        guard let value = ClipSection.parse(startText) else { startText = ClipSection.clock(start); return }
        typedByUser = true
        if phase == .ready { place(start: value, pushingEnd: true) }
        else { start = max(0, value); startText = ClipSection.clock(start) }
    }

    func commitEndText() {
        guard let value = ClipSection.parse(endText) else { endText = ClipSection.clock(end); return }
        typedByUser = true
        if phase == .ready { place(end: value, pushingStart: true) }
        else { end = total > 0 ? min(max(0, value), total) : max(0, value); endText = ClipSection.clock(end) }
    }

    /// A step back or forward in the video.
    func nudge(by seconds: Double) {
        guard phase == .ready else { return }
        seek(to: current + seconds)
    }

    /// «,» and «.» (as on YouTube): one frame back or forward, with the video paused.
    func stepFrame(_ direction: Int) {
        guard phase == .ready, let item = player?.currentItem else { return }
        player?.pause()
        clipEnd = nil
        item.step(byCount: direction)
        current = min(max(0, item.currentTime().seconds), duration)
    }

    /// Keys 0–9: jump to that tenth of the video.
    func jump(toTenth tenth: Int) {
        guard phase == .ready else { return }
        seek(to: duration * Double(tenth) / 10)
    }


    // MARK: Downloading the part

    /// Puts the marked part into the download queue, with the choices of the main window.
    /// The part of the whole file's size that the marks cover.
    private func clipExpectedBytes(height: Int?, audioOnly: Bool) -> Int64? {
        guard total > 0, let whole = manager.expectedSize(height: height, audioOnly: audioOnly) else { return nil }
        return Int64(Double(whole) * (end - start) / total)
    }

    func downloadClip(audioOnly: Bool, qualityHeight: Int, stripAudio: Bool, destination: URL) {
        commitStartText(); commitEndText()      // a time typed a moment ago and not confirmed yet
        guard sectionIsValid else { return }
        let maxHeight = manager.availableHeights.isEmpty ? nil : (qualityHeight == 0 ? nil : qualityHeight)
        let item = QueuedDownload(url: link, destination: destination, maxHeight: maxHeight,
                                  audioOnly: audioOnly, stripAudio: stripAudio,
                                  videoFormat: .current, audioFormat: .current,
                                  knownTitle: title, section: section,
                                  expectedBytes: clipExpectedBytes(height: maxHeight, audioOnly: audioOnly))
        if DownloadQueue.shared.isActive(url: link, audioOnly: audioOnly, section: section) {
            queuedNote = tr("Этот отрывок уже скачивается или стоит в очереди")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.queuedNote = nil }
            return
        }
        DownloadQueue.shared.submitUnlessDownloaded(item) { [weak self] in
            self?.queuedNote = tr("Фрагмент добавлен в загрузки. Выбери ещё один или закрой окно")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self?.queuedNote = nil }
        }
    }
}

// MARK: - Window content

/// Plays the video without the system controls: the timeline below is our own.
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct TrimView: View {
    @ObservedObject var model: TrimModel
    var onClose: () -> Void

    @ObservedObject private var link = LinkField.clip
    @ObservedObject private var manager: DownloadManager
    @ObservedObject private var languageSettings = LanguageSettings.shared
    @AppStorage("qualityHeight") private var qualityHeight = 0
    @AppStorage("videoNoAudio") private var videoNoAudio = false
    @AppStorage(VideoFormat.key) private var videoFormat = VideoFormat.mp4.rawValue
    @AppStorage(AudioFormat.key) private var audioFormat = AudioFormat.mp3.rawValue
    @AppStorage("downloadMode") private var downloadMode = "video"
    @AppStorage("destinationFolder") private var destinationPath: String =
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path) ?? NSHomeDirectory()

    init(model: TrimModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        _manager = ObservedObject(wrappedValue: model.manager)
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                linkField
                // The same line as under the main window's field.
                let hint = ContentView.linkHint(link.text)
                HStack {
                    Text(hint?.text ?? " ").foregroundStyle(hint?.color ?? .secondary).opacity(hint == nil ? 0 : 1)
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            playerArea
            // The controls are there from the start. The timeline and the «здесь» buttons wait for the
            // preview; the times and the choices work as soon as there is a link, so a part whose times
            // are known can be cut at once.
            TrimTimeline(model: model)
                .disabled(!model.previewReady)
                .opacity(model.previewReady ? 1 : 0.4)
            markRow
            optionsRow
                .disabled(!model.linkIsUsable)
                .opacity(model.linkIsUsable ? 1 : 0.4)
            Spacer(minLength: 0)
            bottomRow
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 18, trailing: 24))
        .frame(width: 660, height: 724)
        .onAppear { model.linkChanged() }
    }

    // MARK: Pieces

    private var linkField: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.title3).foregroundStyle(.secondary)
            TextField(tr("Вставь ссылку на видео"), text: $link.text)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1)
                .disableAutocorrection(true)
                .onSubmit { model.load() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// The frame is always 16:9 and as wide as the window; whatever is inside (a message, the video)
    /// is laid over it and can never change its shape.
    private var playerArea: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay { playerContent }
            .overlay(alignment: .bottomLeading) {
                if model.phase == .ready {
                    Text(tr("Просмотр в сниженном качестве. Скачается в том, что выбрано ниже"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(8)
                }
            }
    }

    private var playerContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.9))
            switch model.phase {
            case .empty:
                Text(tr("Вставь ссылку и ролик откроется здесь"))
                    .foregroundStyle(.white.opacity(0.6))
            case .preparing(let percent):
                VStack(spacing: 10) {
                    if let percent {
                        ProgressView(value: percent).frame(width: 220)
                        Text(trf("Готовлю просмотр… %d%%", Int(percent * 100))).foregroundStyle(.white.opacity(0.75))
                    } else {
                        ProgressView().controlSize(.small)
                        Text(tr("Готовлю просмотр…")).foregroundStyle(.white.opacity(0.75))
                    }
                }
            case .failed(let message, let diskAccess):
                VStack(spacing: 10) {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                    if diskAccess {
                        Button(tr("Открыть настройки")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(SoftPillStyle(compact: true))
                    }
                }
                .padding(20)
            case .ready:
                PlayerSurface(player: model.player)
                    .opacity(model.refreshing ? 0.35 : 1)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                // The system player view swallows clicks, so a clear layer on top catches them:
                // a click plays or pauses.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
                if model.refreshing {
                    VStack(spacing: 10) {
                        if let percent = model.refreshPercent {
                            ProgressView(value: percent).frame(width: 220)
                            Text(trf("Готовлю просмотр… %d%%", Int(percent * 100))).foregroundStyle(.white.opacity(0.85))
                        } else {
                            ProgressView().controlSize(.small)
                            Text(tr("Готовлю просмотр…")).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                } else if !model.isPlaying {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private enum TimeField { case start, end }
    @FocusState private var focusedTime: TimeField?
    @State private var previousFocus: TimeField?

    private var markRow: some View {
        HStack(spacing: 18) {
            markGroup(title: tr("Начало"), field: .start, text: $model.startText,
                      edited: { model.startTextEdited() }, commit: { model.commitStartText()},
                      button: tr("Начало здесь")) { model.markStartHere() }
            markGroup(title: tr("Конец"), field: .end, text: $model.endText,
                      edited: { model.endTextEdited() }, commit: { model.commitEndText() },
                      button: tr("Конец здесь")) { model.markEndHere() }
        }
        .opacity(model.linkIsUsable ? 1 : 0.4)
        .onChange(of: focusedTime) { now in
            // Leaving a field confirms what was typed in it.
            if previousFocus == .start, now != .start { model.commitStartText() }
            if previousFocus == .end, now != .end { model.commitEndText() }
            previousFocus = now
        }
    }

    private func markGroup(title: String, field: TimeField, text: Binding<String>,
                           edited: @escaping () -> Void, commit: @escaping () -> Void,
                           button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, onCommit: commit)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 74)
                .font(.system(.body, design: .monospaced))
                .focused($focusedTime, equals: field)
                .onChange(of: text.wrappedValue) { _ in if focusedTime == field { edited() } }
                .disabled(!model.linkIsUsable)
            Button(action: action) { Text(button) }
                .buttonStyle(SoftPillStyle(compact: true))
                .disabled(!model.previewReady)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 20) {
                FormatSegments(title: tr("Видео"),
                               options: VideoFormat.allCases.map { ($0.rawValue, $0.title) },
                               selected: videoFormat, active: downloadMode == "video", disabled: false) { picked in
                    videoFormat = picked
                    downloadMode = "video"
                }
                FormatSegments(title: tr("Звук"),
                               options: AudioFormat.allCases.map { ($0.rawValue, $0.title) },
                               selected: audioFormat, active: downloadMode == "audio", disabled: false) { picked in
                    audioFormat = picked
                    downloadMode = "audio"
                }
            }
            // Sound only has no picture to choose the quality of.
            HStack(spacing: 8) {
                if downloadMode != "audio" {
                    Toggle(tr("без звука"), isOn: $videoNoAudio)
                        .toggleStyle(.checkbox)
                    Text("·")
                    QualityPicker(manager: manager, link: model.link, height: $qualityHeight)
                }
            }
            .frame(minHeight: 20)
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// «Фрагмент: 1:53 · ≈ 38 МБ (весь ролик: 214 МБ)» — the size is a guess from the whole video's size.
    private var sizeText: String {
        let length = ClipSection.clock(max(0, model.end - model.start))
        var text = tr("Фрагмент:") + " " + length
        let height = (qualityHeight == 0 || !manager.availableHeights.contains(qualityHeight))
            ? manager.availableHeights.first : qualityHeight
        let whole: Int64? = downloadMode == "audio" ? manager.approxAudioBytes
            : height.flatMap { manager.approxSizeByHeight[$0] }
        if let whole, model.total > 0 {
            let part = Int64(Double(whole) * (model.end - model.start) / model.total)
            text += " · ≈ " + ContentView.formatBytes(part) + " (" + tr("весь ролик:") + " " + ContentView.formatBytes(whole) + ")"
        }
        return text
    }

    private var bottomRow: some View {
        VStack(spacing: 8) {
            // Notes have a line of their own: beside the buttons they squeezed the labels into two lines.
            Group {
                if let note = model.queuedNote {
                    Text(note).foregroundStyle(.green)
                } else {
                    Text(" ")
                }
            }
            .font(.caption)
            HStack(spacing: 10) {
                Button {
                    model.toggleClipPlayback()
                } label: {
                    Label(model.isPlaying ? tr("Пауза") : tr("Посмотреть фрагмент"),
                          systemImage: model.isPlaying ? "pause.fill" : "play.fill")
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: 190)
                }
                .buttonStyle(SoftPillStyle())
                .disabled(!model.previewReady || !model.sectionIsValid)
                Spacer()
                Button { onClose() } label: { Text(tr("Закрыть")).lineLimit(1).fixedSize() }
                    .buttonStyle(SoftPillStyle())
                Button {
                    model.downloadClip(audioOnly: downloadMode == "audio", qualityHeight: qualityHeight,
                                       stripAudio: videoNoAudio, destination: URL(fileURLWithPath: destinationPath))
                } label: { Text(tr("Скачать фрагмент")).lineLimit(1).fixedSize() }
                    .buttonStyle(PrimaryPillStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.sectionIsValid)
            }
        }
    }
}

// MARK: - Timeline with two handles

private struct TrimTimeline: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared   // texts below are looked up on every redraw
    @ObservedObject var model: TrimModel
    private let handleWidth: CGFloat = 12

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                let width = proxy.size.width
                let usable = max(1, width - handleWidth)
                let scale = model.duration > 0 ? usable / model.duration : 0
                ZStack(alignment: .leading) {
                    // The whole video.
                    Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                        .padding(.horizontal, handleWidth / 2)
                    // The wanted part.
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(0, CGFloat(model.end - model.start) * scale), height: 6)
                        .offset(x: handleWidth / 2 + CGFloat(model.start) * scale)
                    // Where the video is now.
                    Rectangle().fill(Color.primary)
                        .frame(width: 2, height: 30)
                        .offset(x: handleWidth / 2 + CGFloat(model.current) * scale - 1)
                        .allowsHitTesting(false)
                    handle(at: model.start, scale: scale) { x in
                        model.dragStart(Double((x - handleWidth / 2) / max(scale, 0.0001)))
                    }
                    handle(at: model.end, scale: scale) { x in
                        model.dragEnd(Double((x - handleWidth / 2) / max(scale, 0.0001)))
                    }
                }
                .frame(height: 34)
                .coordinateSpace(name: "trimTrack")
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let t = Double((value.location.x - handleWidth / 2) / max(scale, 0.0001))
                    model.seek(to: t)
                })
            }
            .frame(height: 34)
            HStack {
                Text(ClipSection.clock(0))
                Spacer()
                Text(trf("Сейчас %@ из %@", ClipSection.clock(model.current), ClipSection.clock(model.duration)))
                Spacer()
                Text(ClipSection.clock(model.duration))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func handle(at time: Double, scale: CGFloat, onDrag: @escaping (CGFloat) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, lineWidth: 1.5))
            .frame(width: handleWidth, height: 24)
            .offset(x: CGFloat(time) * scale)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("trimTrack")).onChanged { onDrag($0.location.x) })
    }
}


// MARK: - Quality choice shared by the clip window and the queue window

/// «Выбор качества: …» — the one menu of the main, queue and clip windows: nothing is known until
/// the link's automatic quality check is done, then every height with its size.
struct QualityPicker: View {
    @ObservedObject private var languageSettings = LanguageSettings.shared   // texts below are looked up on every redraw
    @ObservedObject var manager: DownloadManager
    let link: String
    @Binding var height: Int

    var body: some View {
        Menu {
            Button { height = 0 } label: {
                if height == 0 { Label(maxLabel, systemImage: "checkmark") } else { Text(maxLabel) }
            }
            ForEach(manager.availableHeights, id: \.self) { h in
                Button { height = h } label: {
                    if height == h { Label(menuLabel(h), systemImage: "checkmark") } else { Text(menuLabel(h)) }
                }
            }
        } label: {
            if manager.isProbing {
                HStack(spacing: 6) { Text(tr("Выбор качества:")).font(.caption); ProgressView().controlSize(.small) }
            } else {
                Text(tr("Выбор качества:") + " " + (height == 0 || !manager.availableHeights.contains(height) ? maxLabel : menuLabel(height)))
                    .font(.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .onChange(of: manager.availableHeights) { heights in
            if height != 0, !heights.contains(height) { height = 0 }
        }
    }

    private var maxLabel: String {
        guard !manager.availableHeights.isEmpty else { return tr("Максимально доступное") }
        if let h = manager.availableHeights.first, let bytes = manager.approxSizeByHeight[h] {
            return trf("Максимальное: %@", "≈ " + ContentView.formatBytes(bytes))
        }
        return tr("Максимальное")
    }

    private func menuLabel(_ h: Int) -> String {
        let name: String
        switch h {
        case 2160: name = "2160p (4K)"
        case 1440: name = "1440p (2K)"
        default:   name = "\(h)p"
        }
        if let bytes = manager.approxSizeByHeight[h] { return "\(name), ≈ " + ContentView.formatBytes(bytes) }
        return name
    }
}
