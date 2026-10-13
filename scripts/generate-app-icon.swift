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
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    context.setFillColor(NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.16, alpha: 1).cgColor)
    roundedRect(context, canvas.insetBy(dx: 24, dy: 24), radius: 214)
    context.fillPath()

    // A dark record and its warm center make the mark legible at small sizes.
    let record = CGRect(x: 178, y: 170, width: 668, height: 668)
    context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).cgColor)
    context.fillEllipse(in: record)
    context.setFillColor(NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.48, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 470, y: 462, width: 84, height: 84))
    context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: 503, y: 495, width: 18, height: 18))

    // Needle arm and cartridge cut through the record as a single strong diagonal.
    context.setStrokeColor(NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.48, alpha: 1).cgColor)
    context.setLineWidth(48)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: 322, y: 716))
    context.addLine(to: CGPoint(x: 704, y: 334))
    context.strokePath()
    context.setFillColor(NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.48, alpha: 1).cgColor)
    roundedRect(context, CGRect(x: 656, y: 266, width: 132, height: 144), radius: 30)
    context.fillPath()
    context.setFillColor(NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.14, alpha: 1).cgColor)
    context.move(to: CGPoint(x: 705, y: 285))
    context.addLine(to: CGPoint(x: 782, y: 362))
    context.addLine(to: CGPoint(x: 760, y: 384))
    context.addLine(to: CGPoint(x: 683, y: 307))
    context.closePath()
    context.fillPath()

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
