import Foundation
import Combine
import AVFoundation

/// Runs the external command-line jobs the app needs: a `yt-dlp` download and the
/// `ffmpeg` conversion that can follow it. Only one job runs at a time.
final class DownloadManager: ObservableObject {

    enum Phase: Equatable {
        case idle
        case running
        case finished
        case cancelled
        case paused                                      // stopped by the user, can be resumed
        case failed(String)
    }

    private enum Job {
        case download
        case transcode                                   // ffmpeg → H.264

        var label: String {
            switch self {
            case .download: return "yt-dlp"
            case .transcode: return "ffmpeg"
            }
        }
    }

    // MARK: Published state (mutated on the main queue only)

    @Published private(set) var phase: Phase = .idle {
        didSet {
            // A finished, failed or cancelled download is nothing to resume later.
            switch phase {
            case .finished, .failed, .cancelled: UnfinishedDownload.clear()
            default: break
            }
        }
    }
    /// True while a download (not a conversion) is at the stage where pausing is safe.
    @Published private(set) var canPause = false
    @Published private(set) var progress: Double = 0          // 0.0 ... 1.0
    @Published private(set) var indeterminate = false
    @Published private(set) var statusLine: String = ""
    @Published private(set) var log: String = ""

    @Published private(set) var ytDlpPath: String?
    @Published private(set) var ffmpegPath: String?

    @Published private(set) var isCheckingToolUpdate = false
    @Published private(set) var toolUpdateCheckStatus: String?
    @Published private(set) var ytDlpVersion: String?
    private var toolProgressTimer: Timer?

    /// Set when a download needs Safari cookies but the app lacks Full Disk Access.
    @Published private(set) var needsFullDiskAccess = false

    /// The finished video file (for "Показать файл"). Nil until a download completes.
    @Published private(set) var lastDownloadedFile: URL?

    // Quality probe.
    @Published private(set) var isProbing = false
    @Published private(set) var probedTitle: String?
    @Published private(set) var availableHeights: [Int] = []      // sorted high → low
    @Published private(set) var approxSizeByHeight: [Int: Int64] = [:]   // bytes, video+audio combined
    @Published private(set) var approxAudioBytes: Int64?                 // bytes, mp3 320kbps estimate

    /// True while downloading a fragmented (DASH/HLS) stream.
    @Published private(set) var fragmentedDownload = false
    /// True when the current download is from a site that serves video in many
    /// tiny slow fragments (Vimeo). Used only to show an explanatory note.
    @Published private(set) var slowFragmentedSite = false

    private enum CookieSource: Equatable {
        case none
        case browser(String)

        var ytDlpArgs: [String] {
            switch self {
            case .none: return []
            case .browser(let b): return ["--cookies-from-browser", DownloadManager.cookiesBrowserArg(for: b)]
            }
        }
        var describe: String {
            switch self {
            case .none: return tr("без входа")
            case .browser(let b): return trf("cookies из %@", b.capitalized)
            }
        }
        var storageKey: String {
            switch self {
            case .none: return ""
            case .browser(let b): return "browser:\(b)"
            }
        }
        static func fromStorage(_ s: String) -> CookieSource? {
            if s.hasPrefix("browser:") { return .browser(String(s.dropFirst(8))) }
            return nil
        }
    }

    private var process: Process?
    private var currentJob: Job = .download
    private var lineBuffer = Data()

    private var lastDestination: URL?          // folder of the current/last download
    private var transcodeInput: URL?           // original file being replaced
    private var transcodeOutput: URL?          // ffmpeg's temp output
    private var transcodeDuration: Double?     // seconds, for progress

    // Auto cookie-fallback state for the current download request.
    private var pendingURL = ""
    private var pendingMaxHeight: Int?
    private var pendingAudioOnly = false
    private var pendingStripAudio = false
    private var pendingVideoFormat: VideoFormat = .mp4
    private var pendingAudioFormat: AudioFormat = .mp3
    private var pendingSpeedLimit = 0
    private var userPaused = false
    private var runningSpeedLimit = 0          // limit the current yt-dlp process was started with
    private var resumeAfterPause = false       // a "pause" that is really a restart (new speed limit)
    private var restartStartTime: Date?
    private var speedApplyWork: DispatchWorkItem?
    private var downloadStartTime: Date?
    private var cookieQueue: [CookieSource] = []
    private var currentCookieSource: CookieSource = .none
    private var downloadAttempt = 0
    private var sawSafariPermissionBlock = false

    private let lastCookieKey = "lastCookieSource"

    private var chimePlayer: AVAudioPlayer?
    private var probeTimer: Timer?

    private let ytDlpKey = "ytDlpPath"
    private let ffmpegKey = "ffmpegPath"

    init() {
        refreshTools()
    }

    var isRunning: Bool { phase == .running }
    var isPaused: Bool { phase == .paused }
    var toolsReady: Bool { ytDlpPath != nil && ffmpegPath != nil }

    /// Are both tools the copies shipped inside the .app?
    var usingBundledTools: Bool {
        guard let y = ytDlpPath, let f = ffmpegPath else { return false }
        return ToolLocator.isBundled(y) && ToolLocator.isBundled(f)
    }

    // MARK: Tool discovery

    func refreshTools() {
        let defaults = UserDefaults.standard
        ytDlpPath = ToolLocator.find("yt-dlp", userOverride: defaults.string(forKey: ytDlpKey))
        ffmpegPath = ToolLocator.find("ffmpeg", userOverride: defaults.string(forKey: ffmpegKey))
        refreshYtDlpVersion()
    }

