import Foundation
import Combine

/// Only Russian and English for now — a friend-facing app, not a global
/// product. Every user-facing string in the app is authored in Russian and
/// passed through `tr`/`trf`; internal-only text (the technical log, the
/// Telegram error reports and feedback messages the developer reads) is
/// intentionally left untranslated regardless of this setting, since it's
/// never shown to the person using the app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

let languageDefaultsKey = "appLanguage"

/// Shared, observable language setting. Every window in this app (the main
/// one, "Advanced", "About", the language picker, …) is hosted by its own
/// separate `NSHostingController` — a plain `@AppStorage("appLanguage")`
/// declared in each view was tried first and turned out to NOT reliably
/// propagate a change made in one window's view hierarchy to another's
/// (confirmed directly: picking English in the language-picker window left
/// the already-open main window in Russian until relaunch). An explicit
/// `ObservableObject` singleton, observed via `@ObservedObject` in each
/// view, doesn't have that problem — `@Published` notifies every observer
/// of this same instance regardless of which window hosts it.
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: languageDefaultsKey) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: languageDefaultsKey)
        language = raw.flatMap(AppLanguage.init(rawValue:)) ?? .ru
    }
}

/// Translates a Russian UI string to English when the app's language is set
/// to English; returns it unchanged otherwise (including when no
/// translation is on file — better a Russian string than a blank one).
func tr(_ russian: String) -> String {
    guard LanguageSettings.shared.language == .en else { return russian }
    return Translations.en[russian] ?? russian
}

/// Same as `tr`, for strings that carry interpolated values. Dictionary
/// keys/values are `String(format:)` templates (`%@`, `%d`, …) — this keeps
/// every translation a plain static string pair, with no string-building
/// logic duplicated between languages.
func trf(_ russianFormat: String, _ args: CVarArg...) -> String {
    String(format: tr(russianFormat), arguments: args)
}

