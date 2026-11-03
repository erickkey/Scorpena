import Foundation

// A history file that cannot be read at all is put aside, never written over with an empty list.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { fails += 1 } }

let dir = AppSupport.folder.appendingPathComponent("History", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try! Data("this is not json".utf8).write(to: dir.appendingPathComponent("history.json"))

let history = DownloadHistory.shared
check(history.items.isEmpty, "nothing could be read")
let aside = try? String(contentsOf: dir.appendingPathComponent("history-broken.json"), encoding: .utf8)
check(aside == "this is not json", "the unreadable file is kept as history-broken.json")
print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
exit(fails == 0 ? 0 : 1)
