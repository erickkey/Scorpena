import SwiftUI
import AppKit
import AVFoundation

struct ContentView: View {

    @StateObject private var manager = DownloadManager()
    @ObservedObject private var queue = DownloadQueue.shared
    @StateObject private var updateChecker = UpdateChecker()
    @StateObject private var windowFitter = MainWindowFitter()
    @State private var updateGlow = false
    @State private var showAccessHint = false
    @State private var playlistStatus: String?
    @AppStorage("accessHintShown") private var accessHintShown = false
    @State private var hoveringVersion = false
    @State private var launchSoundPlayer: AVAudioPlayer?
    @State private var shareAnchorView: NSView?

    @AppStorage("destinationFolder") private var destinationPath: String =
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path)
        ?? NSHomeDirectory()

    @AppStorage("muteLaunchSound") private var muteLaunchSound = false
    @AppStorage("videoNoAudio") private var videoNoAudio = false
    @AppStorage(VideoFormat.key) private var videoFormat = VideoFormat.mp4.rawValue
    @AppStorage(AudioFormat.key) private var audioFormat = AudioFormat.mp3.rawValue
    @AppStorage("downloadMode") private var downloadMode = "video"      // video | audio — what «Скачать» saves
    @AppStorage("lastSeenChangelogVersion") private var lastSeenChangelogVersion = ""
    @AppStorage("appearance") private var appearance = "auto"   // auto | light | dark
    @ObservedObject private var languageSettings = LanguageSettings.shared   // unused directly — just
                                                                 // makes SwiftUI re-render this view (and
                                                                 // every tr()/trf() call in it) when the
                                                                 // language changes anywhere in the app.

    @State private var urlString = ""
    @State private var lastSeenPasteboardChange = -1
    /// Clipboard state when a link went into the queue — that same link must
    /// not be pasted back into the freshly emptied field.
    @State private var clipboardChangeAtQueue = -1
    enum ErrorReportStatus: Equatable { case idle, sending, sent, failed }
    @State private var errorReportStatus: ErrorReportStatus = .idle
    @State private var lastErrorReportNumber: Int?
    @AppStorage("errorReportCounter") private var errorReportCounter = 0
    @State private var runStartTime: Date?
    @State private var batchStartTime: Date?

    // 0 = «Максимальное»; otherwise a height in px.
    @AppStorage("qualityHeight") private var qualityHeight = 0

    /// Heights offered in the picker — empty (just "Максимально доступное")
    /// until a probe actually confirms what's available.
    private var qualityOptions: [Int] { manager.availableHeights }

    private func qualityLabel(_ h: Int) -> String {
        switch h {
        case 2160: return "2160p (4K)"
        case 1440: return "1440p (2K)"
        default:   return "\(h)p"
        }
    }

    /// "Максимальное" (0) shows the size of the best probed height; otherwise
    /// the size for that exact height, if the probe found one.
    private func approxSizeText(for height: Int) -> String? {
        let h = height == 0 ? manager.availableHeights.first : height
        guard let h, let bytes = manager.approxSizeByHeight[h] else { return nil }
        return "≈ " + Self.formatBytes(bytes)
    }

    /// Label shown inside the quality dropdown itself — quality + size, so
    /// every option shows its weight, not just the currently picked one.
    private func qualityMenuLabel(_ h: Int) -> String {
        if let text = approxSizeText(for: h) { return "\(qualityLabel(h)) — \(text)" }
        return qualityLabel(h)
    }

    private var maxOptionMenuLabel: String {
        guard !manager.availableHeights.isEmpty else { return tr("Максимально доступное") }
        if let text = approxSizeText(for: 0) { return trf("Максимальное — %@", text) }
        return tr("Максимальное")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        if mb >= 1000 { return String(format: tr("%.2f ГБ"), mb / 1000) }
        return String(format: tr("%.0f МБ"), mb)
    }

    private var destinationURL: URL { URL(fileURLWithPath: destinationPath) }

    /// File extensions that mean "this is a file, not a domain" when they
    /// show up where a TLD would be (bare filenames people paste by mistake).
    private static let nonDomainExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff", "heic", "svg",
        "mp4", "mov", "avi", "mkv", "webm", "flv", "wmv", "m4v",
        "mp3", "wav", "aac", "flac", "m4a", "ogg",
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf",
        "zip", "rar", "7z", "tar", "gz",
    ]

    /// Returns the parsed URL for anything that plausibly points at a video
    /// page — a full http(s) link, or the shorthand people actually
    /// type/paste, like "www.site.com/…" or a bare "site.com/…" with no
    /// scheme at all — nil otherwise.
    private static func urlIfPlausible(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        let hasHTTPScheme = URL(string: trimmed)
            .flatMap(\.scheme)
            .map { $0.lowercased() == "http" || $0.lowercased() == "https" } ?? false
        let candidate = hasHTTPScheme ? trimmed : "https://" + trimmed

        guard let url = URL(string: candidate),
              let host = url.host, host.contains("."), !host.contains("_"),
              let tld = host.split(separator: ".").last.map(String.init),
              tld.count >= 2, tld.allSatisfy({ $0.isLetter }),
              !nonDomainExtensions.contains(tld.lowercased())
        else { return nil }
        return url
    }

    private static func isPlausibleURLString(_ raw: String) -> Bool {
        urlIfPlausible(raw) != nil
    }

    private var isPlausibleURL: Bool { Self.isPlausibleURLString(urlString) }

    /// Soft signal only — yt-dlp has no real "unsupported site" concept (an
    /// unrecognized domain just falls through to its generic page-scraping
    /// extractor), so this never blocks a download. It only flags that the
    /// domain isn't one of the ~1150 sites with their own dedicated parser,
    /// worth a gentle heads-up and nothing stronger.
    private var isKnownSite: Bool {
        guard let host = Self.urlIfPlausible(urlString)?.host else { return true }
        return SupportedSites.isKnown(host: host)
    }

    /// True when the link has nothing after the domain — just
    /// "twitch.tv" or "youtube.com/", not an actual video/channel/clip
    /// page. Pasting a bare homepage is a common mistake and, unlike an
    /// unrecognized site, this one *is* checkable offline with confidence.
    private var isBareHomepage: Bool {
        guard let url = Self.urlIfPlausible(urlString) else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty && (url.query?.isEmpty ?? true)
    }

    private var canDownload: Bool {
        isPlausibleURL
        && updateChecker.installState == .idle
        && manager.toolsReady
        && !manager.isProbing
    }

    /// `ViewThatFits(in: .vertical)` was tried here to pick a roomy layout
    /// vs. a tighter one before falling back to scrolling — it turned out to
    /// misjudge whether the tighter layout actually fits (confirmed by an
    /// actual clipped footer in testing), so it's not safe to rely on. A
    /// plain ScrollView is the one approach that's provably correct: nothing
    /// is ever cut off, whatever the window height, at the cost of an
    /// occasional scroll when a window is unusually short.
    var body: some View {
        ScrollView {
            mainContent(spacing: 16)
                .background(AlwaysVisibleScroller())
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .onPreferenceChange(ContentHeightKey.self) { windowFitter.fit(toContent: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    DownloadsPanel.shared.show(manager: manager) { picked in urlString = picked }
                } label: {
                    Image(systemName: "list.bullet")
                        .overlay(alignment: .topTrailing) {
                            let count = queue.items.count + queue.busyCount
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(Color.red))
                                    .offset(x: 8, y: -6)
                            }
                        }
                }
                .help(tr("Загрузки"))
                Button {
                    AdvancedSettingsPanel.shared.show(manager: manager)
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(tr("Дополнительно"))
                Button {
                    appearance = (appearance == "dark") ? "light" : "dark"
                } label: {
                    Image(systemName: appearance == "dark" ? "sun.max" : "moon")
                }
                .help(tr("Светлая / тёмная тема"))
            }
        }
        .background(WindowAccessor { windowFitter.window = $0 })
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // A specific resolution picked in a past probe (persisted across
            // launches) has no matching option until this video is probed
            // too — reset it so the picker shows "Максимально доступное"
            // instead of appearing blank.
            if qualityHeight != 0, !manager.availableHeights.contains(qualityHeight) {
                qualityHeight = 0
            }
            AdvancedSettingsPanel.shared.manager = manager
            queue.attach(manager)
            if queue.batchActive { batchStartTime = Date() }
            Cleanup.checkOnLaunch(queue: queue)
            manager.refreshTools()
            manager.autoUpdateToolsIfDue()
            if appearance == "auto" {
                appearance = Self.systemIsDark() ? "dark" : "light"
            }
            applyAppearance()
            updateChecker.check()
            playLaunchSound()
            fillURLFromClipboard()
            DispatchQueue.main.async {
                runLaunchWindowSequenceWhenActive()
            }
        }
        .onChange(of: appearance) { _ in applyAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            fillURLFromClipboard()
            updateChecker.check()
        }
        .onChange(of: manager.progress) { _ in updateDockProgress() }
        .onChange(of: queue.batchDone) { _ in updateDockProgress() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if queue.batchActive { updateDockProgress() }
        }
        .onChange(of: manager.isRunning) { running in
            updateDockProgress()
            runStartTime = running ? Date() : nil
        }
        .onChange(of: queue.batchActive) { active in
            batchStartTime = active ? (batchStartTime ?? Date()) : nil
        }
    }

    private func mainContent(spacing: CGFloat) -> some View {
        VStack(spacing: 18) {
            brandRow
            VStack(spacing: 14) {
                urlField
                formatRow
                settingsLine
            }
            .frame(maxWidth: 560)
            progressSection
                .frame(maxWidth: 560)
            if manager.needsFullDiskAccess || showAccessHint { fullDiskAccessBanner }
            if !manager.toolsReady { missingToolsBanner }
            footer
        }
        .padding(EdgeInsets(top: 22, leading: 28, bottom: 20, trailing: 28))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// Creating and ordering-front a new `NSWindow` (the language picker,
    /// "what's new") *before* the app has actually finished becoming the
    /// active app can leave that window self-reporting as visible/key while
    /// the WindowServer never actually composites it on screen — seen
    /// directly while testing a cold, first-ever launch (Gatekeeper's
    /// "downloaded from the internet" flow makes launch slower and less
    /// predictable than a plain local relaunch). Waiting for
    /// `didBecomeActiveNotification` when the app isn't active yet sidesteps
    /// the race instead of assuming `onAppear` already means it's safe.
    private func runLaunchWindowSequenceWhenActive() {
        guard NSApp.isActive else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                if let observer { NotificationCenter.default.removeObserver(observer) }
                runLaunchWindowSequenceNow()
            }
            return
        }
        runLaunchWindowSequenceNow()
    }

    private func runLaunchWindowSequenceNow() {
        applyInitialWindowSizeIfNeeded()
        if let result = updateChecker.takeLaunchResult() {
            UpdatePanel.shared.show(result, onClosed: { continueLaunchWindowSequence() })
        } else {
            continueLaunchWindowSequence()
        }
    }

    private func continueLaunchWindowSequence() {
        if AppRenamer.shouldShowNotice {
            UpdatePanel.shared.showRenameNotice(canRename: AppRenamer.canRename,
                                                onClosed: { continueAfterRenameNotice() })
        } else {
            continueAfterRenameNotice()
        }
    }

    private func continueAfterRenameNotice() {
        if LanguagePickerPanel.shouldShowOnLaunch {
            LanguagePickerPanel.shared.show(onDismiss: { showWhatsNewIfNeeded() })
        } else {
            showWhatsNewIfNeeded()
        }
    }

    /// The user's preferred window shape. Resizing afterwards is completely
    /// free (no locked aspect ratio) — this only picks the size the window
    /// opens at.
    private static let preferredWindowSize = NSSize(width: 640, height: 470)

    /// Sizes the window once at launch to `preferredWindowSize`, scaled down
    /// to fit a smaller screen if needed. The aspect ratio always wins over
    /// the literal pixel size, so it never overflows a small display.
    /// Resizing afterwards is completely free and is never remembered
    /// across launches — every launch opens at the same size on purpose.
    private func applyInitialWindowSizeIfNeeded() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // Matches the fix already applied to every other window in the app
        // (InfoPanel, AdvancedSettingsPanel, etc.) — macOS silently persists
        // and later restores this window's frame on its own otherwise,
        // fighting whatever size we set here.
        window.isRestorable = false

        var target = Self.preferredWindowSize
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let margin: CGFloat = 60
            let scale = min(1, (visible.width - margin) / target.width, (visible.height - margin) / target.height)
            if scale < 1 {
                target = NSSize(width: target.width * scale, height: target.height * scale)
            }
        }

        // `target` is a *content* size — it mirrors the `idealWidth`/
        // `idealHeight` declared on ContentView's `.frame()` in
        // YouTubeDownloaderApp.swift, which SwiftUI treats as content size,
        // not the outer window frame. `setContentSize` maps that correctly;
        // writing it straight into `window.frame.size` used to leave the
        // content ~28pt (a title bar's height) short of its declared
        // minHeight.
        window.setContentSize(target)
        window.centerExactlyOnScreen()
        windowFitter.window = window
        windowFitter.setBase(contentHeight: window.contentLayoutRect.height)
    }

    /// Draws a thin progress bar over the app's Dock icon while a download runs.
    private func updateDockProgress() {
        if queue.batchActive {
            // Several downloads: the bar shows the whole list, not the one on the main window.
            NSApp.dockTile.contentView = DockProgressView(progress: queue.batchFraction())
        } else if manager.isRunning {
            NSApp.dockTile.contentView = DockProgressView(progress: manager.progress)
        } else {
            NSApp.dockTile.contentView = nil
        }
        NSApp.dockTile.display()
    }

    /// Plays a short sound once, when the app first launches.
    private func playLaunchSound() {
        guard !muteLaunchSound,
              let url = Bundle.main.url(forResource: "AppLaunch", withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else { return }
        player.prepareToPlay()
        player.play()
        launchSoundPlayer = player   // keep a strong ref while it plays
    }

    /// Shows the "what's new" panel once per version, right after an update.
    /// `lastSeenChangelogVersion` is only written once the user actually
    /// clicks the button under the list (`onAcknowledge`) — not the instant
    /// `.show()` is called — so if the window is ever created but somehow
    /// never reaches the user (any future rendering hiccup, a launch that
    /// gets interrupted, …), it simply shows again next launch instead of
    /// silently burning its one chance.
    private func showWhatsNewIfNeeded() {
        guard let version = Self.appVersionString, version != lastSeenChangelogVersion,
              Self.changelog[version] != nil
        else {
            offerUnfinishedDownload()
            return
        }
        WhatsNewPanel.shared.show(version: version, closeTitle: tr("Круто"), onAcknowledge: {
            lastSeenChangelogVersion = version
            offerUnfinishedDownload()
        })
    }

    /// The last session ended in the middle of a download (paused, or the app
    /// was closed): offer to carry on — yt-dlp continues from the partial file.
    private func offerUnfinishedDownload() {
        guard !manager.isRunning, !manager.isPaused, manager.toolsReady,
              let saved = UnfinishedDownload.saved else { return }
        // The queue brought it back by itself — nothing to ask.
        if DownloadQueue.shared.restoredURLs.contains(saved.url) {
            UnfinishedDownload.clear()
            return
        }
        let alert = NSAlert()
        alert.messageText = tr("Скачивание не закончилось")
        alert.informativeText = trf("Не докачано: %@. Продолжить с того места, где остановилось?", saved.displayName)
        alert.addButton(withTitle: tr("Продолжить"))
        alert.addButton(withTitle: tr("Не нужно"))
        if alert.runModal() == .alertFirstButtonReturn {
            urlString = saved.url
            manager.resume(saved)
        } else {
            UnfinishedDownload.clear()
        }
    }

    /// Drops a link from the clipboard into the field: always when the
    /// clipboard has changed since we last looked (so a freshly copied link
    /// replaces the previous one), and, as before, when the field is empty.
    /// An unchanged clipboard never overwrites what's already typed.
    private func fillURLFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != clipboardChangeAtQueue else { return }
        let clipboardIsNew = pasteboard.changeCount != lastSeenPasteboardChange
        lastSeenPasteboardChange = pasteboard.changeCount

        let fieldIsEmpty = urlString.trimmingCharacters(in: .whitespaces).isEmpty
        guard clipboardIsNew || fieldIsEmpty else { return }

        // Copying an image (e.g. "Copy Image" in a browser) often also puts
        // the image's own URL on the pasteboard as plain text — that's not
        // a video link, so skip auto-fill entirely when there's image data.
        guard !pasteboard.canReadItem(withDataConformingToTypes: ["public.image"]) else { return }
        guard let clip = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isPlausibleURLString(clip),
              clip != urlString
        else { return }
        urlString = clip
    }

    // MARK: Appearance

    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    private static func systemIsDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static let appVersionString: String? =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    /// Shown once, the first time a given version launches. Add a new entry
    /// with every release that has user-visible changes.
    /// A festive heading (and a line under it) shown above the list for versions that have one.
    static let changelogHeadlines: [String: (intro: String, name: String, subtitle: String)] = [
        "3.1.1": ("Встречайте! Новое название и новый дизайн!",
                  "Scorpena – video downloader",
                  "Новый облик, новые возможности, и всё работает лучше и быстрее, чем раньше."),
        "3.1": ("Встречайте! Новое название и новый дизайн!",
                "Scorpena – video downloader",
                "Новый облик, новые возможности, и всё работает лучше и быстрее, чем раньше."),
        "3.0": ("Встречайте! Теперь у программы есть название!",
                "Scorpena – video downloader",
                "Новый облик, новые возможности, и всё работает лучше, чем раньше."),
    ]

    /// A thin line after this many items, to set a fix apart from the rest of the list.
    static let changelogDividerAfter: [String: Int] = ["3.1.1": 1]

    /// A call to action shown under the list, highlighted so it isn't missed.
    static let changelogCallouts: [String: String] = [:]

    static let changelog: [String: [String]] = [
        "3.1.1": [
            "Исправлена ошибка при скачивании, когда мешает VPN или нет интернета.",
            "Можно качать несколько видео сразу.",
            "Скачивание плейлистов.",
            "Новое окно «Загрузки»: очередь и история в одном месте.",
            "Очередь и пауза запоминаются при закрытии программы.",
            "Теперь доступен выбор формата видео и звука.",
            "Скачивание и проверка качества стали гораздо быстрее.",
            "Ограничение скорости скачивания. (нажми на шестеренку справа вверху)",
            "Если для видео нужен вход в аккаунт, Scorpena подскажет, что делать.",
            "Напоминание об очистке старой истории и недокачанных файлов.",
            "Множество мелких улучшений и исправлений.",
        ],
        "3.1": [
            "Можно качать несколько видео сразу.",
            "Скачивание плейлистов.",
            "Новое окно «Загрузки»: очередь и история в одном месте.",
            "Очередь и пауза запоминаются при закрытии программы.",
            "Теперь доступен выбор формата видео и звука.",
            "Скачивание и проверка качества стали гораздо быстрее.",
            "Ограничение скорости скачивания. (нажми на шестеренку справа вверху)",
            "Если для видео нужен вход в аккаунт, Scorpena подскажет, что делать.",
            "Напоминание об очистке старой истории и недокачанных файлов.",
            "Множество мелких улучшений и исправлений.",
        ],
        "3.0": [
            "Теперь доступен выбор формата видео и звука.",
            "Появилась возможность паузы и докачки видео даже после закрытия программы.",
            "Ограничение скорости скачивания. (нажми на шестеренку справа вверху)",
            "Скачивание и проверка качества стали гораздо быстрее.",
            "Множество мелких улучшений и исправлений.",
        ],
        "2.1": [
            "Обновление программы теперь одной кнопкой (наконец-то).",
            "Встроенный загрузчик обновляется сам.",
            "История скачиваний.",
            "Поправлен баг – новая скопированная ссылка теперь сама заменяет старую.",
            "Анонимные отчёты о сбоях теперь автоматические (отключаются в «Дополнительно»).",
            "Мелкие внутренние улучшения и исправления.",
        ],
        "2.0": [
            "Отдельные кнопки «Скачать видео» и «Скачать звук» вместо одной галочки.",
            "Новая галочка «Скачать видео без звука».",
            "Проверка качества видео — размер файла виден для каждого варианта.",
            "Понимает ссылки в любом виде и предупреждает, если это не похоже на ссылку.",
            "Автоподстановка ссылки из буфера обмена.",
            "Таймер во время скачивания и показ итогового времени в конце.",
            "«Сообщить об ошибке» — если скачивание не удалось, можно одной кнопкой отправить мне отчёт.",
            "Выбор языка (русский/английский) — при первом запуске, и в любой момент в «Дополнительно».",
            "«Дополнительно» — теперь отдельное окно, а не выпадающий список внизу.",
            "«Поделиться» — можно быстро отправить другу ссылку на программу.",
            "Обновление встроенных инструментов — понятный раздел: «Проверить обновление» показывает, есть ли новая версия, кнопка «Обновить» активна только когда реально есть что обновлять.",
            "«Обратная связь» — отдельный раздел: написать вопрос, пожелание или что угодно ещё, по желанию оставив имя и контакт.",
            "Версия программы видна в шапке окна.",
            "Технический журнал скрыт от пользователя.",
            "Мелкие внутренние улучшения и исправления.",
        ],
    ]

    // MARK: Sections

    /// Logo and name, centred. The version is a link to the list of changes.
    private var brandRow: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("SCORPENA")
                        .font(.title2.bold())
                    if let version = Self.appVersionString {
                        Button {
                            WhatsNewPanel.shared.show(version: version, closeTitle: tr("Закрыть"), onAcknowledge: {})
                        } label: {
                            Text("(v.\(version))")
                                .font(.caption2)
                                .underline(hoveringVersion)
                                .foregroundStyle(hoveringVersion ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(tr("Список изменений"))
                        .onHover { inside in
                            hoveringVersion = inside
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                }
                Text("video downloader")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The link row plus signature can outgrow a narrow window (more so now
    /// with 4 links) — `ViewThatFits` reflows it onto two lines instead of
    /// letting the single-row HStack overflow and get clipped by the window
    /// edge (there's no horizontal scroll to reveal what got cut off).
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 14) {
                footerLinks
                Spacer()
                footerSignature
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) { footerLinks }
                HStack { Spacer(); footerSignature }
            }
        }
        .font(.caption)
    }

    private var footerLinks: some View {
        Group {
            Button(tr("О программе")) { InfoPanel.about.show() }
                .buttonStyle(.link)
            Button(tr("Правовая информация")) { InfoPanel.legal.show() }
                .buttonStyle(.link)
            Button(tr("Обратная связь")) { InfoPanel.feedback.show() }
                .buttonStyle(.link)
            Button(tr("Поделиться")) { ShareHelper.shared.share(from: shareAnchorView) }
                .buttonStyle(.link)
                .background(ViewAnchor { shareAnchorView = $0 })
            Button(tr("Поддержать")) { DonateLink.open() }
                .buttonStyle(.link)
        }
    }

    private var footerSignature: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if updateChecker.updateAvailable {
                Button {
                    updateChecker.startUpdate(downloadInProgress: manager.isRunning)
                } label: {
                    Text(tr("Доступно обновление") + (updateChecker.latestVersion.map { " (\($0))" } ?? ""))
                        .font(.caption2.bold())
                        .foregroundStyle(updateChecker.installState != .idle || updateGlow
                                         ? Color.secondary : Color.red)
                }
                .buttonStyle(.plain)
                .disabled(updateChecker.installState != .idle)
                .onAppear {
                    // Slow on purpose (about 3 s per red→gray→red cycle): it
                    // should catch the eye without nagging.
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        updateGlow = true
                    }
                }
            }
            Text("by Yaroslav Lukyanov")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var urlField: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField(tr("Вставь ссылку на видео"), text: $urlString)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .disableAutocorrection(true)
                    .onSubmit { if canDownload { startDownload(audioOnly: downloadMode == "audio") } }
                    .onChange(of: urlString) { _ in
                        manager.resetProbe()
                        showAccessHint = false
                    }
                Button {
                    startDownload(audioOnly: downloadMode == "audio")
                } label: {
                    // Dark pill with light text when it can be pressed; a soft grey
                    // pill with clearly readable grey text when it can't.
                    Text(tr("Скачать"))
                        .fontWeight(.medium)
                        .foregroundColor(canDownload ? Color(nsColor: .windowBackgroundColor) : Color.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(canDownload ? Color.primary : Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(!canDownload)
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))

            // Always renders (blank when not applicable) so this row's
            // height is reserved up front — showing/hiding it used to shove
            // everything below it up and down as you typed.
            let hasText = !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let showURLWarning = hasText && !isPlausibleURL
            let showHomepageHint = hasText && isPlausibleURL && isBareHomepage
            let showKnownSiteHint = hasText && isPlausibleURL && !isBareHomepage && isKnownSite
            let showUnknownSiteHint = hasText && isPlausibleURL && !isBareHomepage && !isKnownSite
            HStack(spacing: 10) {
                Text(showURLWarning ? tr("Кажется, это не ссылка — проверь, что скопировалось")
                     : showHomepageHint ? tr("Это главная страница сайта, а не ссылка на видео")
                     : showKnownSiteHint ? tr("Сайт есть в списке поддерживаемых ✅")
                     : showUnknownSiteHint ? tr("Необычный сайт — программа попробует, но результат не гарантирован")
                     : " ")
                    .foregroundStyle(showURLWarning || showHomepageHint ? .red : showKnownSiteHint ? .green : .orange)
                    .opacity(showURLWarning || showHomepageHint || showKnownSiteHint || showUnknownSiteHint ? 1 : 0)
                    .layoutPriority(1)
                if let playlistStatus { Text(playlistStatus).foregroundStyle(.secondary) }
                Text(manager.probedTitle.map { "▸ \($0)" } ?? " ")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(manager.probedTitle == nil ? 0 : 1)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    /// One choice for the whole download: pick a video container or an audio
    /// format, and «Скачать» saves exactly that.
    private var formatRow: some View {
        return HStack(spacing: 20) {
            FormatSegments(title: tr("Видео"),
                           options: VideoFormat.allCases.map { ($0.rawValue, $0.title) },
                           selected: videoFormat,
                           active: downloadMode == "video",
                           disabled: false) { picked in
                videoFormat = picked
                downloadMode = "video"
            }
            FormatSegments(title: tr("Звук"),
                           options: AudioFormat.allCases.map { ($0.rawValue, $0.title) },
                           selected: audioFormat,
                           active: downloadMode == "audio",
                           disabled: false) { picked in
                audioFormat = picked
                downloadMode = "audio"
            }
        }
    }

    private var folderName: String {
        let name = URL(fileURLWithPath: destinationPath).lastPathComponent
        return name.isEmpty ? destinationPath : name
    }

    private var qualityLabel: String {
        qualityHeight == 0 ? maxOptionMenuLabel : qualityMenuLabel(qualityHeight)
    }

    /// Quality · folder · "no audio" in one quiet line. Downloading never
    /// requires any of it — «Скачать» works straight off the link.
    private var settingsLine: some View {
        return HStack(spacing: 8) {
            Toggle(tr("без звука"), isOn: $videoNoAudio)
                .toggleStyle(.checkbox)
                .disabled(downloadMode == "audio")
            Text("·")
            Menu {
                // Already checked for this link (the result is dropped when the link changes).
                Button(tr("Проверить качество")) { manager.probeQuality(urlString: urlString) }
                    .disabled(!isPlausibleURL || manager.isProbing || !manager.availableHeights.isEmpty)
                Divider()
                Button { qualityHeight = 0 } label: {
                    if qualityHeight == 0 { Label(maxOptionMenuLabel, systemImage: "checkmark") } else { Text(maxOptionMenuLabel) }
                }
                ForEach(qualityOptions, id: \.self) { h in
                    Button { qualityHeight = h } label: {
                        if qualityHeight == h { Label(qualityMenuLabel(h), systemImage: "checkmark") } else { Text(qualityMenuLabel(h)) }
                    }
                }
            } label: {
                if manager.isProbing {
                    HStack(spacing: 6) { Text(tr("Качество:")).font(.caption); ProgressView().controlSize(.small) }
                } else {
                    Text(tr("Качество:") + " " + qualityLabel).font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(tr("Необязательно — можно сразу нажать «Скачать».\nПроверка займёт немного времени, зато сразу покажет все доступные варианты качества и размер файла."))
            .onChange(of: manager.availableHeights) { heights in
                if qualityHeight != 0, !heights.contains(qualityHeight) {
                    qualityHeight = 0
                }
            }

            Text("·")
            Button { chooseFolder() } label: {
                Text(tr("Папка:") + " " + folderName)
            }
            .buttonStyle(.plain)
            .help(destinationPath)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var progressSection: some View {
        if queue.batchActive {
            batchProgressSection
        } else {
            singleProgressSection
        }
    }

    /// Several downloads at once: one common bar and a line that opens the queue.
    private var batchProgressSection: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: queue.batchFraction())
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    // The running time comes first, the same «the app hasn't frozen» sign as with one download.
                    Text(Self.elapsedText(context.date.timeIntervalSince(batchStartTime ?? context.date)) + " · "
                         + trf("Загрузок идёт: %d · в очереди: %d · готово: %d",
                               queue.busyCount, queue.items.count, queue.batchDone))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(tr("Открыть очередь")) {
                        DownloadsPanel.shared.show(manager: manager, tab: .queue) { picked in urlString = picked }
                    }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
        }
    }

    /// «45 с» up to a minute, then «2:05».
    private static func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total) " + tr("с") : String(format: "%d:%02d", total / 60, total % 60)
    }

    private var singleProgressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if manager.isRunning && manager.indeterminate {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: manager.progress)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(manager.statusLine.isEmpty ? " " : manager.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if manager.isPaused {
                    Button(tr("Продолжить")) { manager.resume() }
                } else {
                    Button(tr("Пауза")) { manager.pause() }
                        .disabled(!(manager.isRunning && manager.canPause))
                }
                Button(tr("Отменить")) { manager.cancel() }
                    .disabled(!(manager.isRunning || manager.isPaused))
                Button(tr("Показать файл")) {
                    if let file = manager.lastDownloadedFile {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
                .disabled(manager.lastDownloadedFile == nil)
            }
            .buttonStyle(.plain)
            .font(.caption)

            // A running counter under the status line — so a long, quiet
            // wait (transcode, download not yet started)
            // still visibly shows the app is working, not stuck.
            if manager.isRunning, let start = runStartTime {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(start))) " + tr("с"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Compares against the same tr() call DownloadManager used to
            // build statusLine, so the match works regardless of language.
            if manager.isRunning && manager.statusLine.hasPrefix(tr("Скачивание сейчас начнётся…")) {
                Text(tr("Программа запрашивает у сайта данные о видео: адреса потоков и способ обхода защиты. Обычно 2–10 секунд."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if manager.isRunning && manager.fragmentedDownload && manager.slowFragmentedSite {
                Text(tr("Сайт отдаёт видео множеством мелких кусков, а не одним файлом — их приходится качать по очереди, поэтому медленнее обычного. У Vimeo почти всегда так."))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case let .failed(message) = manager.phase {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Button {
                        reportError(message)
                    } label: {
                        if errorReportStatus == .sending {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(tr("Сообщить об ошибке"))
                        }
                    }
                    .controlSize(.small)
                    .disabled(errorReportStatus == .sending || errorReportStatus == .sent)

                    switch errorReportStatus {
                    case .idle, .sending:
                        EmptyView()
                    case .sent:
                        Text(trf("Отправлено (обращение №%@) — спасибо!", lastErrorReportNumber.map(String.init) ?? "?"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    case .failed:
                        Text(tr("Не удалось отправить — текст скопирован, отправь вручную в Telegram"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var fullDiskAccessBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tr("Нужен доступ к диску"), systemImage: "lock.shield")
                .font(.callout.bold())
            Text(tr("Чтобы программа могла показать сайту, что ты не робот, используя куки."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(tr("Открыть настройки")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.5)))
    }

    private var missingToolsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(tr("Внутри программы не хватает файлов"), systemImage: "exclamationmark.triangle")
                .font(.callout.bold())
            Text(tr("Скачай Scorpena заново: все файлы встанут на место, настройки и история сохранятся."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(tr("Открыть страницу загрузки")) {
                if let url = URL(string: "https://github.com/erickkey/Scorpena/releases/latest") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.4)))
    }

    // MARK: Actions

    private func startDownload(audioOnly: Bool) {
        errorReportStatus = .idle
        if !accessHintShown && !DownloadManager.hasDiskAccess {
            accessHintShown = true
            showAccessHint = true
        }
        if let list = PlaylistLink.detect(urlString) {
            askAboutPlaylist(list, audioOnly: audioOnly)
        } else {
            submitCurrentLink(audioOnly: audioOnly)
        }
    }

    /// A link with a playlist in it: read the playlist first (so the question can
    /// say how many videos it has), then ask — the whole playlist or just the one video?
    private func askAboutPlaylist(_ list: PlaylistLink, audioOnly: Bool) {
        guard let ytDlp = manager.ytDlpPath, playlistStatus != tr("Читаю плейлист…") else { return }
        playlistStatus = tr("Читаю плейлист…")
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlaylistLink.fetch(listURL: list.listURL, ytDlp: ytDlp)
            DispatchQueue.main.async {
                playlistStatus = nil
                if result == nil { playlistUnreadable() }
                guard result != nil || list.hasVideo else { return }
                presentPlaylistQuestion(list, result: result, audioOnly: audioOnly)
            }
        }
    }

    /// The playlist can't be read: either it needs a sign-in (private, or the site wants proof
    /// that this is not a robot) or it doesn't exist. Asks for disk access only when it's missing.
    private func playlistUnreadable() {
        playlistStatus = tr("Нужен вход или плейлиста не существует")
        if !DownloadManager.hasDiskAccess { showAccessHint = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { playlistStatus = nil }
    }

    private func presentPlaylistQuestion(_ list: PlaylistLink,
                                         result: (title: String?, entries: [PlaylistLink.Entry], total: Int)?,
                                         audioOnly: Bool) {
        var text: String
        switch (result, list.hasVideo) {
        case let (result?, true):
            text = trf("В плейлисте %d видео. Скачать весь плейлист или только это видео?", result.total)
        case let (result?, false):
            text = trf("В плейлисте %d видео. Скачать их все? Они встанут в очередь загрузок.", result.total)
        default:
            text = tr("Скачать весь плейлист или только это видео?")
        }
        if let result, result.total > result.entries.count {
            text += "\n\n" + trf("За один раз добавятся первые %d.", result.entries.count)
        }
        PlaylistQuestionPanel.shared.ask(message: text, canTakeWhole: result != nil, canTakeSingle: list.hasVideo) { choice in
            switch choice {
            case .whole:
                if let result { enqueuePlaylist(result, list: list, audioOnly: audioOnly) }
            case .single:
                submitCurrentLink(audioOnly: audioOnly)
            case .cancel:
                break
            }
        }
    }

    /// Puts every video of the playlist into the queue, in its own folder.
    private func enqueuePlaylist(_ result: (title: String?, entries: [PlaylistLink.Entry], total: Int), list: PlaylistLink, audioOnly: Bool) {
        let folder = destinationURL.appendingPathComponent(PlaylistLink.folderName(for: result.title), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stripAudio = videoNoAudio
        let playlist = PlaylistInfo(id: UUID(), title: result.title, listURL: list.listURL,
                                    thumbnail: result.entries.first.flatMap { PlaylistLink.thumbnail(forVideoURL: $0.url) })
        queue.submit(result.entries.map { entry in
            QueuedDownload(url: entry.url, destination: folder, maxHeight: nil,
                           audioOnly: audioOnly, stripAudio: stripAudio,
                           videoFormat: .current, audioFormat: .current,
                           knownTitle: entry.title,
                           thumbnail: PlaylistLink.thumbnail(forVideoURL: entry.url),
                           playlist: playlist)
        })
        clipboardChangeAtQueue = NSPasteboard.general.changeCount
        urlString = ""
        playlistStatus = trf("В очередь добавлено видео: %d", result.entries.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { playlistStatus = nil }
    }

    private func submitCurrentLink(audioOnly: Bool) {
        // Before a probe, the UI only shows "Максимально доступное" — honor
        // that rather than a stale specific height picked in a past probe.
        let effectiveMaxHeight = manager.availableHeights.isEmpty ? nil : (qualityHeight == 0 ? nil : qualityHeight)
        let item = QueuedDownload(
            url: urlString.trimmingCharacters(in: .whitespacesAndNewlines),
            destination: destinationURL,
            maxHeight: effectiveMaxHeight,
            audioOnly: audioOnly,
            stripAudio: videoNoAudio,
            videoFormat: .current,
            audioFormat: .current)
        if queue.isActive(url: item.url, audioOnly: audioOnly) {
            playlistStatus = tr("Эта ссылка уже скачивается или стоит в очереди")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { playlistStatus = nil }
            return
        }
        let wasBusy = queue.busyCount > 0
        queue.submit(item)
        // Behind another download: the link has gone to the queue, so the field
        // is free for the next one.
        if wasBusy {
            clipboardChangeAtQueue = NSPasteboard.general.changeCount
            urlString = ""
        }
    }

    /// Sends a self-contained error report straight to the developer's
    /// Telegram via the Bot API — no Telegram needed on the sender's side.
    private func reportError(_ message: String) {
        errorReportCounter += 1
        let reportNumber = errorReportCounter
        lastErrorReportNumber = reportNumber

        let version = Self.appVersionString ?? "?"
        // Telegram caps message length at 4096 characters — keep the log
        // tail well under that along with the rest of the report.
        let logTail = String(manager.log.suffix(3000))
        let report = """
        Обращение №\(reportNumber) — Scorpena \(version), ошибка при скачивании

        Ссылка: \(urlString)
        Сообщение: \(message)

        Журнал:
        \(logTail.isEmpty ? "(пусто)" : logTail)
        """

        // Always copy it too — the fallback if the network send fails.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)

        errorReportStatus = .sending
        guard let url = URL(string: "https://api.telegram.org/bot\(Secrets.telegramBotToken)/sendMessage") else {
            errorReportStatus = .failed
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": Secrets.telegramChatID,
            "text": report,
        ])

        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil && (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                errorReportStatus = ok ? .sent : .failed
            }
        }.resume()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = tr("Куда сохранять видео")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = destinationURL
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
        }
    }
}

// MARK: - Resize grip

/// Height of the main column's content, reported up so the window can grow
/// when something (an error message, a banner) makes it taller than the window.
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Hands the NSWindow that hosts a SwiftUI view to the caller.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
    }
}

/// Keeps the main window exactly as tall as its content: at launch it takes the
/// content's height (so the margin under the footer matches the one above the
/// logo), when the content gets taller (a long error message appears) it grows
/// downward to fit, and it goes back when the extra content is gone. A window
/// the user resized by hand is left alone, and every launch starts the same.
@MainActor
final class MainWindowFitter: ObservableObject {
    weak var window: NSWindow?
    private var baseHeight: CGFloat = 0      // content height the window settled at on launch
    private var fittedHeight: CGFloat = 0    // content height we set when growing (0 = not grown)
    private var latestNeeded: CGFloat = 0
    private var launchFitDone = false

    func setBase(contentHeight: CGFloat) {
        baseHeight = contentHeight
        fittedHeight = 0
        launchFitDone = false
        fit(toContent: latestNeeded, animated: false)
    }

    func fit(toContent needed: CGFloat, animated: Bool = true) {
        latestNeeded = needed
        guard let window, baseHeight > 0, needed > 0, window.isVisible else { return }
        let current = window.contentLayoutRect.height
        let chrome = window.frame.height - current
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height

        func clamped(_ height: CGFloat) -> CGFloat {
            guard let visibleHeight else { return height }
            return min(height, visibleHeight - chrome - 10)
        }

        if !launchFitDone {
            // First fit after launch: exactly the content's height, up or down.
            launchFitDone = true
            let target = clamped(needed)
            baseHeight = target
            if abs(target - current) > 1 { resize(window, to: target, chrome: chrome, animated: false) }
            return
        }

        var target: CGFloat
        if needed > current + 1 {
            target = needed
        } else if fittedHeight > 0, abs(current - fittedHeight) < 2, needed < current - 1 {
            target = max(needed, baseHeight)
        } else {
            return
        }
        target = clamped(target)
        guard abs(target - current) > 1, !(needed > current + 1 && target < current) else { return }
        resize(window, to: target, chrome: chrome, animated: animated)
        fittedHeight = target > baseHeight + 1 ? target : 0
    }

    /// Changes the height keeping the window's top edge where it is.
    private func resize(_ window: NSWindow, to contentHeight: CGFloat, chrome: CGFloat, animated: Bool) {
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = contentHeight + chrome
        frame.origin.y = top - frame.size.height
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: animated)
    }
}

/// A small segmented control (title + options). Only the group that holds the
/// current download choice shows its selection.
private struct FormatSegments: View {
    let title: String
    let options: [(id: String, label: String)]
    let selected: String
    let active: Bool
    let disabled: Bool
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                ForEach(options, id: \.id) { option in
                    let isOn = active && option.id == selected
                    Text(option.label)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(isOn ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(isOn ? Color(nsColor: .textBackgroundColor) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture { if !disabled { onPick(option.id) } }
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
        }
        .opacity(disabled ? 0.45 : 1)
    }
}

// MARK: - Dock icon progress bar

/// Redraws the app icon with a thin progress bar along the bottom, the way
/// Finder/Safari show ongoing downloads in the Dock.
private final class DockProgressView: NSView {
    private let progress: Double

    init(progress: Double) {
        self.progress = progress
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let barHeight: CGFloat = 14
        let inset: CGFloat = 10
        let barRect = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: barHeight)

        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let fillWidth = max(0, min(1, progress)) * barRect.width
        if fillWidth > 1 {
            let fillRect = NSRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barHeight)
            NSColor.systemGreen.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        }
    }
}

// MARK: - Info windows (О программе / Правовая информация)

extension NSWindow {
    /// `NSWindow.center()` deliberately sits a bit above true screen centre
    /// (Apple's HIG placement for dialogs) — this pins it to the exact
    /// geometric centre of the screen instead, matching the main window.
    func centerExactlyOnScreen() {
        guard let screen = self.screen ?? NSScreen.main else {
            center()
            return
        }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A reusable window shown centred on the screen.
final class InfoPanel {
    static let about = InfoPanel(title: "О программе", size: NSSize(width: 480, height: 600)) {
        AnyView(AboutView(onClose: $0))
    }
    static let legal = InfoPanel(title: "Правовая информация", size: NSSize(width: 520, height: 640)) {
        AnyView(LegalView(onClose: $0))
    }
    static let feedback = InfoPanel(title: "Обратная связь", size: NSSize(width: 480, height: 380)) {
        AnyView(FeedbackView(onClose: $0))
    }

    private let title: String
    private let size: NSSize
    private let makeContent: (@escaping () -> Void) -> AnyView
    private var window: NSWindow?

    private init(title: String, size: NSSize,
                 makeContent: @escaping (@escaping () -> Void) -> AnyView) {
        self.title = title
        self.size = size
        self.makeContent = makeContent
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.title = tr(title)
            window.centerExactlyOnScreen()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: makeContent { [weak self] in self?.window?.close() }
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = tr(title)
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(size)
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

/// «Дополнительно» — its own window (not an inline expand/collapse) so the
/// main window never needs to resize itself. An inline DisclosureGroup was
/// tried first; macOS doesn't propagate PreferenceKey values out of its
/// disclosed content reliably, so any auto-sizing approach undermeasures,
/// and a hand-tuned constant needed re-tuning by hand on every content
/// change. A separate fixed-size window sidesteps both problems entirely.
final class AdvancedSettingsPanel {
    static let shared = AdvancedSettingsPanel()
    private var window: NSWindow?
    /// Set by the main window, so other windows («О программе») can open this one too.
    weak var manager: DownloadManager?

    func show() {
        if let manager { show(manager: manager) }
    }

    func show(manager: DownloadManager) {
        self.manager = manager
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.title = tr("Дополнительно")
            window.centerExactlyOnScreen()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(
            rootView: AdvancedSettingsView(manager: manager, onClose: { [weak self] in self?.window?.close() })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = tr("Дополнительно")
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        hosting.view.layoutSubtreeIfNeeded()
        win.setContentSize(hosting.view.fittingSize)
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

struct AdvancedSettingsView: View {
    @ObservedObject var manager: DownloadManager
    var onClose: () -> Void

    @AppStorage("muteChime") private var muteChime = false
    @AppStorage(ChimeVoice.key) private var chimeVoice = ChimeVoice.female.rawValue
    @State private var voicePreview: AVAudioPlayer?
    @AppStorage(DiagnosticReporter.enabledKey) private var sendDiagnostics = true
    @AppStorage("muteLaunchSound") private var muteLaunchSound = false
    @AppStorage(SpeedLimit.key) private var speedStep = SpeedLimit.defaultStep
    @AppStorage(Cleanup.Reminder.key) private var cleanupReminder = Cleanup.Reminder.weekly.rawValue
    @State private var cleanupNote: String?
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                notificationsBlock.card()
                speedBlock.card()
                cleanupBlock.card()
                toolsBlock.card()
                languageBlock.card()
                diagnosticsBlock.card()
            }
            .padding(EdgeInsets(top: 20, leading: 20, bottom: 6, trailing: 20))
            Button(tr("Закрыть")) { onClose() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.vertical, 16)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var notificationsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr("Уведомления")).font(.callout.bold())
            // ticked = the sound plays (the stored flags say "muted", so they are inverted here)
            switchRow(tr("Звук уведомления о скачивании"), isOn: Binding(get: { !muteChime }, set: { muteChime = !$0 }))
            HStack(spacing: 10) {
                Text(tr("Голос")).font(.callout)
                PillSegments(options: ChimeVoice.allCases.map { ($0.rawValue, $0.title) }, selected: chimeVoice) { picked in
                    chimeVoice = picked
                    if let url = ChimeVoice(rawValue: picked)?.soundURL, let player = try? AVAudioPlayer(contentsOf: url) {
                        player.play()
                        voicePreview = player   // keep a strong ref while it plays
                    }
                }
            }
            .disabled(muteChime)
            .padding(.leading, 20)
            switchRow(tr("Звук запуска приложения"), isOn: Binding(get: { !muteLaunchSound }, set: { muteLaunchSound = !$0 }))
        }
    }

    /// A checkbox with its label.
    private func switchRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.callout)
    }

    private var speedBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Скорость скачивания")).font(.callout.bold())
            HStack(spacing: 12) {
                Slider(value: Binding(get: { Double(speedStep) },
                                      set: { speedStep = Int($0.rounded()) }),
                       in: 0...Double(SpeedLimit.steps.count - 1), step: 1)
                    .frame(width: 210)
                VStack(alignment: .leading, spacing: 0) {
                    Text(SpeedLimit.title(step: speedStep))
                        .font(.callout.monospacedDigit())
                    if let note = SpeedLimit.megabytesNote(step: speedStep) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, alignment: .leading)
            }
            .onChange(of: speedStep) { _ in
                for engine in DownloadQueue.shared.managers { engine.speedLimitChanged() }
            }
        }
    }

    private var cleanupBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(tr("Напоминание об очистке")).font(.callout.bold())
            PillSegments(options: Cleanup.Reminder.allCases.map { ($0.rawValue, $0.title) }, selected: cleanupReminder) {
                cleanupReminder = $0
            }
            HStack(spacing: 10) {
                Button(tr("Очистить сейчас")) {
                    cleanupNote = nil
                    Cleanup.cleanNow(queue: DownloadQueue.shared) { found in
                        if !found { cleanupNote = tr("Чистить пока нечего.") }
                    }
                }
                .buttonStyle(SoftPillStyle(compact: true))
                if let cleanupNote {
                    Text(cleanupNote).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var toolsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Обновление встроенных инструментов")).font(.callout.bold())
            Text(tr("Программа скачивает видео с помощью внутренних инструментов и сама их обновляет. Если видео перестало скачиваться — нажми «Проверить сейчас»."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    manager.checkAndUpdateTools()
                } label: {
                    if manager.isCheckingToolUpdate {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(tr("Проверяю…"))
                        }
                    } else {
                        Text(tr("Проверить сейчас"))
                    }
                }
                .buttonStyle(SoftPillStyle(compact: true))
                .disabled(manager.isRunning || manager.isCheckingToolUpdate)

                if let version = manager.ytDlpVersion {
                    Text(trf("yt-dlp %@", version))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let status = manager.toolUpdateCheckStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Отчёты о сбоях")).font(.callout.bold())
            switchRow(tr("Отправлять разработчику анонимные отчёты о сбоях"), isOn: $sendDiagnostics)
            Text(tr("Анонимно, без ссылок и личных данных."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var languageBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("Язык")).font(.callout.bold())
            PillSegments(options: [(AppLanguage.ru.rawValue, "🇷🇺 Русский"), (AppLanguage.en.rawValue, "🇺🇸 English")],
                         selected: languageSettings.language.rawValue) { picked in
                if let language = AppLanguage(rawValue: picked) { languageSettings.language = language }
            }
        }
    }
}

/// Opens the native macOS share sheet with a ready-made "tell a friend"
/// message pointing at the latest GitHub release — the link works no matter
/// which version is current, so it never needs updating per-release.
final class ShareHelper: NSObject, NSSharingServicePickerDelegate {
    static let shared = ShareHelper()
    private var picker: NSSharingServicePicker?

    private static let message = """
    Нашёл удобную программу для Mac — SCORPENA – video downloader. Она скачивает видео/аудио с YouTube, VK, Instagram, TikTok и ещё кучи сайтов в один клик. Вот ссылка на актуальную версию: https://github.com/erickkey/Scorpena/releases/latest/download/Scorpena.dmg
    """

    /// Titles of default services that don't make sense for a short "tell a
    /// friend" message. An allow-list (matching by `isEqual` against
    /// `NSSharingService(named:)` reference instances) was tried first and
    /// silently dropped AirDrop and Messages too — that comparison isn't
    /// reliable across service types — and it can never include Telegram,
    /// WhatsApp, MAX or any other third-party messenger, since those show up
    /// as extension-based services with no `NSSharingService.Name` case to
    /// build a reference from. A deny-list leaves every such app alone.
    private static let deniedTitles: Set<String> = [
        "Заметки", "Напоминания", "Добавить в Заметки", "Добавить в Напоминания",
        "Список для чтения", "Добавить в список для чтения", "Быстрые команды",
        "Notes", "Reminders", "Add to Notes", "Add to Reminders",
        "Reading List", "Add to Reading List", "Freeform", "Shortcuts",
    ]

    /// `anchor` should be the exact view of the "Поделиться" button — the
    /// picker attaches right to it, rather than to a whole-window rect
    /// (which made it pop up wherever AppKit felt like, not over the button).
    func share(from anchor: NSView?) {
        guard let anchor else { return }
        let picker = NSSharingServicePicker(items: [Self.message])
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                               sharingServicesForItems items: [Any],
                               proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        let kept = proposedServices.filter { !Self.deniedTitles.contains($0.title) }
        let copyIcon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage()
        let copyService = NSSharingService(title: "Скопировать", image: copyIcon, alternateImage: copyIcon) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(Self.message, forType: .string)
        }
        return kept + [copyService]
    }
}

/// Exposes the plain NSView backing a SwiftUI view (via `.background(...)`)
/// so AppKit APIs like `NSSharingServicePicker` can anchor to it precisely.
private struct ViewAnchor: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Shown once, the very first time the app ever launches (before "Что
/// нового" or anything else) — bilingual by necessity, since we don't know
/// the user's language preference yet.
final class LanguagePickerPanel {
    static let shared = LanguagePickerPanel()
    private var window: NSWindow?

    /// True only if the language was never explicitly set — `@AppStorage`'s
    /// own default doesn't persist a value, so this stays true until a pick
    /// is made (unlike checking the resolved language against "ru").
    static var shouldShowOnLaunch: Bool {
        UserDefaults.standard.object(forKey: "appLanguage") == nil
    }

    func show(onDismiss: @escaping () -> Void = {}) {
        NSApp.activate(ignoringOtherApps: true)
        let hosting = NSHostingController(
            rootView: LanguagePickerView(onClose: { [weak self] in
                self?.window?.close()
                onDismiss()
            })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled]
        win.title = "Scorpena – video downloader"
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        hosting.view.layoutSubtreeIfNeeded()
        win.setContentSize(hosting.view.fittingSize)
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        win.centerExactlyOnScreen()
        window = win
    }
}

struct LanguagePickerView: View {
    var onClose: () -> Void

    /// Setting `languageSettings.language` directly (rather than a plain
    /// `UserDefaults.standard.set` from outside the view, as this used to
    /// do) is what makes the pick take effect everywhere immediately — a raw
    /// UserDefaults write doesn't reliably notify other already-open windows
    /// in this environment, as a real direct write here once did (the main
    /// window stayed in Russian after picking English until relaunch).
    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text("Выбери язык / Choose your language")
                .font(.title3.bold())
            HStack(spacing: 16) {
                option(flag: "🇷🇺", name: "Русский", language: .ru)
                option(flag: "🇺🇸", name: "English", language: .en)
            }
        }
        .padding(30)
    }

    private func option(flag: String, name: String, language: AppLanguage) -> some View {
        Button {
            languageSettings.language = language
            onClose()
        } label: {
            VStack(spacing: 10) {
                Text(flag).font(.system(size: 40))
                Text(name).font(.callout.weight(.semibold))
            }
            .frame(width: 140, height: 100)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// «Что нового» — shown once per version, right after an update.
final class WhatsNewPanel {
    static let shared = WhatsNewPanel()
    private var window: NSWindow?

    /// Opens the changelog for `version`. `onAcknowledge` runs only when the
    /// button under the list is pressed (closing with the window's own ✕
    /// doesn't count).
    func show(version: String, closeTitle: String, onAcknowledge: @escaping () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        window?.close()
        let hosting = NSHostingController(
            rootView: WhatsNewView(version: version, closeTitle: closeTitle, onClose: { [weak self] in
                onAcknowledge()
                self?.window?.close()
            })
        )
        let win = NSWindow(contentViewController: hosting)
        win.styleMask = [.titled, .closable]
        win.title = trf("Список изменений (v.%@)", version)
        win.isReleasedWhenClosed = false
        win.isRestorable = false
        win.setContentSize(NSSize(width: WhatsNewView.windowWidth, height: WhatsNewView.windowHeight(version: version)))
        win.centerExactlyOnScreen()
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}

/// The list of changes in a card, and the highlighted call to action under it.
private struct WhatsNewList: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                let items = ContentView.changelog[version] ?? []
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(tr(item)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if ContentView.changelogDividerAfter[version] == index + 1 {
                        Divider()
                    }
                }
            }
            .card()

            if let callout = ContentView.changelogCallouts[version] {
                HStack(spacing: 12) {
                    Image(systemName: "dock.rectangle")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    Text(tr(callout))
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.45)))
            }
        }
    }
}

