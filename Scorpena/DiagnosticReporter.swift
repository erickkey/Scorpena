import Foundation
import AppKit

/// Automatic, anonymous reports to the developer about failures that matter —
/// the kind a friend would never think to write about. Nothing here ever
/// includes a link, a file name or anything personal: only app/system
/// versions, the kind of failure and a short technical reason.
///
/// Each kind of report is sent at most once per ~20 hours per install, and
/// at most a handful per day overall, so a persistent problem can't flood
/// the bot. The user can switch all of it off in «Дополнительно».
enum DiagnosticReporter {
    static let enabledKey = "sendDiagnosticReports"
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    enum Kind: String {
        case appUpdateFailed = "не удалось обновить приложение"
        case appUpdateRolledBack = "новая версия не запустилась, вернули прежнюю"
        case ytDlpRolledBack = "yt-dlp откатили после обновления"
        case crash = "приложение аварийно закрылось"
        case toolBroken = "встроенный инструмент не работает"
        case repeatedFailures = "скачивание не удаётся несколько раз подряд"
    }

    private static let sentKey = "diagnosticReportSentAt"
    private static let idKey = "diagnosticInstallId"
    private static let crashCheckKey = "diagnosticLastCrashCheck"
    private static let failuresKey = "diagnosticRecentFailures"

    // MARK: Sending

    static func report(_ kind: Kind, details: String) {
        guard enabled, allowedNow(kind) else { return }
        DispatchQueue.global(qos: .utility).async {
            let text = "⚠️ Автоотчёт: \(kind.rawValue)\n\(environmentLine())\n\n\(String(details.prefix(2800)))"
            send(text)
        }
    }

    private static func allowedNow(_ kind: Kind) -> Bool {
        let defaults = UserDefaults.standard
        var sent = (defaults.dictionary(forKey: sentKey) as? [String: Double]) ?? [:]
        let now = Date().timeIntervalSince1970
        sent = sent.filter { now - $0.value < 24 * 3600 }
        if let last = sent[kind.rawValue], now - last < 20 * 3600 { return false }
        if sent.count >= 6 { return false }
        sent[kind.rawValue] = now
        defaults.set(sent, forKey: sentKey)
        return true
    }

