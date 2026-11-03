import Foundation

// The tests never touch the real queue, history and caches: Scripts/test.sh gives each its own folder.
if AppSupport.isReal { print("FAIL  run the tests with Scripts/test.sh (they need their own data folder)"); exit(1) }

// Every language answers, placeholders survive, a shown text can be put into another language.
var fails = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "ok   " : "FAIL ", what); if !ok { fails += 1 } }

for language in AppLanguage.allCases {
    LanguageSettings.shared.language = language
    check(tr("Закрыть") != "" && trf("Новая версия %@ не прошла проверку, оставил %@.", "3.2", "3.1").contains("3.2"),
          "\(language.rawValue): translated text keeps its placeholders")
}
LanguageSettings.shared.language = .zh
let shown = tr("Ошибка")
LanguageSettings.shared.language = .es
check(retranslated(shown) == "Error", "a text on screen goes from Chinese to Spanish")
LanguageSettings.shared.language = .ru
check(retranslated("Готово ✅ · 4 с · 636 КБ") == nil, "a text with numbers is left alone")
check(ContentView.progressAmounts(done: 10_000_000, total: 558_000_000) == "10 из 558 МБ", "10 из 558 МБ in Russian")
LanguageSettings.shared.language = .es
check(ContentView.formatBytes(1_500_000) == "1,5 МБ".replacingOccurrences(of: "МБ", with: "MB"), "Spanish: decimal comma, MB")
for (language, voice) in [(AppLanguage.ru, ""), (.en, "EN"), (.zh, "CN"), (.hi, "HI"), (.es, "ES")] {
    check(language.voiceSuffix == voice, "\(language.rawValue): voice file suffix «\(voice)»")
}
print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
exit(fails == 0 ? 0 : 1)