struct WhatsNewView: View {
    let version: String

    /// Logo + the festive heading (three lines) when the version has one, else the plain title.
    static func headerView(_ version: String) -> AnyView {
        if let special = ContentView.changelogHeadlines[version] {
            return AnyView(VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(tr(special.intro))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                // The name stays black; "video downloader" is the quieter half.
                (Text("Scorpena").bold().foregroundColor(.primary)
                    + Text(" – video downloader").foregroundColor(.secondary))
                    .font(.title2)
                Text(tr(special.subtitle))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity))
        }
        return AnyView(WindowTitleRow(title: trf("Список изменений (v.%@)", version)))
    }

    static let windowWidth: CGFloat = 540

    /// Exactly as tall as the text needs; past 560 pt it stops growing and scrolls.
    static func windowHeight(version: String) -> CGFloat {
        let probe = NSHostingView(rootView: VStack(alignment: .leading, spacing: 14) {
            Self.headerView(version)
            WhatsNewList(version: version)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
        .frame(width: windowWidth))
        let buttonArea: CGFloat = 68
        return min(ceil(probe.fittingSize.height) + buttonArea, 560)
    }
    let closeTitle: String
    var onClose: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        InfoScaffold(width: Self.windowWidth, height: Self.windowHeight(version: version),
                     header: Self.headerView(version),
                     closeTitle: closeTitle, onClose: onClose) {
            WhatsNewList(version: version)
        }
    }
}

