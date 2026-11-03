import Foundation

// One entry of the history that cannot be read must not wipe the others.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { fails += 1 } }

let dir = AppSupport.folder.appendingPathComponent("History", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
let good = try! encoder.encode(HistoryItem(url: "https://example.com/a", title: "Good", thumbnailFile: nil, audioOnly: false, date: Date()))
let file = "[" + String(decoding: good, as: UTF8.self) + ", {\"nonsense\": 1}]"
try! Data(file.utf8).write(to: dir.appendingPathComponent("history.json"))

let history = DownloadHistory.shared      // reads the file now
check(history.items.count == 1 && history.items[0].title == "Good", "the readable entry is kept (got \(history.items.count))")
check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history-before-repair.json").path), "the file as it was is kept beside")
let saved = try! String(contentsOf: dir.appendingPathComponent("history.json"), encoding: .utf8)
check(saved.contains("Good"), "the history file still holds the good entry")
print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
exit(fails == 0 ? 0 : 1)