    func refreshYtDlpVersion() {
        guard let ytDlp = ytDlpPath else { ytDlpVersion = nil; return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let version = Self.captureOutput(ytDlp, ["--version"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { self?.ytDlpVersion = (version?.isEmpty == false) ? version : nil }
        }
    }

    /// Quietly brings the bundled yt-dlp up to the latest stable release (at
    /// most once a day, with a backup and rollback — see ToolAutoUpdater).
    /// Waits a few seconds so it never competes with the launch sequence.
    func autoUpdateToolsIfDue() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !self.isRunning, !self.isProbing else { return }
            ToolAutoUpdater.shared.runIfDue(ytDlp: self.ytDlpPath, knownVersion: self.ytDlpVersion) { [weak self] in
                self?.toolUpdateCheckStatus = nil
                self?.refreshYtDlpVersion()
            }
        }
    }

    func setYtDlpPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: ytDlpKey)
        refreshTools()
    }

    func setFfmpegPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: ffmpegKey)
        refreshTools()
    }

    func cancel() {
        if isPaused {
            phase = .cancelled
            statusLine = tr("Отменено")
            return
        }
        process?.terminate()
    }

    /// Called when the speed slider moves. yt-dlp can't change its limit while
    /// running, so the download is restarted from its partial file with the new
    /// one (after a short pause, so dragging the slider doesn't restart it each step).
    func speedLimitChanged() {
        speedApplyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applySpeedLimitIfNeeded() }
        speedApplyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func applySpeedLimitIfNeeded() {
        guard isRunning, canPause, case .download = currentJob,
              SpeedLimit.current != runningSpeedLimit else { return }
        restartStartTime = downloadStartTime
        userPaused = true
        resumeAfterPause = true
        process?.terminate()
    }

    /// Stops yt-dlp but keeps the partly downloaded file; `resume` continues it.
    func pause() {
        guard isRunning, canPause, case .download = currentJob else { return }
        userPaused = true
        process?.terminate()
    }

    func resume() {
        guard isPaused, let saved = UnfinishedDownload.saved else { return }
        resume(saved)
    }

    /// Runs the same request again; yt-dlp picks up the partial file.
    func resume(_ saved: UnfinishedDownload) {
        guard !isRunning else { return }
        start(urlString: saved.url,
              destination: URL(fileURLWithPath: saved.destination, isDirectory: true),
              maxHeight: saved.maxHeight,
              audioOnly: saved.audioOnly,
              stripAudio: saved.stripAudio,
              videoFormat: VideoFormat(rawValue: saved.videoFormat) ?? .mp4,
              audioFormat: AudioFormat(rawValue: saved.audioFormat) ?? .mp3)
    }

    // MARK: Quality probe

    /// Clears a previous probe result (call when the URL changes).
    func resetProbe() {
        guard !isProbing else { return }
        if probedTitle != nil || !availableHeights.isEmpty {
            probedTitle = nil
            availableHeights = []
            approxSizeByHeight = [:]
            approxAudioBytes = nil
        }
    }

    /// Asks yt-dlp which resolutions this URL actually has, and publishes them.
    /// Users often paste/type a link with no scheme ("www.site.com/…" or
    /// bare "site.com/…", the way a browser's address bar accepts it) —
    /// yt-dlp needs an actual http(s) URL, so fill one in if it's missing.
    private static func normalizedURLString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return trimmed }
        return "https://" + trimmed
    }

    func probeQuality(urlString: String) {
        guard !isRunning, !isProbing else { return }
        let url = Self.normalizedURLString(urlString)
        guard !url.isEmpty, let ytDlp = ytDlpPath else { return }

        if ToolLocator.isBundled(ytDlp), let dir = ToolLocator.bundledBinDirectory {
            Self.clearQuarantine(dir)
        }

        isProbing = true
        probedTitle = nil
        availableHeights = []
        approxSizeByHeight = [:]
        approxAudioBytes = nil

        let start = Date()
        statusLine = trf("Проверяю доступные качества… %d с", 0)
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let elapsed = Int(Date().timeIntervalSince(start))
            self?.statusLine = trf("Проверяю доступные качества… %d с", elapsed)
        }

        let lastGood = CookieSource.fromStorage(
            UserDefaults.standard.string(forKey: lastCookieKey) ?? "")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var result = Self.runProbe(ytDlp: ytDlp, url: url, cookieArgs: [])
            if result == nil, let lastGood, case .browser = lastGood {
                result = Self.runProbe(ytDlp: ytDlp, url: url, cookieArgs: lastGood.ytDlpArgs)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.probeTimer?.invalidate()
                self.probeTimer = nil
                self.isProbing = false
                let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
                if let (title, heights, sizes, duration) = result, !heights.isEmpty {
                    self.probedTitle = title
                    self.availableHeights = heights
                    self.approxSizeByHeight = sizes
                    self.approxAudioBytes = duration.map { Int64($0 * 40_000) }   // 320 kbps ≈ 40 KB/s
                    self.statusLine = trf("Доступно (%@ с): ", elapsed) + heights.map { "\($0)p" }.joined(separator: ", ")
                } else {
                    self.statusLine = trf("Не удалось определить качества за %@ с — при скачивании возьмётся максимум доступное.", elapsed)
                }
            }
        }
    }

    /// PATH for yt-dlp's child processes: the tools bundled in the app, then the
    /// system's own. Nothing else is looked at on purpose — the app must work on
    /// a Mac that has nothing installed, and a stray deno/node on the developer's
    /// machine would otherwise hide a missing bundled one.
    static func toolSearchPath(ytDlp: String, extraFirst: [String] = []) -> String {
        var dirs = extraFirst
        if ToolLocator.isBundled(ytDlp), let bin = ToolLocator.bundledBinDirectory {
            dirs.append(bin)
        }
        dirs += ["/usr/bin", "/bin"]
        return dirs.joined(separator: ":")
    }

    /// YouTube needs a JavaScript engine to solve its signature/"n"
    /// challenges (yt-dlp ships the solver scripts but not an engine), so
    /// point yt-dlp at the deno bundled next to it.
    static func jsRuntimeArgs() -> [String] {
        guard let bin = ToolLocator.bundledBinDirectory else { return [] }
        let deno = bin + "/deno"
        return FileManager.default.isExecutableFile(atPath: deno) ? ["--js-runtimes", "deno:\(deno)"] : []
    }

    private static func runProbe(ytDlp: String, url: String, cookieArgs: [String])
        -> (title: String, heights: [Int], sizeByHeight: [Int: Int64], duration: Double?)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytDlp)
        p.arguments = ["-J", "--no-warnings", "--no-playlist", "--no-progress"] + jsRuntimeArgs() + cookieArgs + [url]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolSearchPath(ytDlp: ytDlp)
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()

        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let title = (json["title"] as? String) ?? tr("видео")
        var heights = Set<Int>()
        var videoSizeByHeight: [Int: Int64] = [:]
        var bestAudioSize: Int64 = 0
        for f in (json["formats"] as? [[String: Any]]) ?? [] {
            let vcodec = f["vcodec"] as? String
            let acodec = f["acodec"] as? String
            let size = int64(f["filesize"]) ?? int64(f["filesize_approx"])
            if let v = vcodec, v != "none", let h = f["height"] as? Int, h > 0 {
                let rh = roundedHeight(h)
                heights.insert(rh)
                if let size, size > (videoSizeByHeight[rh] ?? 0) {
                    videoSizeByHeight[rh] = size
                }
            }
            if let a = acodec, a != "none", vcodec == nil || vcodec == "none", let size, size > bestAudioSize {
                bestAudioSize = size
            }
        }
        if let h = json["height"] as? Int, h > 0 { heights.insert(roundedHeight(h)) }

        var sizeByHeight: [Int: Int64] = [:]
        for h in heights {
            if let v = videoSizeByHeight[h] { sizeByHeight[h] = v + bestAudioSize }
        }
        let duration = (json["duration"] as? NSNumber)?.doubleValue
        return (title, heights.sorted(by: >), sizeByHeight, duration)
    }

    private static func int64(_ any: Any?) -> Int64? {
        (any as? NSNumber)?.int64Value
    }

    /// Snap odd heights (e.g. 1088, 362) to the familiar rung.
    private static func roundedHeight(_ h: Int) -> Int {
        let rungs = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]
        return rungs.min(by: { abs($0 - h) < abs($1 - h) }) ?? h
    }

    // MARK: Updating the bundled yt-dlp

    /// "Проверить сейчас": checks for a newer stable yt-dlp and installs it
    /// right away (with the same self-check and rollback as the daily automatic update).
    func checkAndUpdateTools() {
        guard !isRunning, !isCheckingToolUpdate else { return }
        guard let ytDlp = ytDlpPath, ToolLocator.isBundled(ytDlp) else { return }
        isCheckingToolUpdate = true
        let start = Date()
        var shownStage = ToolAutoUpdater.Stage.checking
        toolUpdateCheckStatus = Self.toolProgressText(shownStage, since: start)

        // Every step stays on screen long enough to be read: a step that
        // finishes instantly still keeps its line for `minStageDisplay`
        // before the next one (or the result) replaces it. The real work
        // carries on in the background meanwhile.
        var freeAt = Date().addingTimeInterval(Self.minStageDisplay)
        func present(holdFor hold: TimeInterval, _ apply: @escaping () -> Void) {
            let delay = max(0, freeAt.timeIntervalSinceNow)
            freeAt = Date().addingTimeInterval(delay + hold)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply)
        }

        toolProgressTimer?.invalidate()
        toolProgressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.toolUpdateCheckStatus = Self.toolProgressText(shownStage, since: start)
        }

        ToolAutoUpdater.shared.updateNow(ytDlp: ytDlp, knownVersion: ytDlpVersion, onStage: { [weak self] newStage in
            present(holdFor: Self.minStageDisplay) {
                shownStage = newStage
                self?.toolUpdateCheckStatus = Self.toolProgressText(newStage, since: start)
            }
        }, completion: { [weak self] outcome in
            present(holdFor: 0) {
                guard let self else { return }
                self.toolProgressTimer?.invalidate()
                self.toolProgressTimer = nil
                self.isCheckingToolUpdate = false
                let seconds = Int(Date().timeIntervalSince(start).rounded())
                switch outcome {
                case .upToDate(let v):
                    self.ytDlpVersion = v
                    self.toolUpdateCheckStatus = trf("У тебя последняя версия (%@). Проверка заняла %d с.", v, seconds)
                case .updated(let from, let to):
                    self.ytDlpVersion = to
                    self.toolUpdateCheckStatus = trf("Обновлено: %@ → %@ ✅ (за %d с)", from, to, seconds)
                case .keptOld(let current, let rejected):
                    self.toolUpdateCheckStatus = trf("Новая версия %@ не прошла проверку — оставил %@.", rejected, current)
                case .offline:
                    self.toolUpdateCheckStatus = tr("Не удалось проверить обновления — нет связи с интернетом.")
                case .failed:
                    self.toolUpdateCheckStatus = tr("Не удалось проверить обновления.")
                }
            }
        })
    }

    private static let minStageDisplay: TimeInterval = 3

    /// "Шаг 3 из 4 · Скачиваю и ставлю новую версию… · 12 с" (+ how long it usually takes).
    private static func toolProgressText(_ stage: ToolAutoUpdater.Stage, since start: Date) -> String {
        let what: String
        switch stage {
        case .checking:    what = tr("Проверяю на GitHub, вышла ли новая версия…")
        case .downloading: what = tr("Скачиваю новую версию (около 54 МБ) и сверяю контрольную сумму…")
        case .unpacking:   what = tr("Распаковываю новую версию рядом со старой…")
        case .verifying:   what = tr("Проверяю, что новая версия работает с YouTube, и только потом заменяю…")
        }
        let elapsed = Int(Date().timeIntervalSince(start))
        var text = trf("Шаг %d из 4 · %@", stage.rawValue, what) + " · " + trf("%d с", elapsed)
        if stage.rawValue >= ToolAutoUpdater.Stage.downloading.rawValue {
            text += "\n" + tr("Обычно занимает до минуты.")
        }
        return text
    }

    static func captureOutput(_ executablePath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static func fetchLatestYtDlpVersion() -> String? {
        guard let url = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("VideoDownloader-app", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        let semaphore = DispatchSemaphore(value: 0)
        var tag: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            tag = json["tag_name"] as? String
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return tag
    }

    // MARK: Download job

    /// Downloads `urlString` into `destination` as an H.264 `.mp4`, doing
    /// everything automatically:
    ///  - tries without cookies first (fast path for public videos);
    ///  - if the video needs a login, retries with cookies from each installed
    ///    browser (Safari, Chrome, …);
    ///  - remembers the source that worked and tries it first next time;
    ///  - transcodes VP9/AV1 to H.264 after the download if needed.
    ///
    /// With `audioOnly`, downloads the audio track only and converts it to a
    /// 320 kbps MP3 instead (quality is ignored).
    func start(urlString: String,
               destination: URL,
               maxHeight: Int?,
               audioOnly: Bool = false,
               stripAudio: Bool = false,
               videoFormat: VideoFormat = .current,
               audioFormat: AudioFormat = .current) {

        guard !isRunning else { return }

        let url = Self.normalizedURLString(urlString)
        guard !url.isEmpty else {
            phase = .failed(tr("Вставь ссылку на видео."))
            return
        }
        guard ytDlpPath != nil, ffmpegPath != nil else {
            phase = .failed(tr("Внутри программы не хватает файлов. Скачай Scorpena заново."))
            return
        }

        pendingURL = url
        pendingMaxHeight = maxHeight
        pendingAudioOnly = audioOnly
        pendingStripAudio = stripAudio
        pendingVideoFormat = videoFormat
        pendingAudioFormat = audioFormat
        pendingSpeedLimit = SpeedLimit.current
        userPaused = false
        canPause = false
        UnfinishedDownload(url: url, destination: destination.path, maxHeight: maxHeight,
                           audioOnly: audioOnly, stripAudio: stripAudio,
                           videoFormat: videoFormat.rawValue, audioFormat: audioFormat.rawValue,
                           name: nil).save()
        downloadStartTime = Date()
        lastDestination = destination
        lastDownloadedFile = nil
        fragmentedDownload = false
        slowFragmentedSite = url.lowercased().contains("vimeo.")
        needsFullDiskAccess = false
        sawSafariPermissionBlock = false
        downloadAttempt = 0
        transcodeInput = nil
        transcodeOutput = nil
        transcodeDuration = nil

        // Ordered list of things to try. Always start with no cookies — fast and
        // transparent for the vast majority of (public) videos. Only if that
        // fails do we reach for cookies, trying the browser that worked last
        // time first (skips retrying browsers that are known not to be logged in).
        var browsers: [CookieSource] = Self.installedCookieBrowsers().map { .browser($0) }
        if let good = CookieSource.fromStorage(UserDefaults.standard.string(forKey: lastCookieKey) ?? ""),
           browsers.contains(good) {
            browsers.removeAll { $0 == good }
            browsers.insert(good, at: 0)
        }
        cookieQueue = [.none] + browsers

        runNextDownloadAttempt()
    }

    private func runNextDownloadAttempt() {
        guard !cookieQueue.isEmpty,
              let ytDlp = ytDlpPath,
              let ffmpeg = ffmpegPath,
              let destination = lastDestination else { return }

        let source = cookieQueue.removeFirst()
        currentCookieSource = source

        let ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent
        let heightFilter = pendingMaxHeight.map { "[height<=\($0)]" } ?? ""

        func outTemplate(_ name: String) -> String {
            destination.appendingPathComponent(name).path
        }

        runningSpeedLimit = pendingSpeedLimit
        var arguments: [String] = [
            "--newline",
            "--no-color",
            "--no-playlist",
            "--ffmpeg-location", ffmpegDir,
            // Pull DASH/HLS fragments in parallel — big speed-up for Vimeo etc.
            // (With a speed limit, one at a time: yt-dlp applies the limit to each
            // parallel fragment, so five of them would run five times too fast.)
            "--concurrent-fragments", pendingSpeedLimit > 0 ? "1" : "5",
            // A dropped connection isn't an error: wait (1 → 20 s between tries)
            // and carry on from the partial file.
            "--retries", "60", "--fragment-retries", "60",
            "--retry-sleep", "http:exp=1:20", "--retry-sleep", "fragment:exp=1:20",
            "--socket-timeout", "20",
        ] + SpeedLimit.ytDlpArgs(pendingSpeedLimit) + Self.jsRuntimeArgs()
        if pendingAudioOnly {
            arguments += pendingAudioFormat.ytDlpArgs
            arguments += [
                // «Название (Scorpena video downloader).mp3»
                "-o", outTemplate("%(title)s (Scorpena video downloader).%(ext)s"),
            ]
        } else {
            let formatSpec: String
            let sortSpec: String
            if pendingVideoFormat == .webm {
                // WebM: take the site's own WebM streams (VP9/AV1 + Opus) when it has
                // them; anything else is re-encoded into WebM afterwards.
                let hf = heightFilter
                formatSpec = pendingStripAudio
                    ? "bv*[ext=webm]\(hf)/bv*\(hf)/b\(hf)"
                    : "bv*[ext=webm]\(hf)+ba[ext=webm]/bv*\(hf)+ba/b\(hf)/bv*+ba/b"
                sortSpec = "res,vcodec:vp9,br"
            } else if pendingVideoFormat == .mkv {
                // MKV holds anything: the best streams the site has, no H.264 preference.
                let hf = heightFilter
                formatSpec = pendingStripAudio
                    ? (pendingMaxHeight != nil ? "bv*\(hf)/b\(hf)" : "bv*/b")
                    : (pendingMaxHeight != nil ? "bv*\(hf)+ba/b\(hf)/bv*+ba/b" : "bv*+ba/b")
                sortSpec = "res,br"
            } else if pendingStripAudio {
                // Video only, no audio track at all.
                formatSpec = pendingMaxHeight != nil
                    ? "bv*\(heightFilter)/b\(heightFilter)"
                    : "bv*[vcodec^=avc1]/b[vcodec^=avc1]/bv*"
                sortSpec = pendingMaxHeight != nil ? "res,vcodec:h264,ext:mp4,br" : "vcodec:h264,res,ext:mp4,br"
            } else if pendingMaxHeight != nil {
                // Explicit height chosen → take the highest available at/below it,
                // even if that means a VP9/AV1 pick that gets transcoded afterwards.
                formatSpec = "bv*\(heightFilter)+ba/b\(heightFilter)/bv*+ba/b"
                sortSpec = "res,vcodec:h264,ext:mp4,br"
            } else {
                // "Максимальное" → best ready-made H.264 (fast, no re-encode);
                // only fall back to VP9/AV1 if the site has no H.264 at all.
                formatSpec = "bv*[vcodec^=avc1]+ba/b[vcodec^=avc1]/bv*+ba/b"
                sortSpec = "vcodec:h264,res,ext:mp4,br"
            }
            arguments += ["-f", formatSpec, "-S", sortSpec]
            switch pendingVideoFormat {
            case .mp4:  arguments += ["--merge-output-format", "mp4", "--remux-video", "mp4"]
            case .mov:  arguments += ["--merge-output-format", "mov", "--remux-video", "mov"]
            case .mkv:  arguments += ["--merge-output-format", "mkv", "--remux-video", "mkv"]
            case .webm: arguments += ["--merge-output-format", "webm", "--recode-video", "webm"]
            }
            arguments += [
                // «1920x1080 Название (Scorpena video downloader).mp4»
                "-o", outTemplate("%(width)sx%(height)s %(title)s (Scorpena video downloader).%(ext)s"),
            ]
        }
        arguments += source.ytDlpArgs
        arguments.append(pendingURL)

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.toolSearchPath(ytDlp: ytDlp, extraFirst: [ffmpegDir])

        // Only call it "нужен вход" on an actual retry (attempt > 0) — the very
        // first attempt is never announced as a login requirement, even if it
        // happens to use remembered cookies straight away.
        let startStatus = (downloadAttempt == 0)
            ? tr("Скачивание сейчас начнётся…")
            : trf("Нужен вход — пробую %@…", source.describe)

        run(executableURL: URL(fileURLWithPath: ytDlp),
            arguments: arguments,
            environment: env,
            job: .download,
            startStatus: startStatus,
            resetLog: downloadAttempt == 0)

        downloadAttempt += 1
    }

    /// Browsers whose cookies we can try. Safari is always present on macOS;
    /// the others only if their data folder exists.
    static func installedCookieBrowsers() -> [String] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        var out: [String] = ["safari"]
        if fm.fileExists(atPath: "\(home)/Library/Application Support/Google/Chrome") { out.append("chrome") }
        if fm.fileExists(atPath: "\(home)/Library/Application Support/Firefox/Profiles") { out.append("firefox") }
        if fm.fileExists(atPath: "\(home)/Library/Application Support/Yandex/YandexBrowser") { out.append("yandex") }
        return out
    }

    // MARK: Shared process runner

    private func run(executableURL: URL,
                     arguments: [String],
                     environment: [String: String],
                     job: Job,
                     startStatus: String,
                     resetLog: Bool = true) {

        currentJob = job
        progress = 0
        indeterminate = false
        statusLine = startStatus
        if resetLog { log = "" } else { log += "\n— \(startStatus) —\n" }
        lineBuffer.removeAll(keepingCapacity: true)
        phase = .running

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let onData: (FileHandle) -> Void = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(chunk) }
        }
        outPipe.fileHandleForReading.readabilityHandler = onData
        errPipe.fileHandleForReading.readabilityHandler = onData

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self?.finish(status: status, reason: reason)
            }
        }

        self.process = process

        // Binaries shipped inside the .app inherit the download quarantine flag on
        // the recipient's machine; clear it so Gatekeeper lets them execute.
        if ToolLocator.isBundled(executableURL.path),
           let binDir = ToolLocator.bundledBinDirectory {
            Self.clearQuarantine(binDir)
        }

        do {
            try process.run()
        } catch {
            phase = .failed(trf("Не удалось запустить %@: %@", executableURL.lastPathComponent, error.localizedDescription))
            self.process = nil
        }
    }

    /// yt-dlp knows safari/chrome/firefox natively. Yandex Browser is a Chromium
    /// fork it doesn't list, so point the `chrome` reader at its profile directory.
    private static func cookiesBrowserArg(for browser: String) -> String {
        guard browser == "yandex" else { return browser }
        let profile = "\(NSHomeDirectory())/Library/Application Support/Yandex/YandexBrowser"
        return "chrome:\(profile)"
    }

    private static func clearQuarantine(_ path: String) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", path]
        xattr.standardOutput = Pipe()
        xattr.standardError = Pipe()
        try? xattr.run()
        xattr.waitUntilExit()
    }

    // MARK: Output parsing (main queue)

    private func consume(_ chunk: Data) {
        lineBuffer.append(chunk)

        while let newline = lineBuffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<newline)
            lineBuffer.removeSubrange(lineBuffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                handle(line: line)
            }
        }

        if lineBuffer.count > 64_000 {
            lineBuffer.removeAll(keepingCapacity: true)
        }
    }

    private func handle(line: String) {
        appendLog(line)

        if !slowFragmentedSite, line.lowercased().hasPrefix("[vimeo") {
            slowFragmentedSite = true
        }

        if case .transcode = currentJob {
            if let t = Self.parseFFmpegTime(line), let total = transcodeDuration, total > 0 {
                progress = min(t / total, 1)
            }
            statusLine = trf("Перекодирование в H.264… %d%%", Int(progress * 100))
            return
        }

        if line.contains("Retrying") || line.contains("Got error") {
            statusLine = tr("Нет связи — жду и продолжу сам…")
            return
        }

        if let percent = Self.parsePercent(line) {
            canPause = true
            applySpeedLimitIfNeeded()
            progress = min(percent / 100, 1)
            if line.contains("(frag ") { fragmentedDownload = true }
            var s = (pendingAudioOnly ? tr("Скачивание аудио… ") : tr("Скачивание… ")) + "\(Int(percent))%"
            if let eta = Self.parseETA(line) { s += trf(" · осталось %@", eta) }
            if let speed = Self.parseSpeed(line) { s += " · \(speed)" }
            statusLine = s
        } else if line.contains("[ExtractAudio]") {
            canPause = false
            statusLine = pendingAudioFormat.convertingStatus
        } else if line.contains("[Merger]") {
            canPause = false
            statusLine = tr("Объединение видео и звука…")
        } else if line.contains("[VideoRemuxer]") || line.contains("[VideoConvertor]") || line.contains("[Recode]") {
            canPause = false
            statusLine = trf("Упаковка в %@…", pendingVideoFormat.title)
        } else if line.contains("Destination:") {
            rememberFileName(from: line)
            statusLine = pendingAudioOnly ? tr("Скачивание аудио…") : tr("Скачивание…")
        } else if line.lowercased().contains("error") {
            statusLine = line.trimmingCharacters(in: .whitespaces)
        }
    }

    /// "[download] Destination: /…/1920x1080 Name (…).f137.mp4" → "Name" — only
    /// used to say what's unfinished if the app has to ask about it later.
    private func rememberFileName(from line: String) {
        guard let range = line.range(of: "Destination:") else { return }
        var name = (String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) as NSString)
            .lastPathComponent
        name = (name as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: #"\.f\d+$"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: " (Scorpena video downloader)", with: "")
        name = name.replacingOccurrences(of: #"^\d+x\d+ "#, with: "", options: .regularExpression)
        guard !name.isEmpty, var saved = UnfinishedDownload.saved else { return }
        saved.name = String(name.prefix(80))
        saved.save()
    }

    private func appendLog(_ line: String) {
        log += line + "\n"
        if log.count > 120_000 {
            log = "… (начало журнала обрезано) …\n" + log.suffix(90_000)
        }
    }

    private static let percentRegex = try! NSRegularExpression(
        pattern: #"\[download\]\s+([0-9]+(?:\.[0-9]+)?)%"#
    )
    private static let etaRegex = try! NSRegularExpression(
        pattern: #"ETA\s+(\d+:\d{2}(?::\d{2})?)"#
    )
    private static let speedRegex = try! NSRegularExpression(
        pattern: #"at\s+([0-9.]+\s?[KMGT]?i?B/s)"#
    )

    private static func firstGroup(_ line: String, _ regex: NSRegularExpression) -> String? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range),
              let r = Range(m.range(at: 1), in: line) else { return nil }
        return String(line[r])
    }

    static func parseETA(_ line: String) -> String? { firstGroup(line, etaRegex) }
    static func parseSpeed(_ line: String) -> String? { firstGroup(line, speedRegex) }

    static func parsePercent(_ line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = percentRegex.firstMatch(in: line, range: range),
              let captured = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[captured])
    }

    private func finish(status: Int32, reason: Process.TerminationReason) {
        if !lineBuffer.isEmpty, let tail = String(data: lineBuffer, encoding: .utf8) {
            handle(line: tail)
            lineBuffer.removeAll(keepingCapacity: true)
        }
        process = nil
        indeterminate = false

        let job = currentJob

        canPause = false
        if reason == .uncaughtSignal {
            if userPaused, case .download = job {
                userPaused = false
                cookieQueue.removeAll()
                phase = .paused
                if resumeAfterPause {
                    // A new speed limit: carry straight on from the partial file.
                    resumeAfterPause = false
                    let started = restartStartTime
                    resume()
                    if let started { downloadStartTime = started }
                    return
                }
                statusLine = tr("Пауза — нажми «Продолжить»")
                return
            }
            userPaused = false
            phase = .cancelled
            statusLine = tr("Отменено")
            cookieQueue.removeAll()
            if case .transcode = job, let tmp = transcodeOutput {
                try? FileManager.default.removeItem(at: tmp)
            }
            return
        }

        if status == 0 {
            switch job {
            case .download:
                UserDefaults.standard.set(currentCookieSource.storageKey, forKey: lastCookieKey)
                cookieQueue.removeAll()
                if pendingAudioOnly {
                    markVideoFinished(trf("Готово ✅ (%@)", pendingAudioFormat.resultName),
                                      file: newestDownloadedFile(extensions: pendingAudioFormat.fileExtensions))
                } else if pendingVideoFormat.convertsToH264 {
                    checkCodecThenFinish()
                } else {
                    markVideoFinished(tr("Готово ✅"), file: newestDownloadedFile(extensions: VideoFormat.fileExtensions))
                }
            case .transcode:
                finalizeTranscode(ok: true)
            }
            return
        }

        // Non-zero exit.

        if case .transcode = job {
            finalizeTranscode(ok: false)
            return
        }

        if case .download = job {
            let l = log.lowercased()
            let permissionBlocked = l.contains("operation not permitted") && l.contains("cookie")
            if permissionBlocked, case .browser("safari") = currentCookieSource {
                sawSafariPermissionBlock = true
                // Safari needs Full Disk Access — ask for that right away instead
                // of silently burning through the other browsers first.
                cookieQueue.removeAll()
                needsFullDiskAccess = true
                phase = .failed(Self.authWallMessage(fdaBlocked: true))
                statusLine = tr("Нужен доступ к диску")
                return
            }

            let authWall = Self.isAuthWall(l) || permissionBlocked

            if authWall, !cookieQueue.isEmpty {
                appendLog("note: \(currentCookieSource.describe) не подошло — пробую следующий способ")
                runNextDownloadAttempt()
                return
            }

            if authWall {
                if !sawSafariPermissionBlock {
                    DiagnosticReporter.noteDownloadFailure(
                        category: "требуется вход / проверка на бота",
                        host: URL(string: pendingURL)?.host, log: log)
                }
                needsFullDiskAccess = sawSafariPermissionBlock
                phase = .failed(Self.authWallMessage(fdaBlocked: sawSafariPermissionBlock))
                statusLine = tr("Нужен вход в аккаунт")
                return
            }

            if let hint = Self.friendlyDownloadError(in: log) {
                if let category = Self.breakageCategory(in: log) {
                    DiagnosticReporter.noteDownloadFailure(
                        category: category, host: URL(string: pendingURL)?.host, log: log)
                }
                phase = .failed(hint)
                statusLine = tr("Ошибка")
                return
            }
        }

        if case .download = job {
            DiagnosticReporter.noteDownloadFailure(
                category: "неизвестная ошибка", host: URL(string: pendingURL)?.host, log: log)
        }
        phase = .failed(tr("Что-то пошло не так. Попробуй ещё раз или сообщи об ошибке. А пока попробуй другую ссылку."))
        statusLine = tr("Ошибка")
    }

    /// Failures worth counting as "something broke" (vs. a bad link, a
    /// private video or no internet, which are the user's to fix).
    private static func breakageCategory(in log: String) -> String? {
        let l = log.lowercased()
        if l.contains("unable to download") && (l.contains("http error 403") || l.contains("403 forbidden")) {
            return "403 от сайта"
        }
        if l.contains("requested format is not available") { return "не нашёлся формат" }
        return nil
    }

    private static func isAuthWall(_ l: String) -> Bool {
        // YouTube
        (l.contains("confirm you") && l.contains("bot"))
        || l.contains("login_required")
        || l.contains("sign in to confirm your age")
        || l.contains("this video may be inappropriate")
        || l.contains("members-only") || l.contains("join this channel")
        || l.contains("account cookies are no longer valid")
        // VK and generic
        || l.contains("access denied")
        || l.contains("only available for authorized")
        || l.contains("available only for") || l.contains("only for friends")
        || l.contains("please log in") || l.contains("log in to")
        || l.contains("removed from public access")
        // Vimeo
        || l.contains("only works when logged")
        || l.contains("provide account credentials")
        || l.contains("unable to fetch new oauth tokens")
    }

    private static func authWallMessage(fdaBlocked: Bool) -> String {
        if fdaBlocked {
            return tr("""
            Это видео требует входа в аккаунт. Чтобы взять cookies из браузера, приложению нужен \
            доступ к диску. Нажми «Открыть настройки» — в списке приложений найди \
            Scorpena и включи «Полный доступ к диску» (если Scorpena там нет — добавь \
            её кнопкой «+»). Перезапусти приложение и повтори.
            """)
        }
        return tr("""
        Для скачивания требуется вход в аккаунт:

        Сайт отдаёт это видео только при входе в аккаунт. Войди на сайт в браузере и повтори. \
        Например, Vimeo сейчас требует вход почти для всех роликов, даже открытых.
        """)
    }

    // MARK: Auto-transcode to H.264

    /// Sets the finished state for a completed video and plays the chime.
    private func markVideoFinished(_ status: String, file: URL? = nil) {
        progress = 1
        phase = .finished
        if let start = downloadStartTime {
            statusLine = "\(status) · \(Self.formatDuration(Date().timeIntervalSince(start)))"
        } else {
            statusLine = status
        }
        downloadStartTime = nil
        lastDownloadedFile = file
        DiagnosticReporter.noteDownloadSuccess()
        DownloadHistory.shared.record(url: pendingURL, audioOnly: pendingAudioOnly,
                                      ytDlp: ytDlpPath, cookieArgs: currentCookieSource.ytDlpArgs)
        playChime()
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return trf("%d с", s) }
        return trf("%d мин %d с", s / 60, s % 60)
    }

    private func playChime() {
        guard !UserDefaults.standard.bool(forKey: "muteChime") else { return }
        let url = Bundle.main.url(forResource: "DownloadComplete", withExtension: "mp3")
            ?? {
                let home = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                let candidate = home?.appendingPathComponent("download complete.mp3")
                return (candidate.map { FileManager.default.isReadableFile(atPath: $0.path) } == true) ? candidate : nil
            }()
        guard let url else { return }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        player.play()
        chimePlayer = player               // keep a strong ref while it plays
    }

    /// After a successful download, probe the file. If the video isn't H.264
    /// (yt-dlp fell back to VP9/AV1), transcode it — otherwise we're done.
    private func checkCodecThenFinish() {
        progress = 1
        statusLine = tr("Проверка кодека…")

        let file = newestDownloadedFile(extensions: ["mp4", "mkv", "webm", "mov", "m4v"])
        guard let ffmpeg = ffmpegPath, let file else {
            markVideoFinished(tr("Готово ✅"), file: file)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let info = Self.probeVideo(at: file, ffmpeg: ffmpeg)
            DispatchQueue.main.async {
                guard let self else { return }
                let codec = (info.codec ?? "").lowercased()
                if codec.isEmpty || codec == "h264" || codec == "avc1" {
                    self.markVideoFinished(tr("Готово ✅"), file: file)
                } else {
                    self.log += "note: видео в \(codec.uppercased()), перекодирую в H.264\n"
                    self.startTranscode(input: file, duration: info.duration)
                }
            }
        }
    }

    private func startTranscode(input: URL, duration: Double?) {
        guard let ffmpeg = ffmpegPath else {
            markVideoFinished(tr("Готово ✅ (кодек не H.264 — ffmpeg недоступен)"), file: input)
            return
        }

        let output = input.deletingPathExtension()
            .appendingPathExtension("h264." + (input.pathExtension.isEmpty ? "mp4" : input.pathExtension))
        try? FileManager.default.removeItem(at: output)

        transcodeInput = input
        transcodeOutput = output
        transcodeDuration = duration

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\((ffmpeg as NSString).deletingLastPathComponent):/usr/bin:/bin"

        run(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: [
                "-y", "-hide_banner", "-loglevel", "info",
                "-i", input.path,
                "-map", "0:v:0", "-map", "0:a:0?",
                "-c:v", "libx264", "-preset", "medium", "-crf", "20",
                "-pix_fmt", "yuv420p",
                "-c:a", "aac", "-b:a", "192k",
                "-movflags", "+faststart",
                output.path,
            ],
            environment: env,
            job: .transcode,
            startStatus: tr("Перекодирование в H.264…"),
            resetLog: false)
    }

    private func finalizeTranscode(ok: Bool) {
        guard let input = transcodeInput, let output = transcodeOutput else {
            phase = ok ? .finished : .failed(tr("Не удалось перекодировать."))
            return
        }
        let fm = FileManager.default

        if ok, fm.fileExists(atPath: output.path) {
            do {
                try fm.removeItem(at: input)
                try fm.moveItem(at: output, to: input)
                markVideoFinished(tr("Готово ✅ (перекодировано в H.264)"), file: input)
            } catch {
                try? fm.removeItem(at: output)
                markVideoFinished(tr("Готово ✅ (H.264-копию сохранить не удалось, файл в исходном кодеке)"), file: input)
            }
        } else {
            try? fm.removeItem(at: output)
            phase = .failed(trf("Видео скачано (%@), но перекодировать в H.264 не удалось. Файл остался в исходном кодеке.", input.lastPathComponent))
            statusLine = tr("Скачано, но не в H.264")
        }

        transcodeInput = nil
        transcodeOutput = nil
        transcodeDuration = nil
    }

    /// Newest matching file in the download folder (yt-dlp just wrote it).
    private func newestDownloadedFile(extensions: Set<String>) -> URL? {
        guard let dir = lastDestination else { return nil }
        let exts = Set(extensions.map { $0.lowercased() })
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .filter {
                let date = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (date ?? .distantPast) > Date().addingTimeInterval(-600)
            }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
    }

    private static let ffmpegTimeRegex = try! NSRegularExpression(
        pattern: #"time=(\d+):(\d\d):(\d\d(?:\.\d+)?)"#
    )
    private static let ffmpegDurationRegex = try! NSRegularExpression(
        pattern: #"Duration:\s*(\d+):(\d\d):(\d\d(?:\.\d+)?)"#
    )
    private static let ffmpegVideoRegex = try! NSRegularExpression(
        pattern: #"Stream #\d+:\d+.*: Video: (\w+)"#
    )

    private static func parseFFmpegTime(_ line: String) -> Double? {
        parseHMS(line, regex: ffmpegTimeRegex)
    }

    private static func parseHMS(_ line: String, regex: NSRegularExpression) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = regex.firstMatch(in: line, range: range),
              let hR = Range(m.range(at: 1), in: line),
              let mR = Range(m.range(at: 2), in: line),
              let sR = Range(m.range(at: 3), in: line),
              let h = Double(line[hR]), let mm = Double(line[mR]), let s = Double(line[sR])
        else { return nil }
        return h * 3600 + mm * 60 + s
    }

    /// Runs `ffmpeg -i FILE` (which exits non-zero but prints stream info) and
    /// pulls out the video codec and duration.
    private static func probeVideo(at url: URL, ffmpeg: String) -> (codec: String?, duration: Double?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-hide_banner", "-i", url.path]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()

        do { try p.run() } catch { return (nil, nil) }
        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return (nil, nil) }

        var codec: String?
        var duration: Double?
        for line in text.split(separator: "\n").map(String.init) {
            if codec == nil {
                let r = NSRange(line.startIndex..., in: line)
                if let m = ffmpegVideoRegex.firstMatch(in: line, range: r),
                   let cR = Range(m.range(at: 1), in: line) {
                    codec = String(line[cR])
                }
            }
            if duration == nil {
                duration = parseHMS(line, regex: ffmpegDurationRegex)
            }
        }
        return (codec, duration)
    }

    /// Turns yt-dlp's other common failures into a one-line explanation.
    /// (The "needs login" family is handled separately in `finish`.)
    private static func friendlyDownloadError(in log: String) -> String? {
        let l = log.lowercased()

        if l.contains("video unavailable") || l.contains("this video is not available") {
            return tr("Видео недоступно (удалено, приватное или заблокировано в твоём регионе).")
        }
        if l.contains("is not a valid url") || l.contains("unsupported url") {
            return tr("Ссылка не распознана или сайт не поддерживается. Нужен прямой адрес страницы видео (YouTube, VK и т.д.).")
        }
        if l.contains("requested format is not available") {
            return tr("Не нашёлся формат под выбранное качество — попробуй «Максимальное».")
        }
        if l.contains("unable to download") && (l.contains("http error 403") || l.contains("403 forbidden")) {
            return tr("YouTube отклонил загрузку (403). Открой «Дополнительно» → «Проверить сейчас», затем повтори. Или попробуй другую ссылку.")
        }
        if l.contains("unable to resolve host") || l.contains("network is unreachable") || l.contains("connection refused") {
            return tr("Нет соединения с интернетом.")
        }
        return nil
    }
}
