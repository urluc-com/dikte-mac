// Dikte uygulama ikonunu üretir: URLuc gradyanı (mavi→mor) üstünde beyaz mikrofon.
// Kullanım: swift Tools/make-icon.swift  →  Resources/AppIcon.icns
import AppKit

let canvas: CGFloat = 1024
let inset: CGFloat = 100            // macOS ikon ızgarası: 824 pt'lik gövde
let body = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let blue = NSColor(srgbRed: 0x0A / 255, green: 0x7C / 255, blue: 0xFF / 255, alpha: 1)
    let purple = NSColor(srgbRed: 0x8B / 255, green: 0x5C / 255, blue: 0xF6 / 255, alpha: 1)
    NSGradient(starting: blue, ending: purple)!.draw(in: shape, angle: -35)

    let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        symbol.draw(in: CGRect(x: (canvas - size.width) / 2, y: (canvas - size.height) / 2,
                               width: size.width, height: size.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Dikte.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, pixels) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                       ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
                       ("512x512", 512), ("512x512@2x", 1024)] {
    try render(pixels).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "Resources/AppIcon.icns yazıldı" : "iconutil hata verdi")
