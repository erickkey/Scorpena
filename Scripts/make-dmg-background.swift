// Generates the disk-image background: swift make-dmg-background.swift <out.png>
// Exactly 640×400, in the look of the app: near-black canvas, one big soft rounded
// "stage" card, the brand on top, a rounded slot behind each of the two icons
// (app on the left, Applications on the right) and a dotted arrow between them.
// Icon centres are at x = 150 / 490, y = 185 from the top (package.sh puts them there).

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

func white(_ alpha: CGFloat) -> CGColor { NSColor(calibratedWhite: 1, alpha: alpha).cgColor }
func rounded(_ rect: CGRect, _ radius: CGFloat, fill: CGColor, stroke: CGColor? = nil) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.setFillColor(fill)
    ctx.addPath(path)
    ctx.fillPath()
    if let stroke {
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(1)
        ctx.addPath(path)
        ctx.strokePath()
    }
}

// canvas
ctx.setFillColor(NSColor(calibratedRed: 0.063, green: 0.063, blue: 0.071, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

// the stage card
rounded(CGRect(x: 14, y: 14, width: CGFloat(W) - 28, height: CGFloat(H) - 28), 24,
        fill: NSColor(calibratedRed: 0.102, green: 0.102, blue: 0.114, alpha: 1).cgColor,
        stroke: white(0.08))

// brand (top)
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, kern: CGFloat = 0, x: CGFloat = 20, width: CGFloat? = nil) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
        .paragraphStyle: p,
        .kern: kern,
    ]
    (s as NSString).draw(in: CGRect(x: x, y: y, width: width ?? CGFloat(W) - 2 * x, height: size + 8),
                         withAttributes: attrs)
}
text("SCORPENA", size: 24, weight: .bold, alpha: 0.97, y: CGFloat(H) - 66, kern: 2)
text("video downloader", size: 13, weight: .regular, alpha: 0.5, y: CGFloat(H) - 88)

// a rounded slot behind each icon
let iconY = CGFloat(H - 185)
for x in [CGFloat(150), CGFloat(490)] {
    rounded(CGRect(x: x - 80, y: iconY - 84, width: 160, height: 160), 26,
            fill: white(0.055), stroke: white(0.09))
}

// Finder draws the file names itself — black on a light-mode Mac, white on a
// dark-mode one — so a mid-grey pill under each name keeps both readable.
func plate(centreX: CGFloat, centreY: CGFloat, width: CGFloat) {
    rounded(CGRect(x: centreX - width / 2, y: centreY - 11, width: width, height: 22), 11,
            fill: NSColor(calibratedWhite: 0.56, alpha: 1).cgColor)
}
plate(centreX: 150, centreY: iconY - 62, width: 112)
plate(centreX: 490, centreY: iconY - 62, width: 112)

// dotted arrow: "drag this onto that"
ctx.setStrokeColor(white(0.5))
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineDash(phase: 0, lengths: [0.1, 9])
ctx.move(to: CGPoint(x: 262, y: iconY))
ctx.addLine(to: CGPoint(x: 352, y: iconY))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.setStrokeColor(white(0.75))
ctx.setLineWidth(3.5)
ctx.move(to: CGPoint(x: 356, y: iconY + 15))
ctx.addLine(to: CGPoint(x: 374, y: iconY))
ctx.addLine(to: CGPoint(x: 356, y: iconY - 15))
ctx.strokePath()

// install hint + help (bottom, centred)
text("Перетащи Scorpena в «Программы»", size: 15, weight: .semibold, alpha: 0.96, y: 88, x: 40, width: CGFloat(W) - 80)
text("Не открывается? Правый клик по значку → «Открыть»", size: 11, weight: .medium, alpha: 0.58, y: 62, x: 40, width: CGFloat(W) - 80)
text("Если не помогло: Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»", size: 10, weight: .regular, alpha: 0.4, y: 44, x: 40, width: CGFloat(W) - 80)
text("by Yaroslav Lukyanov", size: 10, weight: .regular, alpha: 0.26, y: 24, x: 40, width: CGFloat(W) - 80)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
