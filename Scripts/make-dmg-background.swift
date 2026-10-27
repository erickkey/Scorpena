// Generates the disk-image background: swift make-dmg-background.swift <out.png>
// Exactly 640×480, in the look of the app: near-black canvas, one big soft rounded
// "stage" card, the brand on top, a rounded slot behind each of the two icons
// (app on the left, Applications on the right), a dotted arrow between them and
// a help card underneath with the "Открыть настройки" shortcut.
// Icon centres (package.sh puts them there, y from the top):
//   app (150, 190) · Applications (490, 190) · settings shortcut (112, 372)

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let W = 640, H = 480

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func white(_ alpha: CGFloat) -> CGColor { NSColor(calibratedWhite: 1, alpha: alpha).cgColor }
/// Rectangle given from the TOP edge, like Finder positions.
func rect(x: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
    CGRect(x: x, y: CGFloat(H) - top - h, width: w, height: h)
}
func rounded(_ r: CGRect, _ radius: CGFloat, fill: CGColor, stroke: CGColor? = nil) {
    let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
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

/// Text with its top edge `top` points from the top of the window.
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat,
          x: CGFloat = 20, width: CGFloat? = nil, align: NSTextAlignment = .center, kern: CGFloat = 0, lines: CGFloat = 1) {
    let p = NSMutableParagraphStyle(); p.alignment = align
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: alpha),
        .paragraphStyle: p,
        .kern: kern,
    ]
    let height = (size + 5) * lines
    (s as NSString).draw(in: rect(x: x, top: top, w: width ?? CGFloat(W) - 2 * x, h: height), withAttributes: attrs)
}

// canvas + stage card
ctx.setFillColor(NSColor(calibratedRed: 0.063, green: 0.063, blue: 0.071, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
rounded(rect(x: 14, top: 14, w: CGFloat(W) - 28, h: CGFloat(H) - 28), 24,
        fill: NSColor(calibratedRed: 0.102, green: 0.102, blue: 0.114, alpha: 1).cgColor,
        stroke: white(0.08))

// brand
text("SCORPENA", size: 24, weight: .bold, alpha: 0.97, top: 30, kern: 2)
text("video downloader", size: 13, weight: .regular, alpha: 0.5, top: 62)
text("by Yaroslav Lukyanov", size: 10, weight: .regular, alpha: 0.28, top: 82)

// a rounded slot behind each icon
let rowY: CGFloat = 190
for x in [CGFloat(150), CGFloat(490)] {
    rounded(rect(x: x - 80, top: rowY - 80, w: 160, h: 160), 26, fill: white(0.055), stroke: white(0.09))
}

// Finder draws the file names itself — black on a light-mode Mac, white on a
// dark-mode one — so a mid-grey pill under each name keeps both readable.
func plate(centreX: CGFloat, topCentre: CGFloat, width: CGFloat) {
    rounded(rect(x: centreX - width / 2, top: topCentre - 11, w: width, h: 22), 11,
            fill: NSColor(calibratedWhite: 0.56, alpha: 1).cgColor)
}
plate(centreX: 150, topCentre: rowY + 62, width: 112)
plate(centreX: 490, topCentre: rowY + 62, width: 112)

// dotted arrow: "drag this onto that"
let arrowY = CGFloat(H) - rowY
ctx.setStrokeColor(white(0.5))
ctx.setLineWidth(3)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineDash(phase: 0, lengths: [0.1, 9])
ctx.move(to: CGPoint(x: 262, y: arrowY))
ctx.addLine(to: CGPoint(x: 352, y: arrowY))
ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])
ctx.setStrokeColor(white(0.75))
ctx.setLineWidth(3.5)
ctx.move(to: CGPoint(x: 356, y: arrowY + 15))
ctx.addLine(to: CGPoint(x: 374, y: arrowY))
ctx.addLine(to: CGPoint(x: 356, y: arrowY - 15))
ctx.strokePath()

// install hint
text("Перетащи Scorpena в «Программы»", size: 15, weight: .semibold, alpha: 0.96, top: 284, x: 40, width: CGFloat(W) - 80)

// help card: the shortcut icon sits on the left, the explanation on the right
rounded(rect(x: 30, top: 326, w: CGFloat(W) - 60, h: 128), 20, fill: white(0.045), stroke: white(0.08))
plate(centreX: 112, topCentre: 433, width: 128)
text("Не открывается?", size: 14, weight: .semibold, alpha: 0.95, top: 346, x: 188, width: 412, align: .left)
text("Дважды нажми на значок слева, откроются настройки. Найди там Scorpena и нажми «Всё равно открыть».",
     size: 11.5, weight: .regular, alpha: 0.62, top: 370, x: 188, width: 400, align: .left, lines: 2)
text("Или: правый клик по Scorpena → «Открыть».", size: 11, weight: .regular, alpha: 0.42, top: 418, x: 188, width: 412, align: .left)

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
