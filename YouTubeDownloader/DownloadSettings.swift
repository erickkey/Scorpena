import Foundation

/// The container «Скачать видео» saves. MP4 and MOV hold H.264 (plays
/// everywhere, converted afterwards when a site only has something else); WebM
/// and MKV keep the site's own streams.
enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov, webm, mkv

    static let key = "videoFormat"
    var id: String { rawValue }

    static var current: VideoFormat {
        VideoFormat(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mp4
    }

    var title: String {
        switch self {
        case .mp4:  return "MP4"
        case .mov:  return "MOV"
        case .webm: return "WebM"
        case .mkv:  return "MKV"
        }
    }

    /// MP4 and MOV are checked afterwards and converted to H.264 when needed.
    var convertsToH264: Bool { self == .mp4 || self == .mov }

    static let fileExtensions: Set<String> = ["mp4", "mkv", "webm", "mov", "m4v"]
}

/// The format «Скачать звук» saves.
enum AudioFormat: String, CaseIterable, Identifiable {
    case mp3, wav, m4a

    static let key = "audioFormat"
    var id: String { rawValue }

    static var current: AudioFormat {
        AudioFormat(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .mp3
    }

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .wav: return "WAV"
        case .m4a: return "M4A"
        }
    }

    /// "Готово ✅ (MP3)" — just the format, no extras.
    var resultName: String { title }

    var convertingStatus: String { trf("Конвертация в %@…", title) }

    var fileExtensions: Set<String> {
        switch self {
        case .mp3: return ["mp3"]
        case .wav: return ["wav"]
        case .m4a: return ["m4a", "aac"]
        }
    }

    /// yt-dlp options for audio-only downloads. MP3 and M4A (AAC audio,
    /// which every Apple app plays) get the cover art and tags; WAV can't carry them.
    var ytDlpArgs: [String] {
        let tags = ["--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "jpg"]
        switch self {
        case .mp3: return ["-f", "ba/b", "-x", "--audio-format", "mp3", "--audio-quality", "320K"] + tags
        case .wav: return ["-f", "ba/b", "-x", "--audio-format", "wav"]
        case .m4a: return ["-f", "ba[ext=m4a]/ba/b", "-x", "--audio-format", "m4a"] + tags
        }
    }
}

/// Download speed cap, chosen with a 10-step slider in «Дополнительно». Steps
/// are in megabits per second — the unit an internet plan is sold in; the
/// matching MB/s is shown beside it. The last step means "no limit" (default).
enum SpeedLimit {
    static let key = "speedLimitStep"
    /// Mbit/s for each step; 0 = no limit.
    static let steps = [5, 10, 20, 30, 50, 75, 100, 150, 200, 0]
    static var defaultStep: Int { steps.count - 1 }

    private static func mbit(step: Int) -> Int { steps[min(max(step, 0), steps.count - 1)] }

    /// Mbit/s for the saved step (0 = no limit).
    static var current: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return 0 }
        return mbit(step: defaults.integer(forKey: key))
    }

    /// "50 Мбит/с"
    static func title(step: Int) -> String {
        let value = mbit(step: step)
        return value == 0 ? tr("Без ограничения") : trf("%d Мбит/с", value)
    }

    /// "≈ 6,3 МБ/с" — the same speed in the units file sizes use.
    static func megabytesNote(step: Int) -> String? {
        let value = mbit(step: step)
        guard value > 0 else { return nil }
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        let text = formatter.string(from: NSNumber(value: Double(value) / 8)) ?? "\(value / 8)"
        return trf("≈ %@ МБ/с", text)
    }

    /// yt-dlp wants bytes per second; the limit comes in kilobits per second.
    static func ytDlpArgs(kbit: Int) -> [String] {
        kbit > 0 ? ["--limit-rate", "\(kbit * 125)"] : []
    }
}

/// A download that didn't finish — paused by the user, or cut off when the app
/// was closed. yt-dlp keeps the partial file, so running the same request again
/// continues from where it stopped.
struct UnfinishedDownload: Codable, Equatable {
    var url: String
    var destination: String
    var maxHeight: Int?
    var audioOnly: Bool
    var stripAudio: Bool
    var videoFormat: String
    var audioFormat: String
    var name: String?

    private static let key = "unfinishedDownload"

    static var saved: UnfinishedDownload? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UnfinishedDownload.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// What to call it in a prompt: the file name when yt-dlp has printed one, else the site.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return URL(string: url)?.host ?? url
    }
}

/// Whose voice says "download complete".
enum ChimeVoice: String, CaseIterable, Identifiable {
    case female, male

    static let key = "chimeVoice"
    var id: String { rawValue }

    static var current: ChimeVoice {
        ChimeVoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .female
    }

    var title: String {
        switch self {
        case .female: return tr("Женский")
        case .male:   return tr("Мужской")
        }
    }

    /// Russian recordings in the Russian interface, English ones in the English one.
    var resourceName: String {
        let suffix = LanguageSettings.shared.language == .en ? "EN" : ""
        switch self {
        case .female: return "DownloadComplete" + suffix
        case .male:   return "DownloadCompleteMale" + suffix
        }
    }

    var soundURL: URL? { Bundle.main.url(forResource: resourceName, withExtension: "mp3") }
}
