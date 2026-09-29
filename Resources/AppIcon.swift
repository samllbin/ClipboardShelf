import AppKit

// Build-time only: draw a native icon without external assets or dependencies.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift AppIcon.swift <output.iconset>")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func render(pixels: Int, filename: String) throws {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(pixels) / 1024)
    transform.concat()

    let background = rounded(NSRect(x: 52, y: 52, width: 920, height: 920), 220)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.22, green: 0.35, blue: 0.89, alpha: 1).setFill()
    background.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [
        NSColor(calibratedRed: 0.22, green: 0.56, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.34, green: 0.28, blue: 0.84, alpha: 1)
    ])!.draw(in: background, angle: -65)

    NSColor.white.withAlphaComponent(0.24).setFill()
    rounded(NSRect(x: 276, y: 189, width: 514, height: 574), 76).fill()
    NSColor.white.withAlphaComponent(0.42).setFill()
    rounded(NSRect(x: 242, y: 217, width: 514, height: 574), 76).fill()
    NSColor.white.setFill()
    rounded(NSRect(x: 208, y: 245, width: 514, height: 574), 76).fill()

    let blue = NSColor(calibratedRed: 0.27, green: 0.39, blue: 0.89, alpha: 1)
    blue.setFill()
    rounded(NSRect(x: 351, y: 768, width: 227, height: 96), 42).fill()
    NSColor.white.withAlphaComponent(0.95).setFill()
    rounded(NSRect(x: 407, y: 802, width: 115, height: 22), 11).fill()

    blue.withAlphaComponent(0.88).setFill()
    rounded(NSRect(x: 283, y: 628, width: 293, height: 38), 19).fill()
    blue.withAlphaComponent(0.28).setFill()
    rounded(NSRect(x: 283, y: 533, width: 358, height: 30), 15).fill()
    rounded(NSRect(x: 283, y: 457, width: 294, height: 30), 15).fill()
    rounded(NSRect(x: 283, y: 381, width: 216, height: 30), 15).fill()

    NSColor(calibratedRed: 0.57, green: 0.91, blue: 0.82, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 640, y: 216, width: 202, height: 202)).fill()
    blue.setStroke()
    let check = NSBezierPath()
    check.move(to: NSPoint(x: 692, y: 316))
    check.line(to: NSPoint(x: 728, y: 280))
    check.line(to: NSPoint(x: 790, y: 349))
    check.lineWidth = 20
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.stroke()
    image.unlockFocus()

    // Explicit pixel dimensions keep the icon correct on Retina build machines.
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size, filename: "icon_\(size)x\(size).png")
    try render(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
