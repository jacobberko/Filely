import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("Usage: make-icon.swift <output.iconset> <output.icns>\n".utf8))
    exit(64)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconDestination = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func makeIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "FilelyIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create the icon canvas."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    defer { NSGraphicsContext.restoreGraphicsState() }
    graphics.imageInterpolation = .high
    let transform = AffineTransform(scale: Double(pixels) / 1024)
    let drawingTransform = NSAffineTransform(transform: transform)
    drawingTransform.concat()

    let plateRect = NSRect(x: 88, y: 90, width: 848, height: 848)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 190, yRadius: 190)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.23)
    shadow.shadowOffset = NSSize(width: 0, height: -13)
    shadow.shadowBlurRadius = 26
    shadow.set()
    NSColor(calibratedRed: 0.10, green: 0.44, blue: 0.55, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.restoreGraphicsState()

    let ocean = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.72, alpha: 1), 0),
        (NSColor(calibratedRed: 0.04, green: 0.64, blue: 0.67, alpha: 1), 0.52),
        (NSColor(calibratedRed: 0.27, green: 0.83, blue: 0.73, alpha: 1), 1))!
    ocean.draw(in: plate, angle: 70)

    NSGraphicsContext.saveGraphicsState()
    plate.addClip()
    let glow = NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0))!
    glow.draw(fromCenter: NSPoint(x: 280, y: 900), radius: 0,
              toCenter: NSPoint(x: 280, y: 900), radius: 720, options: [])
    let lowerGlow = NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.65, alpha: 0.32),
                               ending: NSColor.clear)!
    lowerGlow.draw(fromCenter: NSPoint(x: 760, y: 90), radius: 0,
                   toCenter: NSPoint(x: 760, y: 90), radius: 760, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 2, dy: 2), xRadius: 188, yRadius: 188)
    rim.lineWidth = 3
    NSColor.white.withAlphaComponent(0.36).setStroke()
    rim.stroke()

    let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 530, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Filely")?
        .withSymbolConfiguration(symbolConfiguration) else {
        throw NSError(domain: "FilelyIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "The paperclip system symbol is unavailable."])
    }
    let available = NSRect(x: 255, y: 245, width: 514, height: 540)
    let ratio = min(available.width / symbol.size.width, available.height / symbol.size.height)
    let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
    let symbolRect = NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                            width: size.width, height: size.height)
    NSGraphicsContext.saveGraphicsState()
    let symbolShadow = NSShadow()
    symbolShadow.shadowColor = NSColor(calibratedRed: 0, green: 0.21, blue: 0.34, alpha: 0.27)
    symbolShadow.shadowOffset = NSSize(width: 0, height: -8)
    symbolShadow.shadowBlurRadius = 15
    symbolShadow.set()
    symbol.draw(in: symbolRect)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FilelyIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot encode the icon PNG."])
    }
    return png
}

var images: [Int: Data] = [:]
for (filename, pixels) in variants {
    let png = try images[pixels] ?? makeIcon(pixels: pixels)
    images[pixels] = png
    try png.write(to: destination.appendingPathComponent(filename), options: .atomic)
}

// ICNS supports PNG payloads directly. Encode the documented representation sizes as a fallback
// for iconutil versions that reject otherwise valid iconsets in a restricted build environment.
func bigEndianBytes(_ value: Int) -> Data {
    var integer = UInt32(value).bigEndian
    return withUnsafeBytes(of: &integer) { Data($0) }
}
let representations: [(String, Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
    ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)
]
var body = Data()
for (type, pixels) in representations {
    let png = images[pixels]!
    body.append(Data(type.utf8))
    body.append(bigEndianBytes(png.count + 8))
    body.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndianBytes(body.count + 8))
icon.append(body)
try icon.write(to: iconDestination, options: .atomic)
guard let loaded = NSImage(contentsOf: iconDestination), loaded.isValid,
      loaded.representations.contains(where: { $0.pixelsWide == 1024 && $0.pixelsHigh == 1024 }) else {
    throw NSError(domain: "FilelyIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "The generated ICNS could not be loaded by macOS."])
}
print("Created and verified \(iconDestination.path)")
