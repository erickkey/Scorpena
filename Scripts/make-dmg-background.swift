// Generates the disk-image background: swift make-dmg-background.swift <out.png>
// Exactly 640×400, light, with a right-pointing arrow between the two icons.

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let W = 640, H = 400

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// background — dark, close to black
ctx.setFillColor(NSColor(calibratedWhite: 0.15, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// arrow (points right), one filled path so the semi-transparent fill never
// overlaps itself. Vertically centred on the icon row (Finder y = 185).
let cx = CGFloat(W) / 2
let cy = CGFloat(H - 185)
let arrow = CGMutablePath()
arrow.addRect(CGRect(x: cx - 36, y: cy - 13, width: 44, height: 26))   // shaft
arrow.move(to: CGPoint(x: cx + 2,  y: cy - 34))                        // head
arrow.addLine(to: CGPoint(x: cx + 2,  y: cy + 34))
arrow.addLine(to: CGPoint(x: cx + 40, y: cy))
arrow.closeSubpath()
ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.55).cgColor)
ctx.addPath(arrow)
ctx.fillPath()   // one fill of the union → uniform opacity, no seam

// text
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
        .paragraphStyle: p,
    ]
    (s as NSString).draw(in: CGRect(x: 20, y: y, width: CGFloat(W) - 40, height: size + 8),
                         withAttributes: attrs)
}

// title (top)
text("Добро пожаловать!", size: 17, weight: .semibold, alpha: 0.97, y: CGFloat(H) - 52)
text("Рад облегчить твою жизнь", size: 12, weight: .regular, alpha: 0.55, y: CGFloat(H) - 74)

// install hint + first-launch tip + credit (bottom)
text("Перетащите Scorpena в «Программы»", size: 13, weight: .medium, alpha: 0.95, y: 68)
text("Первый запуск: правый клик по значку → «Открыть»", size: 11, weight: .medium, alpha: 0.65, y: 48)
text("Drag Scorpena to the Applications folder", size: 11, weight: .regular, alpha: 0.38, y: 28)
text("by Yaroslav Lukyanov", size: 10, weight: .regular, alpha: 0.30, y: 8)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
