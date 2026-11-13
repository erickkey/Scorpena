import Foundation
import Combine

/// Russian, English, Chinese, Hindi and Spanish. Every user-facing string in the app is authored in Russian and
/// passed through `tr`/`trf`; internal-only text (the technical log, the
/// Telegram error reports and feedback messages the developer reads) is
/// intentionally left untranslated regardless of this setting, since it's
/// never shown to the person using the app.
enum AppLanguage: String, CaseIterable, Identifiable {
    case ru, en, zh, hi, es

    var id: String { rawValue }

    /// The name of the language in the language itself.
    var displayName: String {
        switch self {
        case .ru: return "Русский"
        case .en: return "English"
        case .zh: return "中文"
        case .hi: return "हिन्दी"
        case .es: return "Español"
        }
    }

    var flag: String {
        switch self {
        case .ru: return "🇷🇺"
        case .en: return "🇺🇸"
        case .zh: return "🇨🇳"
        case .hi: return "🇮🇳"
        case .es: return "🇪🇸"
        }
    }

    /// The language of the Mac's own settings, when the app speaks it; English otherwise.
    static var system: AppLanguage {
        for code in Locale.preferredLanguages {
            let base = String(code.prefix(2)).lowercased()
            if let found = AppLanguage(rawValue: base) { return found }
        }
        return .en
    }

    /// Decimal comma (1,5) in Russian and Spanish, decimal point (1.5) in the others.
    var usesDecimalComma: Bool { self == .ru || self == .es }

    /// For dates and times.
    var localeIdentifier: String { self == .zh ? "zh-Hans" : rawValue }

