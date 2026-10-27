// Draws the icon of the "Открыть настройки" shortcut that sits in the DMG:
// swift make-settings-icon.swift <out.png>
// A black rounded square with a white gear — the same family as the app icon.

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "settings-icon.png"
let S = 1024

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// rounded square (the usual 824-pt body inside a 1024 canvas)
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.setFillColor(NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 1).cgColor)
ctx.addPath(path)
ctx.fillPath()
ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor)
ctx.setLineWidth(6)
ctx.addPath(path)
ctx.strokePath()

// white gear
let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .regular)
guard let symbol = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) else { fatalError("no symbol") }
let size = symbol.size
let tinted = NSImage(size: size)
tinted.lockFocus()
symbol.draw(in: NSRect(origin: .zero, size: size))
NSColor.white.set()
NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
tinted.unlockFocus()
tinted.draw(in: NSRect(x: (CGFloat(S) - size.width) / 2, y: (CGFloat(S) - size.height) / 2,
                       width: size.width, height: size.height))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("encode failed") }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