    private static func send(_ text: String) {
        guard let url = URL(string: "https://api.telegram.org/bot\(Secrets.telegramBotToken)/sendMessage") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "chat_id": Secrets.telegramChatID,
            "text": text,
        ])
        URLSession.shared.dataTask(with: request).resume()
    }

    private static var installID: String {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: idKey) { return id }
        let id = String(UUID().uuidString.prefix(6)).lowercased()
        defaults.set(id, forKey: idKey)
        return id
    }

    /// App + system versions on one line (runs yt-dlp --version, so call it
    /// off the main thread).
    private static func environmentLine() -> String {
        let app = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var ytDlp = "нет"
        if let bin = ToolLocator.bundledBinDirectory,
           let v = DownloadManager.captureOutput(bin + "/yt-dlp", ["--version"])?
               .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            ytDlp = v
        }
        let deno = ToolLocator.bundledBinDirectory.map {
            FileManager.default.isExecutableFile(atPath: $0 + "/deno") ? "есть" : "нет"
        } ?? "нет"
        return "Scorpena \(app) · macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)\n"
            + "yt-dlp \(ytDlp) · deno \(deno) · установка #\(installID)"
    }

    // MARK: Crashes

    /// Looks for a macOS crash report written since the last launch and
    /// sends a short summary of it (exception, fatal-error message, top frames).
    static func reportPreviousCrashIfAny() {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: crashCheckKey)
        defaults.set(Date().timeIntervalSince1970, forKey: crashCheckKey)
        guard last > 0, enabled else { return }

        DispatchQueue.global(qos: .utility).async {
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let candidates = files.compactMap { url -> (URL, Date)? in
                let name = url.lastPathComponent
                guard name.hasPrefix("VideoDownloader"), name.hasSuffix(".ips") || name.hasSuffix(".crash"),
                      let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      date.timeIntervalSince1970 > last
                else { return nil }
                return (url, date)
            }
            guard let newest = candidates.max(by: { $0.1 < $1.1 })?.0 else { return }
            report(.crash, details: crashSummary(at: newest) ?? "(отчёт о падении есть, но разобрать его не удалось)")
        }
    }

    /// Pulls the useful, non-personal parts out of a macOS `.ips` crash report.
    static func crashSummary(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let newline = text.firstIndex(of: "\n"),
              let object = try? JSONSerialization.jsonObject(
                with: Data(text[text.index(after: newline)...].utf8)) as? [String: Any]
        else { return nil }

        var lines: [String] = []
        if let exception = object["exception"] as? [String: Any] {
            let type = exception["type"] as? String ?? "?"
            let signal = exception["signal"] as? String ?? ""
            lines.append("Исключение: \(type) \(signal)".trimmingCharacters(in: .whitespaces))
        }
        if let termination = object["termination"] as? [String: Any] {
            let indicator = termination["indicator"] as? String ?? ""
            let namespace = termination["namespace"] as? String ?? ""
            lines.append("Завершение: \(namespace) \(indicator)".trimmingCharacters(in: .whitespaces))
        }
        if let asi = object["asi"] as? [String: Any] {
            let messages = asi.values.compactMap { $0 as? [String] }.flatMap { $0 }
            if let message = messages.first { lines.append("Сообщение: \(String(message.prefix(300)))") }
        }
        if let faulting = object["faultingThread"] as? Int,
           let threads = object["threads"] as? [[String: Any]], faulting < threads.count,
           let frames = threads[faulting]["frames"] as? [[String: Any]] {
            let images = (object["usedImages"] as? [[String: Any]]) ?? []
            lines.append("")
            lines.append("Стек (поток, где упало):")
            for frame in frames.prefix(10) {
                let symbol = frame["symbol"] as? String
                let imageName = (frame["imageIndex"] as? Int).flatMap { $0 < images.count ? images[$0]["name"] as? String : nil } ?? "?"
                let offset = frame["imageOffset"] as? Int ?? 0
                lines.append("  \(imageName) · \(symbol ?? "+\(offset)")")
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Bundled tools

    /// Runs each bundled tool once. If macOS blocks one or it's missing, the
    /// app can't download anything — exactly the thing worth knowing about.
    static func checkBundledTools() {
        guard enabled, let bin = ToolLocator.bundledBinDirectory else { return }
        DispatchQueue.global(qos: .utility).async {
            var problems: [String] = []
            for (name, argument) in [("yt-dlp", "--version"), ("ffmpeg", "-version"), ("deno", "--version")] {
                let path = bin + "/" + name
                guard FileManager.default.isExecutableFile(atPath: path) else {
                    problems.append("\(name): файла нет или нет права на запуск")
                    continue
                }
                switch runBriefly(path, [argument], timeout: 30) {
                case .none:                  problems.append("\(name): не удалось запустить")
                case .some(let r) where r.killedBySignal: problems.append("\(name): убит системой (сигнал \(r.status))")
                case .some(let r) where r.status != 0:    problems.append("\(name): код выхода \(r.status)")
                default: break
                }
            }
            if !problems.isEmpty { report(.toolBroken, details: problems.joined(separator: "\n")) }
        }
    }

    private struct RunResult { let status: Int32; let killedBySignal: Bool }

    private static func runBriefly(_ path: String, _ arguments: [String], timeout: TimeInterval) -> RunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [ToolLocator.bundledBinDirectory, "/usr/bin", "/bin"].compactMap { $0 }.joined(separator: ":")
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()
        return RunResult(status: process.terminationStatus, killedBySignal: process.terminationReason == .uncaughtSignal)
    }

    // MARK: Repeated download failures

    /// Called for failures that look like breakage rather than user error
    /// (login/bot wall, 403, format not found, unknown). Three in a row trigger
    /// one report with the sites involved — never the links themselves.
    static func noteDownloadFailure(category: String, host: String?, log: String) {
        let defaults = UserDefaults.standard
        var recent = (defaults.array(forKey: failuresKey) as? [[String: String]]) ?? []
        recent.append(["c": category, "h": host ?? "?", "e": lastErrorLine(in: log)])
        if recent.count >= 3 {
            defaults.removeObject(forKey: failuresKey)
            let lines = recent.enumerated().map { index, item in
                "\(index + 1). \(item["h"] ?? "?") — \(item["c"] ?? "?")\n   \(item["e"] ?? "")"
            }
            report(.repeatedFailures, details: "Три неудачи подряд:\n" + lines.joined(separator: "\n"))
        } else {
            defaults.set(recent, forKey: failuresKey)
        }
    }

    static func noteDownloadSuccess() {
        UserDefaults.standard.removeObject(forKey: failuresKey)
    }

    /// yt-dlp's last "ERROR:" line with the site/video-id prefix and any link removed.
    private static func lastErrorLine(in log: String) -> String {
        guard let line = log.split(separator: "\n").last(where: { $0.contains("ERROR:") }) else { return "" }
        var text = String(line)
        if let range = text.range(of: "ERROR:") { text = String(text[range.upperBound...]) }
        text = text.replacingOccurrences(of: #"https?://\S+"#, with: "<ссылка>", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^\s*\[[^\]]+\]\s*[^:\s]+:\s*"#, with: "", options: .regularExpression)
        return String(text.trimmingCharacters(in: .whitespaces).prefix(220))
    }
}