    /// Which recorded «download complete» voice belongs to the language.
    var voiceSuffix: String {
        switch self {
        case .ru: return ""
        case .en: return "EN"
        case .zh: return "CN"
        case .hi: return "HI"
        case .es: return "ES"
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
        // Never chosen yet: the language of the Mac (the choice window shows it as the first pick).
        language = raw.flatMap(AppLanguage.init(rawValue:)) ?? AppLanguage.system
    }
}

/// Translates a Russian UI string to English when the app's language is set
/// to English; returns it unchanged otherwise (including when no
/// translation is on file — better a Russian string than a blank one).
func tr(_ russian: String) -> String {
    switch LanguageSettings.shared.language {
    case .ru: return russian
    case .en: return Translations.en[russian] ?? russian
    case .zh: return Translations.zh[russian] ?? Translations.en[russian] ?? russian
    case .hi: return Translations.hi[russian] ?? Translations.en[russian] ?? russian
    case .es: return Translations.es[russian] ?? Translations.en[russian] ?? russian
    }
}

/// A text that was translated earlier and is still on screen (an error, «cancelled»…), put into the
/// language that is on now. nil when it is not a plain translation (it carries numbers, say).
func retranslated(_ shown: String) -> String? {
    struct Reverse { static let table: [String: String] = {
        var table: [String: String] = [:]
        for dictionary in [Translations.en, Translations.zh, Translations.hi, Translations.es] {
            for (russian, translated) in dictionary { table[translated] = russian }
        }
        return table
    }() }
    if let russian = Reverse.table[shown] { return tr(russian) }
    if Translations.en[shown] != nil { return tr(shown) }      // it is the Russian text itself
    return nil
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
        "Программа для Mac: скачивание видео и звука с YouTube, VK, Instagram, TikTok, Vimeo и ещё более 1000 сайтов, а также вырезание фрагментов, очередь, плейлисты, история и другие инструменты для загрузок.": "A program for Mac: downloading video and audio from YouTube, VK, Instagram, TikTok, Vimeo and more than 1000 other sites, as well as cutting out clips, a queue, playlists, history and other tools for downloads.",
        "пауза и воспроизведение": "pause and play",
        "перемотка на 5 секунд": "skip 5 seconds",
        "точная перемотка на 1 секунду": "precise skip of 1 second",
        "покадровая перемотка": "frame by frame",
        "отметить начало и конец отрезка": "mark the start and end of the clip",
        "быстрый переход по видео (5 это середина)": "quick jump through the video (5 is the middle)",
        "Клавиши": "Keys",
        "Не удалось продолжить загрузку. Проверь ссылку или добавь её заново.": "Couldn't continue the download. Check the link or add it again.",
        "Ножницы: вырезание нужного куска видео, ввод времени вручную, навигация клавишами": "Scissors: cutting out the part of a video you need, typing the times in by hand, keyboard navigation",
        "Светлая и тёмная тема": "Light and dark theme",
        "Выбери язык": "Choose your language",
        "Свернуть все": "Collapse all",
        "Развернуть все": "Expand all",
        "Напоминание об очистке": "Cleanup reminder",
        "Раз в неделю": "Weekly",
        "Раз в месяц": "Monthly",
        "Никогда": "Never",
        "Очистить сейчас": "Clean up now",
        "Чистить пока нечего.": "Nothing to clean up yet.",
        "Идёт скачивание": "Download in progress",
        "Если закрыть программу сейчас, скачивание остановится. Оно продолжится, когда ты откроешь программу снова.": "If you close the app now, the download will stop. It will carry on when you open the app again.",
        "Всё равно закрыть": "Close anyway",
        "Остаться": "Stay",
        "Пора прибраться": "Time to tidy up",
        "Старые записи истории и недокачанные видео занимают %@. Удалить их? Твои скачанные файлы останутся на месте.": "Old history entries and unfinished videos take up %@. Delete them? Your downloaded files will stay where they are.",
        "Почистить": "Clean up",

        // MARK: Header / footer
        "Дополнительно": "Advanced",
        "Светлая / тёмная тема": "Light / dark theme",
        "О программе": "About",
        "Правовая информация": "Legal Information",
        "Обратная связь": "Feedback",
        "Поделиться": "Share",
        "Поддержать": "Support",
        "Справка": "Help",
        "Что нового": "What's new",
        "Программа бесплатная. Если она тебе пригодилась, можно поддержать её развитие.": "The app is free. If you find it useful, you can support its development.",
        "Доступно обновление": "Update available",

        // MARK: URL field
        "Кажется, это не ссылка: проверь, что скопировалось":
            "Doesn't look like a link: check what you copied",
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
        "Необычный сайт: программа попробует, но результат не гарантирован":
            "Unusual site: the app will try, but success isn't guaranteed",
        "Сайт есть в списке поддерживаемых ✅": "Site is in the supported list ✅",
        "видео": "video",

        // MARK: Quality section
        "Максимально доступное": "Best available",
        "Максимальное": "Best",
        "Максимальное: %@":
            "Best: %@",

        // MARK: Destination
        "Куда сохранять видео": "Where to save videos",

        // MARK: Action row
        "Отменить": "Cancel",
        "Показать файл": "Show file",

        // MARK: Progress / status
        "с": "s",
        "Программа запрашивает у сайта данные о видео: адреса потоков и способ обхода защиты. Обычно 2–10 секунд.":
            "The app is asking the site for the video's info: stream addresses and how to get past its protection. Usually 2–10 seconds.",
        "Сайт отдаёт видео множеством мелких кусков, а не одним файлом. Их приходится качать по очереди, поэтому медленнее обычного. У Vimeo почти всегда так.":
            "The site serves the video in lots of tiny pieces instead of one file. They have to be downloaded one by one, so it's slower than usual. Vimeo almost always does this.",
        "Сообщить об ошибке": "Report a problem",
        "Отправлено (обращение №%@). Спасибо!":
            "Sent (ticket #%@). Thanks!",
        "Не удалось отправить. Текст скопирован, отправь вручную в Telegram":
            "Couldn't send it. The text was copied, send it manually via Telegram",

        // MARK: Banners
        "Чтобы программа могла показать сайту, что ты не робот, используя куки.": "So the app can show the site that you’re not a robot, using cookies.",
        "Открыть настройки": "Open Settings",

        // MARK: Advanced settings window
        "Закрыть": "Close",
        "Уведомления": "Notifications",
        "Обновление внутренних инструментов": "Built-in tools update",
        "Обновление программы": "App update",
        "Версия %@.": "Version %@.",
        "Обновить": "Update",
        "Обновления": "Updates",
        "Версия %@. Доступна новая: %@.": "Version %@. A new one is available: %@.",
        "Версия %@. У тебя последняя.": "Version %@. You have the latest.",
        "Язык": "Language",

        // MARK: What's New
        "Круто": "Cool",
        "Список изменений": "What's New",
        "Проект на GitHub": "Project on GitHub",
        "Это видео недоступно в твоей стране. Включи VPN или поменяй в нём страну и попробуй ещё раз.": "This video is not available in your country. Turn on a VPN or change its country, then try again.",
        "Сейчас идёт скачивание": "A download is in progress",
        "Отчёты о сбоях": "Crash reports",
        "Программа скачивает видео с помощью внутренних инструментов и сама их обновляет. Если видео перестало скачиваться, нажми «Проверить сейчас».":
            "The app downloads videos using internal tools and updates them by itself. If videos stop downloading, press “Check now”.",
        "Проверить сейчас": "Check now",
        "Проверяю…": "Checking…",
        "У тебя последняя версия (%@). Проверка заняла %d с.": "You have the latest version (%@). The check took %d s.",
        "Обновлено: %@ → %@ ✅ (за %d с)": "Updated: %@ → %@ ✅ (in %d s)",
        "Шаг %d из 4 · %@": "Step %d of 4 · %@",
        "Проверяю на GitHub, вышла ли новая версия…": "Checking GitHub for a new version…",
        "Обычно занимает до минуты.": "Usually takes up to a minute.",
        "yt-dlp %@": "yt-dlp %@",
        "Новая версия %@ не прошла проверку, оставил %@.":
            "The new version %@ didn't pass the check, kept %@.",
        "Не удалось проверить обновления: нет связи с интернетом.":
            "Couldn't check for updates: no internet connection.",
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
        "Новая версия не запустилась, поэтому вернули прежнюю. Ничего не сломалось, можно скачать новую вручную.":
            "The new version wouldn't start, so the previous one was put back. Nothing broke, you can download the new one manually.",
        "Скачать вручную": "Download manually",
        "Нет связи с интернетом или GitHub недоступен. Проверь подключение и попробуй ещё раз.": "No internet connection, or GitHub is unreachable. Check your connection and try again.",
        "GitHub не отдал файл обновления (код %d). Попробуй позже или скачай вручную.": "GitHub didn't serve the update file (code %d). Try later or download it manually.",
        "Не хватает места на диске. Освободи около 1 ГБ и попробуй снова.": "Not enough disk space. Free up about 1 GB and try again.",
        "Скачанный файл не открылся: возможно, загрузка прервалась. Попробуй ещё раз.":
            "The downloaded file wouldn't open: the download may have been interrupted. Try again.",
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
            "“Advanced” — now its own window, not a dropdown at the bottom.",
        "«Поделиться» — можно быстро отправить другу ссылку на программу.":
            "“Share” — quickly send a friend a link to the app.",
        "Обновление встроенных инструментов — понятный раздел: «Проверить обновление» показывает, есть ли новая версия, кнопка «Обновить» активна только когда реально есть что обновлять.":
            "Built-in tools update — a clear section: “Check for update” shows whether a new version exists, and “Update” is only enabled when there's actually something to update.",
        "«Обратная связь» — отдельный раздел: написать вопрос, пожелание или что угодно ещё, по желанию оставив имя и контакт.":
            "“Feedback” — a dedicated section: write a question, a suggestion, or anything else, optionally leaving your name and contact.",
        "Программа переименована": "The app has been renamed",
        "Переименовываю…": "Renaming…",
        "Секунду, сейчас программа перезапустится.": "One second, the app is about to restart.",
        "Ладно": "OK",
        "Теперь она называется Scorpena – video downloader. Настройки и история на месте. Программа один раз перезапустится. Если рядом осталась старая копия, её можно удалить.": "It's now called Scorpena – video downloader. Your settings and history are untouched. The app will restart once. If an old copy is left next to it, you can delete it.",
        "Теперь она называется Scorpena – video downloader. Настройки и история на месте. Если рядом осталась старая копия, её можно удалить.": "It's now called Scorpena – video downloader. Your settings and history are untouched. If an old copy is left next to it, you can delete it.",
        "Скачиваю новую версию (около 54 МБ) и сверяю контрольную сумму…": "Downloading the new version (about 54 MB) and checking its checksum…",
        "Распаковываю новую версию рядом со старой…": "Unpacking the new version next to the old one…",
        "Проверяю, что новая версия работает с YouTube, и только потом заменяю…": "Checking that the new version works with YouTube, and only then replacing…",
        "Без ограничения": "No limit",
        "Внутри программы не хватает файлов. Скачай Scorpena заново.": "Some files inside the app are missing. Download Scorpena again.",
        "Внутри программы не хватает файлов": "Some files inside the app are missing",
        "Скачай Scorpena заново: все файлы встанут на место, настройки и история сохранятся.": "Download Scorpena again: everything will be put back in place, and your settings and history are kept.",
        "Открыть страницу загрузки": "Open the download page",
        "Звук уведомления о скачивании": "Download notification sound",
        "Звук запуска приложения": "App launch sound",
        "Выбор качества:": "Choose quality:",
        "Показать папку": "Show folder",
        "Возможности": "Features",
        "Ограничения": "Limitations",
        "**Загрузка:** видео (MP4, MOV, WebM, MKV) и звук (MP3, WAV, M4A)": "**Download:** video (MP4, MOV, WebM, MKV) and audio (MP3, WAV, M4A)",
        "**Качество и размер:** перед скачиванием видно, какое качество есть и сколько будет весить файл": "**Quality and size:** before downloading, you can see which qualities exist and how big the file will be",
        "**Фрагменты:** можно скачать не всё видео, а только нужный кусок": "**Clips:** you can download just the part you need instead of the whole video",
        "**Очередь:** до 3 видео скачиваются одновременно, остальные запускаются автоматически по мере завершения предыдущих": "**Queue:** up to 3 videos download at once, the rest start automatically as the previous ones finish",
        "**Плейлисты:** скачивание плейлистов": "**Playlists:** downloading playlists",
        "**История:** список скачанного, откуда файл открывается в один клик": "**History:** a list of what was downloaded, where the file opens in one click",
        "**Докачка:** если закрыть программу или пропал интернет, скачивание продолжится": "**Resume:** if the app is closed or the internet drops, the download carries on",
        "**Скорость:** ограничение скорости скачивания": "**Speed:** a limit on the download speed",
        "**Ссылка:** скопированная ссылка вставляется в поле сама": "**Link:** a copied link is pasted into the field automatically",
        "**Оформление:** светлая и тёмная тема, пять языков": "**Appearance:** light and dark theme, five languages",
        "**Обновление:** новая версия ставится одной кнопкой": "**Updates:** a new version installs with one button",
        "**Совместимость:** любой Mac (Intel и Apple Silicon), macOS 13 и новее": "**Compatibility:** any Mac (Intel and Apple Silicon), macOS 13 or later",
        "**Защищённый контент:** Netflix, Disney+, Prime Video, Apple TV+, Кинопоиск, ivi, Okko и другие сервисы с DRM скачать нельзя: они шифруют видео от копирования": "**Protected content:** Netflix, Disney+, Prime Video, Apple TV+, Kinopoisk, ivi, Okko and other DRM services cannot be downloaded: they encrypt video against copying",
        "**Прямые трансляции:** можно записать только уже закончившиеся эфиры": "**Live streams:** only streams that have already ended can be recorded",
        "Пять языков: русский, английский, китайский, хинди, испанский": "Five languages: Russian, English, Chinese, Hindi, Spanish",
        "Нашёл удобную программу для Mac: SCORPENA – video downloader. Она скачивает видео и аудио с YouTube, VK, Instagram, TikTok и ещё кучи сайтов в один клик. Вот ссылка на актуальную версию:": "Found a handy app for Mac: SCORPENA – video downloader. It downloads video and audio from YouTube, VK, Instagram, TikTok and loads of other sites in one click. Here is the link to the current version:",
        "Скопировать": "Copy",
        "Новое": "New",
        "Улучшения": "Improvements",
        "Исправлено": "Fixed",
        "Галочка «Открывать папку после загрузки»": "The “Open the folder after the download” checkbox",
        "Ссылки на видео можно вставлять прямо в окне очереди, как на главной": "Video links can be pasted right in the queue window, as on the main one",
        "В истории видно, сколько длится видео и когда его скачали, записи можно удалять": "History shows how long a video is and when it was downloaded; entries can be removed",
        "Плейлист скачивается в свою папку": "A playlist downloads into its own folder",
        "Качество определяется, как только вставишь ссылку": "The quality is detected as soon as you paste a link",
        "Полоса скачивания больше не дёргается, рядом написано, сколько уже скачано": "The download bar no longer jerks, and next to it you can see how much has been downloaded",
        "Новые значки, окна закрываются на Esc": "New icons, windows close with Esc",
        "Полоса скачивания больше не замирает и не идёт назад": "The download bar no longer freezes or goes back",
        "Если поменять скорость во время скачивания, оно не сбрасывается": "Changing the speed during a download no longer resets it",
        "Для звука больше не показывается качество видео": "The video quality is no longer shown for audio",
        "Общие улучшения стабильности": "General stability improvements",
        "Внеплановое обновление": "Unplanned update",
        "Исправление критических ошибок": "Critical bug fixes",
        "**Вырезание фрагмента:** скачивание части видео по отметкам начала и конца, управление клавишами": "**Clip cutting:** downloading part of a video by start and end marks, keyboard control",
        "**Очередь загрузок:** одновременное скачивание нескольких видео, пауза, сохранение очереди при закрытии программы": "**Download queue:** several videos at once, pause, the queue is saved when the program closes",
        "**Языки и тема:** русский, английский, китайский, хинди, испанский, светлая и тёмная тема": "**Languages and theme:** Russian, English, Chinese, Hindi, Spanish, light and dark theme",
        "**Открытие папки:** автоматически после загрузки, включается в настройках": "**Opening the folder:** automatically after the download, turned on in the settings",
        "**История:** длительность видео, время скачивания, удаление записей": "**History:** video length, download time, deleting entries",
        "**Плейлисты:** скачивание в отдельную папку": "**Playlists:** downloading into a separate folder",
        "**Качество:** определение сразу после вставки ссылки": "**Quality:** detected right after a link is pasted",
        "**Значки и окна:** новые значки, закрытие на Esc": "**Icons and windows:** new icons, closing with Esc",
        "**Ограничение скорости:** смена во время скачивания больше не сбрасывает загрузку": "**Speed limit:** changing it during a download no longer resets the download",
        "**Стабильность:** общие улучшения": "**Stability:** general improvements",
        "**Обновление программы:** заметная полоса с кнопкой «Обновить» вверху окна": "**App update:** a prominent bar with an “Update” button at the top of the window",
        "**Настройки:** раздел «Обновления». Обновление программы и обновление внутренних инструментов теперь разделены": "**Settings:** the “Updates” section. Updating the app and updating the built-in tools are now separate",
        "**Меню:** упрощённый состав пунктов, сочетания клавиш работают": "**Menu:** a simplified set of items, keyboard shortcuts work",
        "**Исправления и улучшения:** устранение ошибок, повышение стабильности": "**Fixes and improvements:** bug fixes, better stability",
        "Этот отрывок уже скачивается или стоит в очереди": "This clip is already downloading or waiting in the queue",
        "Файл уже скачан": "File already downloaded",
        "Плейлист не найден": "Playlist not found",
        "Вставь ссылку на видео": "Paste a video link",
        "Скачать": "Download",
        "без звука": "no audio",
        "Папка:": "Folder:",
        "%d Мбит/с": "%d Mbit/s",
        "≈ %@ МБ/с": "≈ %@ MB/s",
        "Скорость скачивания": "Download speed",
        "Пауза": "Pause",
        "Продолжить": "Resume",
        "Пауза: нажми «Продолжить»":
            "Paused: press “Resume”",
        "Нет связи, жду и продолжу сам…":
            "No connection, waiting to carry on by itself…",
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
        "Исправлена ошибка при скачивании, когда мешает VPN или нет интернета.": "Fixed a download error when a VPN gets in the way or there is no internet.",
        "Множество мелких улучшений и исправлений.": "Lots of small improvements and fixes.",
        "Обновление программы теперь одной кнопкой (наконец-то).": "Updating the app is now one button (finally).",
        "Встроенный загрузчик обновляется сам.": "The built-in downloader updates itself.",
        "История скачиваний.": "Download history.",
        "Поправлен баг – новая скопированная ссылка теперь сама заменяет старую.": "Fixed a bug – a newly copied link now replaces the old one by itself.",
        "Анонимные отчёты о сбоях теперь автоматические (отключаются в «Дополнительно»).": "Anonymous crash reports are now automatic (you can turn them off in “Advanced”).",
        "Версия программы видна в шапке окна.": "The app version is shown in the header.",
        "Технический журнал скрыт от пользователя.": "The technical log is now hidden from the user.",
        "Мелкие внутренние улучшения и исправления.": "Minor internal improvements and fixes.",

        // MARK: About window
        "Скопируй ссылку и нажми «Скачать»": "Copy the link and hit “Download”",
        "Размер файла и доступное качество видны до скачивания.": "File size and available quality are shown before downloading.",
        "Ссылка из буфера обмена подставляется сама.": "A link from the clipboard is filled in automatically.",
        "Отчёт об ошибке разработчику в один клик.": "Error report to the developer in one click.",
        "Русский и английский языки.": "Russian and English languages.",
        "Несколько скачиваний одновременно, остальные ждут в очереди.": "Several downloads at once, the rest wait in the queue.",
        "Плейлисты целиком.": "Whole playlists.",
        "Встречайте! Новое название и новый дизайн!": "Meet the new name and the new design!",
        "Новый облик, новые возможности, и всё работает лучше и быстрее, чем раньше.": "A new look, new features, and everything works better and faster than before.",
        "Можно качать несколько видео сразу.": "You can download several videos at once.",
        "Скачивание плейлистов.": "Downloading playlists.",
        "Новое окно «Загрузки»: очередь и история в одном месте.": "A new “Downloads” window: the queue and the history in one place.",
        "Очередь и пауза запоминаются при закрытии программы.": "The queue and pauses are remembered when you close the app.",
        "Если для видео нужен вход в аккаунт, Scorpena подскажет, что делать.": "If a video needs you to sign in, Scorpena will tell you what to do.",
        "Напоминание об очистке старой истории и недокачанных файлов.": "A reminder to clear old history and unfinished downloads.",
        "История и очередь загрузок.": "Download history and queue.",
        "Напоминание об очистке места на диске.": "A reminder to free up disk space.",
        "Пауза и продолжение скачивания, даже если пропал интернет или программа была закрыта.": "Pause and resume downloads, even if the internet drops or the app was closed.",
        "Ограничение скорости скачивания в «Дополнительно» (⚙).": "Download speed limit in “Advanced” (⚙).",
        "Обновление программы одной кнопкой.": "Updating the app with one button.",
        "Любой Mac: Intel и Apple Silicon, macOS 13 и новее.": "Any Mac: Intel and Apple Silicon, macOS 13 or newer.",
        "Благодарю": "Thanks",

        // MARK: Feedback window
        "Вопросы, предложения, ошибки: что угодно. Уходит прямо разработчику.":
            "Questions, suggestions, bugs: anything at all. Goes straight to the developer.",
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
        "Это не юридическая консультация, а общие ориентиры. Законы отличаются в разных странах, поэтому перед использованием программы проверь, что допускает закон в твоей стране. Если сомневаешься, консультируйся с юристом.":
            "This isn't legal advice, just general guidance. Laws differ between countries, so check what's allowed where you live before using the app. If you're unsure, consult a lawyer.",
        "Сама программа легальна.": "The app itself is legal.",
        "Внутри открытый движок yt-dlp. Scorpena – video downloader просто удобная оболочка над ним. Она не взламывает сайты: берёт те же потоки, что сайт и так отдаёт браузеру.":
            "Under the hood is the open-source yt-dlp engine. Scorpena – video downloader is just a convenient shell around it. It doesn't hack sites: it fetches the same streams a site already serves to a browser.",
        "Scorpena – video downloader позволяет сохранять видео и аудио локально. Убедись, что твоё использование соответствует законодательству твоей страны и условиям сервиса, с которого ты скачиваешь контент.":
            "Scorpena – video downloader lets you save video and audio locally. Make sure your use complies with the law in your country and the terms of the service you're downloading from.",
        "Нельзя:": "Not allowed:",
        "обходить платную подписку и DRM (Netflix, Disney+, Prime Video, Apple TV+, Кинопоиск и т.д.): программа этого и не умеет.":
            "bypassing a paid subscription or DRM (Netflix, Disney+, Prime Video, Apple TV+, Kinopoisk, etc.): the app can't do this anyway.",
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

        // MARK: DownloadManager — tooling
        "Не удалось проверить обновления.": "Couldn't check for updates.",

        // MARK: DownloadManager — download flow
        "Вставь ссылку на видео.": "Paste a video link.",
        "Скачивание сейчас начнётся…": "Download will start now…",
        "Нужен вход, пробую %@…":
            "Login required, trying %@…",
        "без входа": "without login",
        "cookies из %@": "cookies from %@",
        "Не удалось запустить %@: %@": "Couldn't launch %@: %@",
        "Скачивание аудио… ": "Downloading audio… ",
        "Скачивание… ": "Downloading… ",
        "Скачивание аудио…": "Downloading audio…",
        "Скачивание…": "Downloading…",
        "Отменено": "Cancelled",
        "Нужен доступ к диску": "Disk access required",
        "Очередь загрузок": "Download queue",
        "Очередь пуста": "The queue is empty",
        "Ждёт очереди": "Waiting",
        "Недавно завершённые": "Recently finished",
        "Готово": "Done",
        "Убрать из очереди": "Remove from the queue",
        "Убрать из списка": "Remove from the list",
        "Это плейлист": "This is a playlist",
        "Скачать весь плейлист или только это видео?": "Download the whole playlist or just this video?",
        "Весь плейлист": "Whole playlist",
        "Только это видео": "Just this video",
        "Читаю плейлист…": "Reading the playlist…",
        "Нужен вход или плейлиста не существует": "Sign-in needed, or the playlist doesn’t exist",
        "В очередь добавлено видео: %d": "Videos added to the queue: %d",
        "Плейлист": "Playlist",
        "Загрузок идёт: %d · в очереди: %d · готово: %d": "Downloading: %d · in the queue: %d · done: %d",
        "Открыть очередь": "Open the queue",
        "В плейлисте %d видео. Скачать весь плейлист или только это видео?": "The playlist has %d videos. Download the whole playlist or just this video?",
        "В плейлисте %d видео. Скачать их все? Они встанут в очередь загрузок.": "The playlist has %d videos. Download them all? They will go into the download queue.",
        "За один раз добавятся первые %d.": "The first %d will be added at a time.",
        "Остановить все": "Pause all",
        "Продолжить все": "Resume all",
        "Удалить все": "Remove all",
        "Эта ссылка уже скачивается или стоит в очереди": "This link is already downloading or in the queue",
        "Загрузки": "Downloads",
        "Очередь": "Queue",
        "История": "History",
        "Сегодня": "Today",
        "Вчера": "Yesterday",
        "За этот день больше 100 записей. Можно очистить.": "More than 100 entries for this day. You can clear it.",
        "Плейлист · %d видео": "Playlist · %d videos",
        "Голос": "Voice",
        "Женский": "Female",
        "Мужской": "Male",
        "Нужен вход в аккаунт": "Login required",
        "Ошибка": "Error",
        "Это видео требует входа в аккаунт. Чтобы взять cookies из браузера, приложению нужен доступ к диску. Нажми «Открыть настройки»: в списке приложений найди Scorpena и включи «Полный доступ к диску» (если Scorpena там нет, добавь её кнопкой «+»). Перезапусти приложение и повтори.":
            "This video requires being logged in. To grab cookies from your browser, the app needs disk access. Click “Open Settings”: find Scorpena in the list of apps and turn on “Full Disk Access” (if Scorpena isn't there, add it with the “+” button). Restart the app and try again.",
        "Для скачивания требуется вход в аккаунт:\n\nСайт отдаёт это видео только при входе в аккаунт. Войди на сайт в браузере и повтори. Например, Vimeo сейчас требует вход почти для всех роликов, даже открытых.":
            "Logging in is required to download this:\n\nThe site only serves this video to logged-in accounts. Log in to the site in your browser and try again. For example, Vimeo now requires login for almost all videos, even public ones.",
        "Что-то пошло не так. Попробуй ещё раз или сообщи об ошибке. А пока попробуй другую ссылку.":
            "Something went wrong. Try again or report the problem. In the meantime, try a different link.",
        "%d с": "%d s",
        "%d мин %d с": "%d min %d s",
        "Готово ✅": "Done ✅",
        "Готово ✅ (кодек не H.264, ffmpeg недоступен)":
            "Done ✅ (codec isn't H.264, ffmpeg unavailable)",
        "Не удалось перекодировать.": "Couldn't transcode.",
        "Готово ✅ (перекодировано в H.264)": "Done ✅ (transcoded to H.264)",
        "Готово ✅ (H.264-копию сохранить не удалось, файл в исходном кодеке)":
            "Done ✅ (couldn't save the H.264 copy, file kept in its original codec)",
        "Видео скачано (%@), но перекодировать в H.264 не удалось. Файл остался в исходном кодеке.":
            "Video downloaded (%@), but transcoding to H.264 failed. The file was kept in its original codec.",
        "Скачано, но не в H.264": "Downloaded, but not H.264",
        "Видео недоступно (удалено, приватное или заблокировано в твоём регионе).":
            "Video unavailable (removed, private, or blocked in your region).",
        "Ссылка не распознана или сайт не поддерживается. Нужен прямой адрес страницы видео (YouTube, VK и т.д.).":
            "Link not recognized or the site isn't supported. A direct video page URL is needed (YouTube, VK, etc.).",
        "Здесь нет видео или аудио. Нужна другая ссылка.": "There is no video or audio here. A different link is needed.",
        "Не нашёлся формат под выбранное качество. Попробуй «Максимальное».":
            "No format found for the selected quality. Try “Best”.",
        "YouTube отклонил загрузку (403). Открой «Дополнительно» → «Проверить сейчас», затем повтори. Или попробуй другую ссылку.":
            "YouTube rejected the download (403). Open “Advanced” → “Check now”, then try again. Or try a different link.",
        "Не получилось связаться с сайтом. Если включён VPN, попробуй его выключить.": "Couldn't reach the site. If a VPN is on, try turning it off.",
        "Вырезать фрагмент": "Cut a clip",
        "Вставь ссылку и ролик откроется здесь": "Paste a link and the video will open here",
        "Готовлю просмотр…": "Getting the preview ready…",
        "Готовлю просмотр… %d%%": "Getting the preview ready… %d%%",
        "Не получилось открыть ролик для просмотра.": "Couldn't open the video for preview.",
        "Просмотр в сниженном качестве. Скачается в том, что выбрано ниже": "Preview is in lower quality. It will download in the quality chosen below",
        "Начало": "Start",
        "Конец": "End",
        "Начало здесь": "Start here",
        "Конец здесь": "End here",
        "Посмотреть фрагмент": "Preview the clip",
        "Скачать фрагмент": "Download the clip",
        "Сейчас %@ из %@": "Now %@ of %@",
        "Фрагмент:": "Clip:",
        "весь ролик:": "whole video:",
        "фрагмент": "clip",
        "Фрагмент добавлен в загрузки. Выбери ещё один или закрой окно": "Clip added to downloads. Pick another or close the window",
        "ГБ": "GB",
        "МБ": "MB",
        "КБ": "KB",
        "Открывать папку после загрузки": "Open the folder after the download",
        "Сразу, если одно видео. Когда скачается всё, если плейлист или очередь.": "Right away if it is one video. When everything has downloaded if it is a playlist or a queue.",
        "Файл не найден": "File not found",
        "из": "of",
        "Конвертирую в %@…": "Converting to %@…",
        "Склеиваю видео и звук…": "Joining video and sound…",
        "Перекодирую видео…": "Re-encoding the video…",
        "Перекодирую видео… %d%%": "Re-encoding the video… %d%%",
        "Сохраняю файл…": "Saving the file…",
        "При поддержке Александра Семенова (opragopa)": "With support from Alexander Semenov (opragopa)",
        "Очистить записи за %@?": "Clear entries for %@?",
        "Записи за %@ будут удалены из списка. Скачанные файлы не затрагиваются.": "Entries for %@ will be removed from the list. Your downloaded files are not touched.",
        "Очистить записи за %@": "Clear entries for %@",
        "Добавить в очередь": "Add to queue",
        "Добавлено в очередь": "Added to the queue",
        "Ты уже скачивал это видео с такими же настройками. Файл лежит в папке.": "You've already downloaded this video with the same settings. The file is in the folder.",
        "Скачать ещё раз": "Download again",
        "МБ/с": "MB/s",
        "КБ/с": "KB/s",
        "Удалить из истории": "Remove from history",

        // MARK: formatBytes
    ]
}
