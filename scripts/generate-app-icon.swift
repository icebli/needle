import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift OUTPUT_ICONSET\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fileManager = FileManager.default
try? fileManager.removeItem(at: outputURL)
try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func roundedRect(_ context: CGContext, _ rect: CGRect, radius: CGFloat) {
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

func drawIcon(in context: CGContext, size: CGFloat) {
    context.saveGState()
    context.scaleBy(x: size / 512, y: size / 512)
    context.translateBy(x: 0, y: 512)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    let background = NSColor(srgbRed: 21/255, green: 24/255, blue: 28/255, alpha: 1).cgColor
    let record = NSColor(srgbRed: 11/255, green: 13/255, blue: 16/255, alpha: 1).cgColor
    let groove = NSColor(srgbRed: 41/255, green: 46/255, blue: 52/255, alpha: 1).cgColor
    let amber = NSColor(srgbRed: 241/255, green: 184/255, blue: 75/255, alpha: 1).cgColor
    context.setFillColor(background)
    roundedRect(context, CGRect(x: 0, y: 0, width: 512, height: 512), radius: 112)
    context.fillPath()
    context.setFillColor(record)
    context.setStrokeColor(groove)
    context.setLineWidth(8)
    context.addEllipse(in: CGRect(x: 90, y: 108, width: 320, height: 320))
    context.drawPath(using: .fillStroke)
    context.setLineWidth(6)
    for radius: CGFloat in [126, 94, 62] {
        context.strokeEllipse(in: CGRect(x: 250-radius, y: 268-radius, width: radius*2, height: radius*2))
    }
    context.setFillColor(amber)
    context.fillEllipse(in: CGRect(x: 217, y: 235, width: 66, height: 66))
    context.setFillColor(background)
    context.fillEllipse(in: CGRect(x: 241, y: 259, width: 18, height: 18))
    context.setStrokeColor(amber)
    context.setLineWidth(22)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 103, y: 128))
    context.addLine(to: CGPoint(x: 150, y: 128))
    context.addCurve(to: CGPoint(x: 197, y: 175), control1: CGPoint(x: 176, y: 128), control2: CGPoint(x: 197, y: 149))
    context.addLine(to: CGPoint(x: 197, y: 190))
    context.addLine(to: CGPoint(x: 324, y: 317))
    context.strokePath()
    context.saveGState()
    context.translateBy(x: 304, y: 300)
    context.rotate(by: -.pi / 4)
    context.setFillColor(amber)
    roundedRect(context, CGRect(x: 0, y: 0, width: 64, height: 92), radius: 18)
    context.fillPath()
    context.restoreGState()
    context.setStrokeColor(background)
    context.setLineWidth(11)
    context.move(to: CGPoint(x: 345, y: 365))
    context.addLine(to: CGPoint(x: 376, y: 396))
    context.strokePath()
    context.restoreGState()
}

for item in sizes {
    let width = item.pixels
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: width,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ), let bitmapData = bitmap.bitmapData,
       let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let context = CGContext(
           data: bitmapData,
           width: width,
           height: width,
           bitsPerComponent: 8,
           bytesPerRow: width * 4,
           space: colorSpace,
           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
       ) else {
        throw NSError(domain: "NeedleIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap for \(item.name)"])
    }
    context.clear(CGRect(x: 0, y: 0, width: width, height: width))
    drawIcon(in: context, size: CGFloat(width))
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "NeedleIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode \(item.name)"])
    }
    try png.write(to: outputURL.appendingPathComponent(item.name), options: .atomic)
}
