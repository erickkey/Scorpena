// pad-icon.swift  <source.png>  <output-1024.png>
// Scales the source into a 1024 canvas with transparent margins so it sits
// right in the macOS Dock.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let src = CommandLine.arguments[1]
let out = CommandLine.arguments[2]

guard let srcImg = NSImage(contentsOfFile: src),
      let tiff = srcImg.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cgSrc = rep.cgImage
else { fatalError("cannot read source") }

let S = 1024
let inset: CGFloat = 76               // transparent margin on each side
let box = CGFloat(S) - inset * 2
// Keep the picture's own proportions (it isn't exactly square) and centre it.
let scale = min(box / CGFloat(cgSrc.width), box / CGFloat(cgSrc.height))
let drawW = CGFloat(cgSrc.width) * scale
let drawH = CGFloat(cgSrc.height) * scale
let target = CGRect(x: (CGFloat(S) - drawW) / 2, y: (CGFloat(S) - drawH) / 2, width: drawW, height: drawH)

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: S, height: S,
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("no context") }

ctx.interpolationQuality = .high
ctx.draw(cgSrc, in: target)

guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("no destination") }
CGImageDestinationAddImage(dest, img, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write failed") }
print("wrote \(out)")
