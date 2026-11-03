import Foundation
import CryptoKit

/// What was found out about a link a short while ago (its title, qualities, sizes and length), kept for
/// a day in a small file — like the history. Pasting the same link again in any window does not
/// ask the site again.
enum ProbeCache {
    struct Entry: Codable {
        var title: String
        var heights: [Int]
        var sizes: [String: Int64]      // height → bytes
        var duration: Double?
        var date: Date
    }

    static let lifetime: TimeInterval = 24 * 3600
    static let limit = 100

    private static let file: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("VideoDownloader/probe-cache.json")
    }()

    private static var entries: [String: Entry] = {
        guard let data = try? Data(contentsOf: file),
              let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return loaded
    }()

    private static func key(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Main thread only.
    static func lookup(_ url: String) -> Entry? {
        guard let entry = entries[key(url)] else { return nil }
        guard Date().timeIntervalSince(entry.date) < lifetime else {
            entries[key(url)] = nil
            return nil
        }
        return entry
    }

    /// Main thread only.
    static func store(_ url: String, title: String, heights: [Int], sizes: [Int: Int64], duration: Double?) {
        entries[key(url)] = Entry(title: title, heights: heights,
                                  sizes: Dictionary(uniqueKeysWithValues: sizes.map { (String($0.key), $0.value) }),
                                  duration: duration, date: Date())
        // Old and surplus entries go.
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.date) < lifetime }
        if entries.count > limit {
            let keep = entries.sorted { $0.value.date > $1.value.date }.prefix(limit)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

/// The light copy that the clip window plays, kept for a day: opening the same link again (or going back
/// to it after a typo) shows the video at once instead of preparing it all over.
enum PreviewCache {
    private struct Meta: Codable {
        var file: String
        var title: String?
        var date: Date
    }

    static let lifetime: TimeInterval = 24 * 3600
    static let limit = 8

    private static var dir: URL {
        let dir = DownloadManager.partialDir.appendingPathComponent("preview-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func key(_ link: String) -> String {
        let digest = SHA256.hash(data: Data(link.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func lookup(_ link: String) -> (file: URL, title: String?)? {
        let metaURL = dir.appendingPathComponent(key(link) + ".json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              Date().timeIntervalSince(meta.date) < lifetime else { return nil }
        let file = dir.appendingPathComponent(meta.file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return (file, meta.title)
    }

    /// Moves the prepared copy into the cache; returns where it is now (nil if that did not work).
    static func store(file: URL, link: String, title: String?) -> URL? {
        let name = key(link) + "." + (file.pathExtension.isEmpty ? "mp4" : file.pathExtension)
        let target = dir.appendingPathComponent(name)
        let fm = FileManager.default
        try? fm.removeItem(at: target)
        do { try fm.moveItem(at: file, to: target) } catch {
            do { try fm.copyItem(at: file, to: target) } catch { return nil }
        }
        let meta = Meta(file: name, title: title, date: Date())
        if let data = try? JSONEncoder().encode(meta) {
            try? data.write(to: dir.appendingPathComponent(key(link) + ".json"), options: .atomic)
        }
        prune()
        return target
    }

    /// Old copies, and all but the newest few, are deleted.
    private static func prune() {
        let fm = FileManager.default
        let metas: [(url: URL, meta: Meta)] = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url), let meta = try? JSONDecoder().decode(Meta.self, from: data) else { return nil }
                return (url, meta)
            }
            .sorted { $0.meta.date > $1.meta.date }
        for (index, item) in metas.enumerated()
        where index >= limit || Date().timeIntervalSince(item.meta.date) >= lifetime {
            try? fm.removeItem(at: dir.appendingPathComponent(item.meta.file))
            try? fm.removeItem(at: item.url)
        }
    }
}
