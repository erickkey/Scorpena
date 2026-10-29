import AppKit
import SwiftUI

/// A YouTube link that carries a playlist (`…&list=…`, or `/playlist?list=…`).
struct PlaylistLink {
    /// The link also names one particular video (`watch?v=…&list=…`).
    let hasVideo: Bool
    /// Address of the playlist itself, for listing its videos.
    let listURL: String

    /// Auto-generated "Mix" lists («RD…») never end, so they aren't treated as playlists.
    static func detect(_ raw: String) -> PlaylistLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.lowercased().hasPrefix("http") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: text),
              let host = components.host?.lowercased(),
              host.hasSuffix("youtube.com") || host == "youtu.be",
              let list = components.queryItems?.first(where: { $0.name == "list" })?.value,
              !list.isEmpty, !list.hasPrefix("RD") else { return nil }
        let hasVideo = components.queryItems?.contains { $0.name == "v" } == true
            || (host == "youtu.be" && components.path.count > 1)
        return PlaylistLink(hasVideo: hasVideo, listURL: "https://www.youtube.com/playlist?list=\(list)")
    }

    struct Entry {
        let url: String
        let title: String?
    }

    /// Reads the playlist's title and videos (without downloading anything).
    /// Blocking — call from a background queue. `entries` holds at most `limit`
    /// videos; `total` is how many the playlist really has.
    static func fetch(listURL: String, ytDlp: String, limit: Int = 1000) -> (title: String?, entries: [Entry], total: Int)? {
        for cookies in DownloadManager.metadataCookieArgs() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ytDlp)
            p.arguments = ["--flat-playlist", "--no-warnings", "--print", "%(url)s\t%(title)s\t%(playlist_title)s"]
                + DownloadManager.jsRuntimeArgs() + cookies + [listURL]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = DownloadManager.toolSearchPath(ytDlp: ytDlp)
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { continue }

            func clean(_ s: String?) -> String? {
                guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "NA" else { return nil }
                return s
            }
            var title: String?
            var entries: [Entry] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard let url = clean(parts.first), url.hasPrefix("http") else { continue }
                if title == nil { title = clean(parts.count > 2 ? parts[2] : nil) }
                entries.append(Entry(url: url, title: clean(parts.count > 1 ? parts[1] : nil)))
            }
            if entries.isEmpty { continue }
            return (title, Array(entries.prefix(limit)), entries.count)
        }
        return nil
    }

    /// A folder name made from the playlist title.
    static func folderName(for title: String?) -> String {
        let base = (title ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? tr("Плейлист") : String(base.prefix(80))
    }

    /// The small picture YouTube keeps for every video.
    static func thumbnail(forVideoURL url: String) -> URL? {
        guard let id = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
    }
}

// MARK: - The question window

enum PlaylistChoice { case whole, single, cancel }

/// «Это плейлист» — a window in the app's own style (like «Дополнительно» or the
/// history), not a system alert. Closing it with the red button counts as «Отмена».
final class PlaylistQuestionPanel {
    static let shared = PlaylistQuestionPanel()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private var answered = false

    func ask(message: String, canTakeWhole: Bool, canTakeSingle: Bool, onChoice: @escaping (PlaylistChoice) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        window?.close()
        answered = false

        func finish(_ choice: PlaylistChoice) {
            guard !answered else { return }
            answered = true
            window?.close()
            onChoice(choice)
        }

        let win = makeDialogWindow(PlaylistQuestionView(
            message: message, canTakeWhole: canTakeWhole, canTakeSingle: canTakeSingle, onChoose: finish))
        win.makeKeyAndOrderFront(nil)
        window = win

        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { _ in finish(.cancel) }
    }
}

private struct PlaylistQuestionView: View {
    let message: String
    let canTakeWhole: Bool
    let canTakeSingle: Bool
    let onChoose: (PlaylistChoice) -> Void

    @ObservedObject private var languageSettings = LanguageSettings.shared

    var body: some View {
        DialogLayout(title: tr("Это плейлист"), message: message, width: 540) {
            DialogButton(title: tr("Отмена")) { onChoose(.cancel) }
            if canTakeSingle {
                DialogButton(title: tr("Только это видео")) { onChoose(.single) }
            }
            if canTakeWhole {
                DialogButton(title: tr("Весь плейлист"), primary: true) { onChoose(.whole) }
            }
        }
    }
}