enum Translations {
    static let en: [String: String] = [
        // MARK: Header / footer
        "Дополнительно": "Advanced",
        "Оформление": "Appearance",
        "Светлая / тёмная тема": "Light / dark theme",
        "Нативное приложение для Mac, которое скачивает видео и аудио с YouTube, VK, Instagram, TikTok, Vimeo и ещё почти 1750 сайтов одной кнопкой.\nПоказ реального размера файла перед скачиванием, поддержка ссылок в любом виде и умная подстановка из буфера обмена.":
            "A native Mac app that downloads video and audio from YouTube, VK, Instagram, TikTok, Vimeo, and almost 1750 other sites with one click.\nShows the real file size before downloading, understands links in any form, and smartly fills in a link from your clipboard.",
        "О программе": "About",
        "Правовая информация": "Legal Information",
        "Обратная связь": "Feedback",
        "Поделиться": "Share",
        "Доступно обновление": "Update available",

        // MARK: URL field
        "Ссылка на видео": "Video link",
        "https://vk.com/video…  или  https://www.youtube.com/watch?v=…":
            "https://vk.com/video…  or  https://www.youtube.com/watch?v=…",
        "Кажется, это не ссылка — проверь, что скопировалось": "Doesn't look like a link — check what you copied",
        "Это главная страница сайта, а не ссылка на видео": "That's the site's homepage, not a link to a video",
        "История скачиваний": "Download history",
        "Пока нет скачиваний": "No downloads yet",
        "Очистить историю": "Clear history",
        "Очистить историю?": "Clear history?",
        "Очистить": "Clear",
        "Отмена": "Cancel",
        "Список будет удалён. Скачанные файлы не затрагиваются.": "The list will be deleted. Downloaded files are not affected.",
        "Видео": "Video",
        "Звук": "Audio",
        "Необычный сайт — программа попробует, но результат не гарантирован": "Unusual site — the app will try, but success isn't guaranteed",
        "Сайт есть в списке поддерживаемых ✅": "Site is in the supported list ✅",
        "видео": "video",

        // MARK: Quality section
        "Качество": "Quality",
        "Качество видео": "Video quality",
        "Качество видео (доступное для этого видео)": "Video quality (available for this video)",
        "Максимально доступное": "Best available",
        "Максимальное": "Best",
        "Максимальное — %@": "Best — %@",
        "Проверить качество": "Check quality",
        "Необязательно — можно сразу нажать «Скачать видео».\nПроверка займёт немного времени, зато сразу покажет все доступные варианты качества и размер файла.":
            "Optional — you can just click “Download video” right away.\nChecking takes a little time, but shows every available quality and its file size upfront.",

        // MARK: Destination
        "Папка назначения": "Destination folder",
        "Выбрать…": "Choose…",
        "Куда сохранять видео": "Where to save videos",

        // MARK: Action row
        "Отменить": "Cancel",
        "Скачать видео": "Download video",
        "Скачать звук": "Download audio",
        "Показать файл": "Show file",
        "Скачать видео без звука": "Download video without audio",
        "«Скачать видео» / .mp4 (h.264) ": "“Download video” / .mp4 (H.264) ",
        "(автоматическое преобразование)": "(automatic conversion)",
        "«Скачать звук» / .mp3 (320 kbps)": "“Download audio” / .mp3 (320 kbps)",

        // MARK: Progress / status
        "с": "s",
        "Программа запрашивает у сайта данные о видео: адреса потоков и способ обхода защиты. Обычно 2–10 секунд.":
            "The app is asking the site for the video's info: stream addresses and how to get past its protection. Usually 2–10 seconds.",
        "Сайт отдаёт видео множеством мелких кусков, а не одним файлом — их приходится качать по очереди, поэтому медленнее обычного. У Vimeo почти всегда так.":
            "The site serves the video in lots of tiny pieces instead of one file — they have to be downloaded one by one, so it's slower than usual. Vimeo almost always does this.",
        "Сообщить об ошибке": "Report a problem",
        "Отправлено (обращение №%@) — спасибо!": "Sent (ticket #%@) — thanks!",
        "Не удалось отправить — текст скопирован, отправь вручную в Telegram": "Couldn't send it — the text was copied, send it manually via Telegram",

        // MARK: Banners
        "Нужен «Полный доступ к диску»": "“Full Disk Access” needed",
        "Чтобы взять cookies из Safari для видео, требующих входа, включи для Scorpena «Полный доступ к диску» в настройках. Один раз. Нет Scorpena в списке? Нажми «+» и добавь её из папки, куда ты её установил.":
            "To grab cookies from Safari for videos that need a login, turn on “Full Disk Access” for Scorpena in Settings. Once. Scorpena isn't in the list? Click “+” and add it from the folder you installed it in.",
        "Открыть настройки": "Open Settings",
        "Не хватает инструментов": "Missing tools",
        "yt-dlp: %@\nffmpeg: %@": "yt-dlp: %@\nffmpeg: %@",
        "не найден": "not found",
        "Установить через Homebrew": "Install via Homebrew",
        "Проверить снова": "Check again",
        "Homebrew не найден — поставь его с brew.sh. Обычно инструменты уже вшиты в приложение при сборке.":
            "Homebrew not found — install it from brew.sh. The tools are usually already bundled with the app.",

        // MARK: Advanced settings window
        "Закрыть": "Close",
        "Уведомления": "Notifications",
        "Обновление встроенных инструментов": "Built-in tools update",
        "Обновить": "Update",
        "Язык": "Language",

        // MARK: What's New
        "Круто": "Cool!",
        "Список изменений": "What's New",
        "Сейчас идёт скачивание": "A download is in progress",
        "Отчёты о сбоях": "Crash reports",
        "Программа скачивает видео с помощью внутренних инструментов и сама их обновляет. Если видео перестало скачиваться — нажми «Проверить сейчас».": "The app downloads videos using internal tools and updates them by itself. If videos stop downloading, press “Check now”.",
        "Проверить сейчас": "Check now",
        "Проверяю…": "Checking…",
        "У тебя последняя версия (%@). Проверка заняла %d с.": "You have the latest version (%@). The check took %d s.",
        "Обновлено: %@ → %@ ✅ (за %d с)": "Updated: %@ → %@ ✅ (in %d s)",
        "Шаг %d из 4 · %@": "Step %d of 4 · %@",
        "Проверяю на GitHub, вышла ли новая версия…": "Checking GitHub for a new version…",
        "Обычно занимает до минуты.": "Usually takes up to a minute.",
        "yt-dlp %@": "yt-dlp %@",
        "Новая версия %@ не прошла проверку — оставил %@.": "The new version %@ didn't pass the check — kept %@.",
        "Не удалось проверить обновления — нет связи с интернетом.": "Couldn't check for updates — no internet connection.",
        "Отправлять разработчику анонимные отчёты о сбоях": "Send anonymous crash reports to the developer",
        "Анонимно, без ссылок и личных данных.": "Anonymous, no links or personal data.",
        "Дождись окончания скачивания и нажми кнопку обновления ещё раз.": "Wait for the download to finish, then press the update button again.",
        "Вышла новая версия %@": "Version %@ is out",
        "Обновимся прямо сейчас? Займёт около минуты, программа сама перезапустится. Настройки и история сохранятся.": "Update right now? It takes about a minute and the app restarts by itself. Your settings and history are kept.",
        "Позже": "Later",
        "Загружаю новую версию…": "Downloading the new version…",
        "Проверяю загрузку…": "Checking the download…",
        "Убеждаюсь, что всё скачалось без повреждений.": "Making sure everything downloaded intact.",
        "Ставлю обновление…": "Installing the update…",
        "Сейчас программа перезапустится.": "The app is about to restart.",
        "Готово! Теперь у тебя версия %@ ✅": "Done! You now have version %@ ✅",
        "Отлично": "Great",
        "Обновиться не получилось": "The update didn't work out",
        "Ничего не сломалось: осталась прежняя версия.": "Nothing broke: the previous version is still in place.",
        "Новая версия не запустилась, поэтому вернули прежнюю. Ничего не сломалось — можно скачать новую вручную.": "The new version wouldn't start, so the previous one was put back. Nothing broke — you can download the new one manually.",
        "Скачать вручную": "Download manually",
        "Нет связи с интернетом или GitHub недоступен. Проверь подключение и попробуй ещё раз.": "No internet connection, or GitHub is unreachable. Check your connection and try again.",
        "GitHub не отдал файл обновления (код %d). Попробуй позже или скачай вручную.": "GitHub didn't serve the update file (code %d). Try later or download it manually.",
        "Не хватает места на диске. Освободи около 1 ГБ и попробуй снова.": "Not enough disk space. Free up about 1 GB and try again.",
        "Скачанный файл не открылся — возможно, загрузка прервалась. Попробуй ещё раз.": "The downloaded file wouldn't open — the download may have been interrupted. Try again.",
        "Скачанный файл повреждён или не подходит к этому приложению.": "The downloaded file is damaged or doesn't match this app.",
        "Что-то пошло не так: %@": "Something went wrong: %@",
        "Список изменений (v.%@)": "What's New (v.%@)",
        "Отдельные кнопки «Скачать видео» и «Скачать звук» вместо одной галочки.":
            "Separate “Download video” and “Download audio” buttons instead of one checkbox.",
        "Новая галочка «Скачать видео без звука».": "A new “Download video without audio” checkbox.",
        "Проверка качества видео — размер файла виден для каждого варианта.":
            "A video quality check — the file size is shown for every option.",
        "Понимает ссылки в любом виде и предупреждает, если это не похоже на ссылку.":
            "Understands links in any form, and warns if it doesn't look like a link at all.",
        "Автоподстановка ссылки из буфера обмена.": "Auto-fills a link from your clipboard.",
        "Таймер во время скачивания и показ итогового времени в конце.":
            "A timer during downloads, and the total time shown at the end.",
        "«Сообщить об ошибке» — если скачивание не удалось, можно одной кнопкой отправить мне отчёт.":
            "“Report a problem” — if a download fails, you can send me a report with one click.",
        "Выбор языка (русский/английский) — при первом запуске, и в любой момент в «Дополнительно».":
            "A language choice (Russian/English) — on first launch, and any time after in “Advanced”.",
        "«Дополнительно» — теперь отдельное окно, а не выпадающий список внизу.":
            "“Advanced” is now its own window instead of a dropdown at the bottom.",
        "«Поделиться» — можно быстро отправить другу ссылку на программу.":
            "“Share” — quickly send a friend a link to the app.",
        "Обновление встроенных инструментов — понятный раздел: «Проверить обновление» показывает, есть ли новая версия, кнопка «Обновить» активна только когда реально есть что обновлять.":
            "Built-in tools update — a clear section: “Check for update” shows whether a new version exists, and “Update” is only enabled when there's actually something to update.",
        "«Обратная связь» — отдельный раздел: написать вопрос, пожелание или что угодно ещё, по желанию оставив имя и контакт.":
            "“Feedback” — a dedicated section: write a question, a suggestion, or anything else, optionally leaving your name and contact.",
        "Можно запомнить нужный размер окна — при выходе программа спросит, сохранить ли его.":
            "You can save your preferred window size — the app asks whether to remember it when you quit.",
        "Программа переименована": "The app has been renamed",
        "Переименовываю…": "Renaming…",
        "Секунду, сейчас программа перезапустится.": "One moment — the app is about to restart.",
        "Ладно": "OK",
        "Теперь она называется Scorpena – video downloader. Настройки и история на месте. Программа один раз перезапустится, а значок в Dock нужно будет закрепить заново. Если рядом осталась старая копия, её можно удалить.": "It's now called Scorpena – video downloader. Your settings and history are untouched. The app will restart once, and you'll need to pin its Dock icon again. If an old copy is left next to it, you can delete it.",
        "Теперь она называется Scorpena – video downloader. Настройки и история на месте. Если рядом осталась старая копия, её можно удалить.": "It's now called Scorpena – video downloader. Your settings and history are untouched. If an old copy is left next to it, you can delete it.",
        "Скачиваю новую версию (около 54 МБ) и сверяю контрольную сумму…": "Downloading the new version (about 54 MB) and checking its checksum…",
        "Распаковываю новую версию рядом со старой…": "Unpacking the new version next to the old one…",
        "Проверяю, что новая версия работает с YouTube, и только потом заменяю…": "Checking that the new version works with YouTube, and only then replacing…",
        "Без ограничения": "No limit",
        "Звук уведомления о скачивании": "Download notification sound",
        "Звук запуска приложения": "App launch sound",
        "Конвертация в %@…": "Converting to %@…",
        "Качество:": "Quality:",
        "Вставь ссылку на видео": "Paste a video link",
        "Скачать": "Download",
        "без звука": "no audio",
        "Качество (доступное для этого видео):": "Quality (available for this video):",
        "Выбрать папку для сохранения": "Choose where to save",
        "Папка:": "Folder:",
        "%d Мбит/с": "%d Mbit/s",
        "≈ %@ МБ/с": "≈ %@ MB/s",
        "Упаковка в %@…": "Packing into %@…",
        "Формат видео": "Video format",
        "Формат звука": "Audio format",
        "Скорость скачивания": "Download speed",
        "Пауза": "Pause",
        "Продолжить": "Resume",
        "Пауза — нажми «Продолжить»": "Paused — press “Resume”",
        "Нет связи — жду и продолжу сам…": "No connection — waiting, will carry on by itself…",
        "Скачивание не закончилось": "The download didn't finish",
        "Не докачано: %@. Продолжить с того места, где остановилось?": "Not finished: %@. Continue from where it stopped?",
        "Не нужно": "No thanks",
        "Готово ✅ (%@)": "Done ✅ (%@)",
        "Встречайте! Теперь у программы есть название!": "Meet the new name! The app finally has one!",
        "Новый облик, новые возможности, и всё работает лучше, чем раньше.": "A new look, new features, and everything works better than before.",
        "Теперь доступен выбор формата видео и звука.": "You can now choose the video and audio format.",
        "Появилась возможность паузы и докачки видео даже после закрытия программы.": "You can now pause and resume downloads, even after closing the app.",
        "Ограничение скорости скачивания. (нажми на шестеренку справа вверху)": "Download speed limit. (click the gear at the top right)",
        "Скачивание и проверка качества стали гораздо быстрее.": "Downloading and the quality check are now much faster.",
        "Множество мелких улучшений и исправлений.": "Lots of small improvements and fixes.",
        "Добавь приложение в Dock и погнали качать!": "Add the app to the Dock and let's get downloading!",
        "Обновление программы теперь одной кнопкой (наконец-то).": "Updating the app is now one button (finally).",
        "Встроенный загрузчик обновляется сам.": "The built-in downloader updates itself.",
        "История скачиваний.": "Download history.",
        "Поправлен баг – новая скопированная ссылка теперь сама заменяет старую.": "Fixed a bug — a newly copied link now replaces the old one by itself.",
        "Анонимные отчёты о сбоях теперь автоматические (отключаются в «Дополнительно»).": "Anonymous crash reports are now automatic (you can turn them off in “Advanced”).",
        "Версия программы видна в шапке окна.": "The app version is shown in the header.",
        "Технический журнал скрыт от пользователя.": "The technical log is now hidden from the user.",
        "Мелкие внутренние улучшения и исправления.": "Minor internal improvements and fixes.",

        // MARK: About window
        "Сайты периодически меняют защиту. Если видео перестало скачиваться, зайди в раздел «Дополнительно» (⚙) и проверь обновления встроенных инструментов.":
            "Sites change their protection from time to time. If a video stops downloading, open “Advanced” (⚙) and check for updates to the built-in tools.",
        "Скопируй ссылку и нажми «Скачать»": "Copy the link and hit “Download”",
        "Нативное приложение для Mac — скачивает видео и аудио с YouTube, VK, Instagram, TikTok, Vimeo и ещё ~1750 сайтов одним кликом. Видео — в MP4, MOV, WebM или MKV, звук — в MP3, WAV или M4A: формат выбирается рядом с кнопками скачивания.":
            "A native Mac app — downloads video and audio from YouTube, VK, Instagram, TikTok, Vimeo, and ~1750 other sites in one click. Video as MP4, MOV, WebM or MKV, audio as MP3, WAV or M4A: pick the format next to the download buttons.",
        "Что есть в программе": "What's in the app",
        "Размер файла и доступное качество видны до скачивания.": "File size and available quality are shown before downloading.",
        "Ссылка из буфера обмена подставляется сама.": "A link from the clipboard is filled in automatically.",
        "Отчёт об ошибке разработчику в один клик.": "Error report to the developer in one click.",
        "Русский и английский языки.": "Russian and English languages.",
        "История последних скачиваний.": "History of recent downloads.",
        "Пауза и продолжение скачивания, даже если пропал интернет или программа была закрыта.": "Pause and resume downloads, even if the internet drops or the app was closed.",
        "Ограничение скорости скачивания в «Дополнительно» (⚙).": "Download speed limit in “Advanced” (⚙).",
        "Обновление программы одной кнопкой.": "Updating the app with one button.",
        "Любой Mac: Intel и Apple Silicon, macOS 13 и новее.": "Any Mac: Intel and Apple Silicon, macOS 13 or newer.",
        "Что не умеет": "What it can't do",
        "Скачивать платное и защищённое видео (Netflix, Кинопоиск, ivi, Okko и т.д.) — оно закрыто DRM (система шифрования от копирования).":
            "Download paid or protected video (Netflix, Kinopoisk, ivi, Okko, etc.) — it's locked with DRM (copy-protection encryption).",
        "Скачивать плейлист целиком — только по одной ссылке за раз.": "Download a whole playlist — only one link at a time.",
        "Записывать идущие прямые эфиры — только уже завершённые.": "Record a live stream in progress — only ones that have already ended.",
        "Скачивать субтитры и вырезать фрагменты.": "Download subtitles or cut out clips.",
        "Благодарю": "Thanks",

        // MARK: Feedback window
        "Вопросы, предложения, ошибки — что угодно. Уходит прямо разработчику.":
            "Questions, suggestions, bugs — anything at all. Goes straight to the developer.",
        "Обращение": "Message",
        "Напиши сюда…": "Write here…",
        "Имя (необязательно)": "Name (optional)",
        "Как тебя зовут": "Your name",
        "Как связаться (необязательно)": "How to reach you (optional)",
        "Например, ссылка на Telegram": "e.g. a Telegram link",
        "Обращение отправлено": "Message sent",
        "Отправить": "Send",
        "Подожди ещё %d с перед следующим сообщением.": "Please wait %d more seconds before sending another message.",

        // MARK: Legal window
        "Это не юридическая консультация, а общие ориентиры. Законы отличаются в разных странах, поэтому перед использованием программы проверь, что допускает закон в твоей стране. Если сомневаешься — консультируйся с юристом.":
            "This isn't legal advice, just general guidance. Laws differ between countries, so check what's allowed where you live before using the app. Consult a lawyer if you're unsure.",
        "Сама программа легальна.": "The app itself is legal.",
        "Внутри — открытый движок yt-dlp, Scorpena – video downloader просто удобная оболочка над ним. Она не взламывает сайты: берёт те же потоки, что сайт и так отдаёт браузеру.":
            "Under the hood is the open-source yt-dlp engine — Scorpena – video downloader is just a convenient shell around it. It doesn't hack sites: it fetches the same streams a site already serves to a browser.",
        "Scorpena – video downloader позволяет сохранять видео и аудио локально. Убедись, что твоё использование соответствует законодательству твоей страны и условиям сервиса, с которого ты скачиваешь контент.":
            "Scorpena – video downloader lets you save video and audio locally. Make sure your use complies with the law in your country and the terms of the service you're downloading from.",
        "Нельзя:": "Not allowed:",
        "обходить платную подписку и DRM (Netflix, Кинопоиск и т.д.) — программа этого и не умеет.":
            "bypassing a paid subscription or DRM (Netflix, Kinopoisk, etc.) — the app can't do this anyway.",
        "Ответственность": "Responsibility",
        "Автор не отвечает за то, какие видео и с каких сайтов ты скачиваешь, и за соблюдение тобой законов, авторских прав и правил этих сайтов.":
            "The author isn't responsible for what videos or sites you download from, or for your compliance with laws, copyright, or those sites' rules.",
        "Автор не отвечает за любой вред: потерю или повреждение файлов, сбои в работе, блокировку твоих аккаунтов, претензии правообладателей или сайтов.":
            "The author isn't responsible for any harm: lost or corrupted files, malfunctions, your accounts being blocked, or claims from rights holders or sites.",
        "Автор не гарантирует, что программа работает, работает правильно или продолжит работать в будущем.":
            "The author doesn't guarantee the app works, works correctly, or will keep working in the future.",
        "Программа распространяется бесплатно, в текущем виде, без каких-либо гарантий. Скачивая что-либо через программу, ты действуешь на свой страх и риск и полностью принимаешь ответственность на себя.":
            "The app is distributed free of charge, as-is, without any warranty. By downloading anything through it, you act at your own risk and take full responsibility.",
        "Понятно": "Got it",
        "Отчёты о сбоях.": "Crash reports.",
        "При серьёзных сбоях программа может отправить разработчику короткий анонимный отчёт без ссылок и личных данных. Отключить можно в «Дополнительно».":
            "In case of a serious failure the app may send the developer a short anonymous report with no links or personal data. You can turn this off in “Advanced”.",

        // MARK: DownloadManager — probe status
        "Проверяю доступные качества… %d с": "Checking available qualities… %d s",
        "Доступно (%@ с): ": "Available (%@ s): ",
        "Не удалось определить качества за %@ с — при скачивании возьмётся максимум доступное.":
            "Couldn't determine available qualities in %@ s — the download will use the best available quality.",

        // MARK: DownloadManager — tooling
        "yt-dlp и ffmpeg установлены ✅": "yt-dlp and ffmpeg installed ✅",
        "Установка yt-dlp и ffmpeg через Homebrew…": "Installing yt-dlp and ffmpeg via Homebrew…",
        "Не удалось проверить обновления.": "Couldn't check for updates.",
        "yt-dlp обновлён ✅": "yt-dlp updated ✅",
        "Обновление встроенного yt-dlp…": "Updating the built-in yt-dlp…",
        "yt-dlp и ffmpeg обновлены ✅": "yt-dlp and ffmpeg updated ✅",
        "Обновление yt-dlp и ffmpeg…": "Updating yt-dlp and ffmpeg…",
        "Homebrew не найден. Установи его одной командой в Терминале:\n\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n\nзатем нажми «Проверить снова».":
            "Homebrew not found. Install it with one command in Terminal:\n\n/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"\n\nthen click “Check again”.",

        // MARK: DownloadManager — download flow
        "Вставь ссылку на видео.": "Paste a video link.",
        "yt-dlp не найден. Нажми «Установить через Homebrew» в баннере выше.": "yt-dlp not found. Click “Install via Homebrew” in the banner above.",
        "ffmpeg не найден. Нажми «Установить через Homebrew» в баннере выше.": "ffmpeg not found. Click “Install via Homebrew” in the banner above.",
        "Скачивание сейчас начнётся…": "Download will start now…",
        "Нужен вход — пробую %@…": "Login required — trying %@…",
        "без входа": "without login",
        "cookies из %@": "cookies from %@",
        "Не удалось запустить %@: %@": "Couldn't launch %@: %@",
        "Перекодирование в H.264… %d%%": "Transcoding to H.264… %d%%",
        "Скачивание аудио… ": "Downloading audio… ",
        "Скачивание… ": "Downloading… ",
        " · осталось %@": " · %@ left",
        "Объединение видео и звука…": "Merging video and audio…",
        "Упаковка в MP4…": "Packaging into MP4…",
        "Скачивание аудио…": "Downloading audio…",
        "Скачивание…": "Downloading…",
        "Отменено": "Cancelled",
        "Готово ✅ (MP3 320 kbps)": "Done ✅ (MP3 320 kbps)",
        "Нужен доступ к диску": "Disk access required",
        "Нужен вход в аккаунт": "Login required",
        "Ошибка": "Error",
        "Это видео требует входа в аккаунт. Чтобы взять cookies из браузера, приложению нужен доступ к диску. Нажми «Открыть настройки» — в списке приложений найди Scorpena и включи «Полный доступ к диску» (если Scorpena там нет — добавь её кнопкой «+»). Перезапусти приложение и повтори.":
            "This video requires being logged in. To grab cookies from your browser, the app needs disk access. Click “Open Settings” — find Scorpena in the list of apps and turn on “Full Disk Access” (if Scorpena isn't there, add it with the “+” button). Restart the app and try again.",
        "Для скачивания требуется вход в аккаунт:\n\nСайт отдаёт это видео только при входе в аккаунт. Войди на сайт в браузере и повтори. Например, Vimeo сейчас требует вход почти для всех роликов, даже открытых.":
            "Logging in is required to download this:\n\nThe site only serves this video to logged-in accounts. Log in to the site in your browser and try again. For example, Vimeo now requires login for almost all videos, even public ones.",
        "Что-то пошло не так. Попробуй ещё раз или сообщи об ошибке. А пока попробуй другую ссылку.":
            "Something went wrong. Try again or report the problem. In the meantime, try a different link.",
        "%d с": "%d s",
        "%d мин %d с": "%d min %d s",
        "Готово ✅": "Done ✅",
        "Проверка кодека…": "Checking codec…",
        "Готово ✅ (кодек не H.264 — ffmpeg недоступен)": "Done ✅ (codec isn't H.264 — ffmpeg unavailable)",
        "Перекодирование в H.264…": "Transcoding to H.264…",
        "Не удалось перекодировать.": "Couldn't transcode.",
        "Готово ✅ (перекодировано в H.264)": "Done ✅ (transcoded to H.264)",
        "Готово ✅ (H.264-копию сохранить не удалось, файл в исходном кодеке)":
            "Done ✅ (couldn't save the H.264 copy — file kept in its original codec)",
        "Видео скачано (%@), но перекодировать в H.264 не удалось. Файл остался в исходном кодеке.":
            "Video downloaded (%@), but transcoding to H.264 failed. The file was kept in its original codec.",
        "Скачано, но не в H.264": "Downloaded, but not H.264",
        "Видео недоступно (удалено, приватное или заблокировано в твоём регионе).":
            "Video unavailable (removed, private, or blocked in your region).",
        "Ссылка не распознана или сайт не поддерживается. Нужен прямой адрес страницы видео (YouTube, VK и т.д.).":
            "Link not recognized or the site isn't supported. A direct video page URL is needed (YouTube, VK, etc.).",
        "Не нашёлся формат под выбранное качество — попробуй «Максимальное».":
            "No format found for the selected quality — try “Best”.",
        "YouTube отклонил загрузку (403). Открой «Дополнительно» → «Проверить сейчас», затем повтори. Или попробуй другую ссылку.":
            "YouTube rejected the download (403). Open “Advanced” → “Check now”, then try again. Or try a different link.",
        "Нет соединения с интернетом.": "No internet connection.",

        // MARK: formatBytes
        "%.2f ГБ": "%.2f GB",
        "%.0f МБ": "%.0f MB",
    ]
}
