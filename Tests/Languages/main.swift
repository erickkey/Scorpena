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

// the message for a link that is not a video: translated everywhere, and an error already on screen follows a language change
let notVideoRu = "Здесь нет видео или аудио. Нужна другая ссылка."
var notVideoShown: [String: String] = [:]
for language in AppLanguage.allCases {
    LanguageSettings.shared.language = language
    notVideoShown[language.rawValue] = tr(notVideoRu)
    check(language == .ru || tr(notVideoRu) != notVideoRu, "\(language.rawValue): «not a video» message is translated")
}
LanguageSettings.shared.language = .es
check(retranslated(notVideoShown["en"]!) == notVideoShown["es"], "«not a video» message on screen goes from English to Spanish")
LanguageSettings.shared.language = .zh
check(retranslated(notVideoShown["hi"]!) == notVideoShown["zh"], "«not a video» message on screen goes from Hindi to Chinese")
LanguageSettings.shared.language = .ru
check(retranslated(notVideoShown["es"]!) == notVideoRu, "«not a video» message on screen goes from Spanish back to Russian")

print(fails == 0 ? "ALL OK" : "FAILURES: \(fails)")
// the message for a video closed in the viewer's country: translated everywhere, follows a language change on screen
let geoRu = "Это видео недоступно в твоей стране. Включи VPN или поменяй в нём страну и попробуй ещё раз."
var geoShown: [String: String] = [:]
for language in AppLanguage.allCases {
    LanguageSettings.shared.language = language
    geoShown[language.rawValue] = tr(geoRu)
    check(language == .ru || tr(geoRu) != geoRu, "\(language.rawValue): «geo block» message is translated")
}
for from in AppLanguage.allCases {
    for to in AppLanguage.allCases where from != to {
        LanguageSettings.shared.language = to
        check(retranslated(geoShown[from.rawValue]!) == geoShown[to.rawValue], "«geo block» on screen: \(from.rawValue) → \(to.rawValue)")
    }
}

exit(fails == 0 ? 0 : 1)
