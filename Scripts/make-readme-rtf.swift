// Generates "Если не открывается.rtf" — instructions with a clickable link
// that opens System Settings → Privacy & Security directly.
// Usage: swift Scripts/make-readme-rtf.swift <output.rtf>

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Если не открывается.rtf"

let bodyFont = NSFont.systemFont(ofSize: 14)
let boldFont = NSFont.boldSystemFont(ofSize: 15)
let linkFont = NSFont.boldSystemFont(ofSize: 14)

let text = NSMutableAttributedString()

func para(_ s: String, font: NSFont = bodyFont, spacingAfter: CGFloat = 10, color: NSColor = .textColor) {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = spacingAfter
    style.lineSpacing = 2
    text.append(NSAttributedString(string: s + "\n", attributes: [
        .font: font, .foregroundColor: color, .paragraphStyle: style,
    ]))
}

func link(_ label: String, url: String, spacingAfter: CGFloat = 4) {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = spacingAfter
    let attrs: [NSAttributedString.Key: Any] = [
        .font: linkFont,
        .link: url,
        .paragraphStyle: style,
    ]
    text.append(NSAttributedString(string: label, attributes: attrs))
    text.append(NSAttributedString(string: "\n"))
}

para("Scorpena – video downloader: если не открывается", font: boldFont, spacingAfter: 14)

para("macOS иногда блокирует программы без платной подписи Apple (у нас её нет). Обычно хватает одного из шагов:", spacingAfter: 14)

para("1. Правый клик по Scorpena.app → «Открыть» → в появившемся окне снова нажать «Открыть».", spacingAfter: 14)

para("2. Если всё ещё не открывается — нажми на кнопку ниже, прокрути вниз в открывшемся окне настроек, найди строку про заблокированный Scorpena и нажми «Открыть в любом случае».", spacingAfter: 8)

link("→ Открыть настройки", url: "x-apple.systempreferences:com.apple.preference.security", spacingAfter: 16)

para("После этого программа открывается как обычно. Ставить больше ничего не нужно — всё нужное уже внутри.")

let docAttrs: [NSAttributedString.DocumentAttributeKey: Any] = [
    .documentType: NSAttributedString.DocumentType.rtf
]
guard let data = try? text.data(
    from: NSRange(location: 0, length: text.length),
    documentAttributes: docAttrs
) else { fatalError("rtf encode failed") }

try! data.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