/// Scrollable body (optionally under the logo + title) and one closing button at the bottom.
struct InfoScaffold<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    var title: String? = nil
    var subtitle: String? = nil
    var header: AnyView? = nil
    let closeTitle: String
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let header { header } else if let title { WindowTitleRow(title: title, subtitle: subtitle) }
                    content()
                }
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AlwaysVisibleScroller())
            }
            Button(closeTitle) { onClose() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .padding(.vertical, 16)
        }
        .frame(width: width, height: height)
    }
}

/// Bulleted "heading + items" block, shared by both windows.
func infoSection(_ title: String, _ items: [String]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(title).font(.callout.bold())
        ForEach(items, id: \.self) { item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                if item.contains("⚙") {
                    TextWithGear(text: item, action: { AdvancedSettingsPanel.shared.show() })
                } else {
                    Text(item).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    .card()
}

/// Где можно поддержать автора (CloudTips). Открывается в браузере, программа ничего не передаёт.
enum DonateLink {
    static let url = URL(string: "https://pay.cloudtips.ru/p/491e7ef9")!
    static func open() { NSWorkspace.shared.open(url) }
}

struct AboutView: View {
    var onClose: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        InfoScaffold(width: 480, height: 600, closeTitle: tr("Благодарю"), onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                TextWithGear(text: tr("Сайты периодически меняют защиту. Если видео перестало скачиваться, зайди в раздел «Дополнительно» (⚙) и проверь обновления встроенных инструментов."),
                             action: { AdvancedSettingsPanel.shared.show() })
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))

                HStack(alignment: .center, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 60, height: 60)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("SCORPENA").font(.title2.bold())
                        Text("video downloader").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text("by Yaroslav Lukyanov")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tr("Скопируй ссылку и нажми «Скачать»"))
                    .font(.callout.weight(.semibold).italic())
                    .foregroundColor(.accentColor)
                Text(tr("Нативное приложение для Mac — скачивает видео и аудио с YouTube, VK, Instagram, TikTok, Vimeo и ещё ~1750 сайтов одним кликом. Видео — в MP4, MOV, WebM или MKV, звук — в MP3, WAV или M4A: формат выбирается рядом с кнопками скачивания."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                infoSection(tr("Что есть"), [
                    "Размер файла и доступное качество видны до скачивания.",
                    "Ссылка из буфера обмена подставляется сама.",
                    "Несколько скачиваний одновременно, остальные ждут в очереди.",
                    "Плейлисты целиком.",
                    "История и очередь загрузок.",
                    "Пауза и продолжение скачивания, даже если пропал интернет или программа была закрыта.",
                    "Ограничение скорости скачивания в «Дополнительно» (⚙).",
                    "Отчёт об ошибке разработчику в один клик.",
                    "Русский и английский языки.",
                    "Напоминание об очистке места на диске.",
                    "Обновление программы одной кнопкой.",
                    "Любой Mac: Intel и Apple Silicon, macOS 13 и новее.",
                ].map(tr))

                infoSection(tr("Чего нет"), [
                    "Скачивания платного и защищённого видео (Netflix, Кинопоиск, ivi, Okko и т.д.): оно закрыто DRM, системой шифрования от копирования.",
                    "Записи идущих прямых эфиров: только уже завершённых.",
                ].map(tr))

                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Программа бесплатная. Если она тебе пригодилась, можно поддержать её развитие."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(tr("Поддержать")) { DonateLink.open() }
                        .buttonStyle(SoftPillStyle())
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Sends whatever the user types straight to the developer's Telegram via
/// the same bot the error reports use — no Telegram needed on their side.
struct FeedbackView: View {
    var onClose: () -> Void

    /// Resets every time this opens — name/contact are worth remembering
    /// between messages, the message itself isn't.
    @State private var message = ""
    @AppStorage("feedbackName") private var name = ""
    @AppStorage("feedbackContact") private var contact = ""
    @AppStorage("lastFeedbackSendTime") private var lastSendTime: Double = 0
    @State private var cooldownNotice: String?
    @State private var sentNotice = false
    @ObservedObject private var languageSettings = LanguageSettings.shared

    private static let cooldown: TimeInterval = 60

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WindowTitleRow(title: tr("Обратная связь"),
                                   subtitle: tr("Вопросы, предложения, ошибки — что угодно. Уходит прямо разработчику."))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Обращение")).font(.caption).foregroundStyle(.secondary)
                        TextField(tr("Напиши сюда…"), text: $message, axis: .vertical)
                            .lineLimit(3...6)
                            .font(.callout)
                            .fieldStyle()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Имя (необязательно)")).font(.caption).foregroundStyle(.secondary)
                        TextField(tr("Как тебя зовут"), text: $name)
                            .font(.callout)
                            .fieldStyle()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("Как связаться (необязательно)")).font(.caption).foregroundStyle(.secondary)
                        TextField(tr("Например, ссылка на Telegram"), text: $contact)
                            .font(.callout)
                            .fieldStyle()
                    }

                    if let cooldownNotice {
                        Text(cooldownNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if sentNotice {
                        Text(tr("Обращение отправлено"))
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                .padding(EdgeInsets(top: 22, leading: 24, bottom: 14, trailing: 24))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AlwaysVisibleScroller())
            }
            Button(tr("Отправить")) { send() }
                .buttonStyle(PrimaryPillStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.vertical, 16)
        }
        .frame(width: 480, height: 380)
        .onAppear { cooldownNotice = nil; sentNotice = false }
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let elapsed = Date().timeIntervalSince1970 - lastSendTime
        guard elapsed >= Self.cooldown else {
            let remaining = Int((Self.cooldown - elapsed).rounded(.up))
            cooldownNotice = trf("Подожди ещё %d с перед следующим сообщением.", remaining)
            return
        }
        cooldownNotice = nil

        let nameLine = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contactLine = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        var infoLines: [String] = []
        if !nameLine.isEmpty { infoLines.append("Имя: \(nameLine)") }
        if !contactLine.isEmpty { infoLines.append("Связь: \(contactLine)") }
        let header = infoLines.isEmpty ? "Обратная связь:" : "Обратная связь (\(infoLines.joined(separator: ", "))):"
        let fullText = "\(header)\n\n\(text)"

        message = ""
        lastSendTime = Date().timeIntervalSince1970

        if let url = URL(string: "https://api.telegram.org/bot\(Secrets.telegramBotToken)/sendMessage") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "chat_id": Secrets.telegramChatID,
                "text": fullText,
            ])
            URLSession.shared.dataTask(with: request).resume()
        }

        sentNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            sentNotice = false
            onClose()
        }
    }
}

