import AppKit

/// On the very first launch, quietly looks at which installed browsers are
/// already signed in to the big sites, so the first download that needs a
/// login goes straight to the right browser instead of trying them one by one.
/// It only looks at cookie *names* and domains, which are stored in the
/// clear — nothing is decrypted, so macOS never asks for a password.
enum CookiePreflight {
    static let doneKey = "cookiePreflightDone"
    static let orderKey = "cookiePreflightOrder"

    /// A cookie that exists only while someone is signed in to the site.
    private static let loginCookies: [(host: String, names: [String])] = [
        ("youtube.com", ["SAPISID", "LOGIN_INFO", "__Secure-3PSID"]),
        ("instagram.com", ["sessionid"]),
        ("vimeo.com", ["vimeo"]),
    ]

    private static var started = false

    static func runOnceInBackground() {
        guard !started, !UserDefaults.standard.bool(forKey: doneKey) else { return }
        started = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
            let defaultBrowser = defaultBrowserName()
            var scored: [(browser: String, score: Int)] = []
            for browser in DownloadManager.installedCookieBrowsers() {
                let score = signedInSites(in: browser)
                if score > 0 { scored.append((browser, score)) }
            }
            // Most sites first; the system's default browser wins a tie.
            scored.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.browser == defaultBrowser && b.browser != defaultBrowser
            }
            let order = scored.map(\.browser)
            DispatchQueue.main.async {
                UserDefaults.standard.set(order, forKey: orderKey)
                UserDefaults.standard.set(true, forKey: doneKey)
            }
        }
    }

    /// Browsers that had a login, best first (empty before the check has run).
    static var rankedBrowsers: [String] {
        UserDefaults.standard.stringArray(forKey: orderKey) ?? []
    }

    private static func defaultBrowserName() -> String? {
        guard let url = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let id = Bundle(url: app)?.bundleIdentifier else { return nil }
        switch id {
        case "com.apple.Safari": return "safari"
        case "com.google.Chrome": return "chrome"
        case "org.mozilla.firefox": return "firefox"
        case "ru.yandex.desktop.yandex-browser": return "yandex"
        default: return nil
        }
    }

    /// How many of the known sites this browser is signed in to.
    private static func signedInSites(in browser: String) -> Int {
        let home = NSHomeDirectory()
        switch browser {
        case "safari":
            let paths = ["\(home)/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
                         "\(home)/Library/Cookies/Cookies.binarycookies"]
            for path in paths {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
                return loginCookies.filter { site in
                    data.range(of: Data(site.host.utf8)) != nil
                        && site.names.contains { data.range(of: Data($0.utf8)) != nil }
                }.count
            }
            return 0   // unreadable (no Full Disk Access) or not used
        case "firefox":
            return databases(under: "\(home)/Library/Application Support/Firefox/Profiles", file: "cookies.sqlite")
                .map { count(in: $0, table: "moz_cookies", hostColumn: "host") }.max() ?? 0
        case "chrome":
            return chromiumDatabases(under: "\(home)/Library/Application Support/Google/Chrome")
                .map { count(in: $0, table: "cookies", hostColumn: "host_key") }.max() ?? 0
        case "yandex":
            return chromiumDatabases(under: "\(home)/Library/Application Support/Yandex/YandexBrowser")
                .map { count(in: $0, table: "cookies", hostColumn: "host_key") }.max() ?? 0
        default:
            return 0
        }
    }

    /// `<root>/<profile>/<file>` for every profile folder.
    private static func databases(under root: String, file: String) -> [URL] {
        let fm = FileManager.default
        guard let profiles = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return profiles.map { URL(fileURLWithPath: root).appendingPathComponent($0).appendingPathComponent(file) }
            .filter { fm.isReadableFile(atPath: $0.path) }
    }

    private static func chromiumDatabases(under root: String) -> [URL] {
        databases(under: root, file: "Network/Cookies") + databases(under: root, file: "Cookies")
    }

    /// Works on a copy, because the browser keeps its own file locked while it runs.
    private static func count(in database: URL, table: String, hostColumn: String) -> Int {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("scorpena-cookies-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let copy = dir.appendingPathComponent("db")
            try fm.copyItem(at: database, to: copy)
            let wal = URL(fileURLWithPath: database.path + "-wal")
            if fm.fileExists(atPath: wal.path) { try? fm.copyItem(at: wal, to: URL(fileURLWithPath: copy.path + "-wal")) }

            return loginCookies.filter { site in
                let names = site.names.map { "'\($0)'" }.joined(separator: ",")
                let sql = "select count(*) from \(table) where \(hostColumn) like '%\(site.host)' and name in (\(names));"
                return (Int(runSQLite(copy.path, sql) ?? "") ?? 0) > 0
            }.count
        } catch {
            return 0
        }
    }

    private static func runSQLite(_ path: String, _ sql: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", path, sql]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
