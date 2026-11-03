import Foundation

// The tests never touch the real queue, history and caches: Scripts/test.sh gives each its own folder.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }
// The texts are checked in Russian whatever the language of the computer that runs the tests.
LanguageSettings.shared.language = .ru

// The 24-hour memories: what was found out about a link, and the prepared viewing copy.
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { fails += 1 } }

let link = "https://test.invalid/watch?v=cache-test-" + UUID().uuidString
check(ProbeCache.lookup(link) == nil, "probe cache: nothing yet")
ProbeCache.store(link, title: "Тест", heights: [1080, 720], sizes: [1080: 5_000_000, 720: 2_000_000], duration: 61)
let hit = ProbeCache.lookup("  " + link.uppercased() + " ")
check(hit?.title == "Тест" && hit?.heights == [1080, 720] && hit?.duration == 61, "probe cache: answers the same link (any case, with spaces)")

let copy = FileManager.default.temporaryDirectory.appendingPathComponent("cache-test-\(UUID().uuidString).mp4")
try! Data("not a real video".utf8).write(to: copy)
check(PreviewCache.lookup(link) == nil, "preview cache: nothing yet")
let stored = PreviewCache.store(file: copy, link: link, title: "Тест")
check(stored != nil && FileManager.default.fileExists(atPath: stored!.path), "preview cache: the copy is moved in")
check(PreviewCache.lookup(link)?.title == "Тест", "preview cache: found again")
if let stored { try? FileManager.default.removeItem(at: stored) }
print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
exit(fails == 0 ? 0 : 1)