struct LegalView: View {
    var onClose: () -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        InfoScaffold(width: 520, height: 640, title: tr("Правовая информация"), closeTitle: tr("Понятно"), onClose: onClose) {
            VStack(alignment: .leading, spacing: 14) {
                Text(tr("Это не юридическая консультация, а общие ориентиры. Законы отличаются в разных странах, поэтому перед использованием программы проверь, что допускает закон в твоей стране. Если сомневаешься — консультируйся с юристом."))
                    .font(.callout)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)))

                VStack(alignment: .leading, spacing: 10) {
                    para("Сама программа легальна.", "Внутри — открытый движок yt-dlp, Scorpena – video downloader просто удобная оболочка над ним. Она не взламывает сайты: берёт те же потоки, что сайт и так отдаёт браузеру.")

                    Text(tr("Scorpena – video downloader позволяет сохранять видео и аудио локально. Убедись, что твоё использование соответствует законодательству твоей страны и условиям сервиса, с которого ты скачиваешь контент."))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    para("Нельзя:", "обходить платную подписку и DRM (Netflix, Кинопоиск и т.д.) — программа этого и не умеет.")
                }
                .card()

                infoSection(tr("Ответственность"), [
                    "Автор не отвечает за то, какие видео и с каких сайтов ты скачиваешь, и за соблюдение тобой законов, авторских прав и правил этих сайтов.",
                    "Автор не отвечает за любой вред: потерю или повреждение файлов, сбои в работе, блокировку твоих аккаунтов, претензии правообладателей или сайтов.",
                    "Автор не гарантирует, что программа работает, работает правильно или продолжит работать в будущем.",
                ].map(tr))

                para("Отчёты о сбоях.", "При серьёзных сбоях программа может отправить разработчику короткий анонимный отчёт без ссылок и личных данных. Отключить можно в «Дополнительно».")
                    .card()

                Text(tr("Программа распространяется бесплатно, в текущем виде, без каких-либо гарантий. Скачивая что-либо через программу, ты действуешь на свой страх и риск и полностью принимаешь ответственность на себя."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func para(_ lead: String, _ rest: String) -> some View {
        (Text(tr(lead)).bold() + Text(" " + tr(rest)))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Update checker

/// Fetches a tiny JSON file from GitHub on launch and compares its "version"
/// to this build's own version. No auto-download — just points at the
/// GitHub Release's stable "latest" URL for the user to grab themselves.
@MainActor
final class UpdateChecker: ObservableObject {
    enum InstallState: Equatable { case idle, installing }

    @Published private(set) var updateAvailable = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var installState: InstallState = .idle

    /// Set at launch when this run is the result of an in-app update: shown
    /// once, in the same window that asked the question.
    private(set) var launchResult: UpdatePanel.Phase?
    func takeLaunchResult() -> UpdatePanel.Phase? {
        defer { launchResult = nil }
        return launchResult
    }

    private static let pendingUpdateKey = "pendingAppUpdateVersion"

    init() {
        let defaults = UserDefaults.standard
        guard let target = defaults.string(forKey: Self.pendingUpdateKey) else { return }
        defaults.removeObject(forKey: Self.pendingUpdateKey)
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        launchResult = current == target ? .finished(current) : .rolledBack
        if current != target {
            DiagnosticReporter.report(.appUpdateRolledBack,
                                      details: "Ставили версию \(target), запущена \(current).")
        }
    }

    private let versionURL = URL(string:
        "https://raw.githubusercontent.com/erickkey/Scorpena/main/version.json")!
    private let downloadURL = AppInstaller.downloadURL

    func check() {
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        Task {
            // raw.githubusercontent.com caches responses on its own CDN for a
            // few minutes regardless of client cache headers, so a plain
            // reloadIgnoringLocalCacheData isn't enough right after a
            // release — bust it with a per-request query param instead.
            var comps = URLComponents(url: versionURL, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            var request = URLRequest(url: comps.url!)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let remote = json["version"] as? String
            else { return }

            if Self.isNewer(remote, than: currentVersion) {
                self.latestVersion = remote
                self.updateAvailable = true
            }
        }
        if installState == .idle, !Self.cleanedUp {
            Self.cleanedUp = true
            DispatchQueue.global(qos: .utility).async { AppInstaller.cleanupLeftovers() }
        }
    }

    private static var cleanedUp = false

    func openDownload() {
        NSWorkspace.shared.open(downloadURL)
    }

    /// The red "update available" button: asks first (in the update window),
    /// then downloads the new version and swaps the app in place — see
    /// AppInstaller. Falls back to opening the download page whenever the app
    /// can't replace itself.
    func startUpdate(downloadInProgress: Bool) {
        guard installState == .idle, let version = latestVersion else { return }
        if AppInstaller.cannotReplaceSelfReason() != nil {
            openDownload()
            return
        }
        let panel = UpdatePanel.shared
        if downloadInProgress {
            panel.show(.downloadRunning)
            return
        }
        panel.onConfirm = { [weak self] in self?.beginInstall(version: version) }
        panel.show(.confirm(version))
    }

    private func beginInstall(version: String) {
        guard installState == .idle else { return }
        let panel = UpdatePanel.shared
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        installState = .installing
        panel.show(.downloading(0))
        Task {
            do {
                try AppInstaller.ensureDiskSpace()
                let dmg = try await AppInstaller.download(from: AppInstaller.downloadURL) { fraction in
                    Task { @MainActor in
                        if case .downloading = panel.phase { panel.update(.downloading(fraction)) }
                    }
                }
                panel.update(.verifying)
                let staged = try await Task.detached(priority: .userInitiated) {
                    try AppInstaller.prepare(dmg: dmg, currentVersion: currentVersion)
                }.value
                panel.update(.installing)
                let stagedVersion = Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String
                UserDefaults.standard.set(stagedVersion ?? version, forKey: Self.pendingUpdateKey)
                UserDefaults.standard.synchronize()
                try AppInstaller.launchInstaller(staged: staged)
                try? await Task.sleep(nanoseconds: 600_000_000)   // let the "installing" step be seen
                NSApp.terminate(nil)
            } catch {
                self.installState = .idle
                UserDefaults.standard.removeObject(forKey: Self.pendingUpdateKey)
                panel.update(.failed(AppInstaller.friendlyMessage(for: error)))
                let ns = error as NSError
                DiagnosticReporter.report(.appUpdateFailed, details:
                    "Обновление \(currentVersion) → \(version)\n\(AppInstaller.friendlyMessage(for: error))\n(\(ns.domain) \(ns.code))")
            }
        }
    }

    /// Simple dotted-version compare ("1.10" > "1.9").
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
