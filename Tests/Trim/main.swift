import Foundation

// The tests never touch the real queue, history and caches: Scripts/test.sh gives each its own folder.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }
// The texts are checked in Russian whatever the language of the computer that runs the tests.
LanguageSettings.shared.language = .ru
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { fails += 1 } }
let model = TrimModel(manager: DownloadManager())
check(!model.sectionIsValid, "no link: nothing can be cut")
LinkField.clip.text = "https://www.youtube.com/watch?v=jNQXAC9IVRw"
check(!model.sectionIsValid, "link but no times yet: not valid")
model.startText = "1:07"; model.startTextEdited()
model.endText = "3:00"; model.endTextEdited()
check(model.sectionIsValid, "times typed at once, no preview: valid")
check(Int(model.section.start) == 67 && Int(model.section.end) == 180, "section is 1:07–3:00 (\(model.section.start)–\(model.section.end))")
check(!model.previewReady, "the preview is not ready, and the clip can still be downloaded")
model.endText = "1:00"; model.endTextEdited()
check(!model.sectionIsValid, "end before start: not valid")
model.endText = "1:07.1"; model.endTextEdited()
check(!model.sectionIsValid, "a gap under 0.2 s: not valid")
model.endText = "garbage"; model.endTextEdited()
check(!model.sectionIsValid, "unreadable end keeps the old (invalid) value")
LinkField.clip.text = "не ссылка"
model.endText = "3:00"; model.endTextEdited()
check(!model.sectionIsValid, "not a link: not valid")
model.nudge(by: 1)   // must not crash without a player
check(true, "arrow keys without a preview do nothing")
print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
