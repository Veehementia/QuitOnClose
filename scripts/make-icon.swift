// Renders the app icon into an .iconset folder. Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(size)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let background = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(
        starting: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.32, alpha: 1),
        ending: NSColor(calibratedRed: 0.93, green: 0.27, blue: 0.27, alpha: 1)
    )!.draw(in: background, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        symbol.draw(in: NSRect(
            x: (s - symbolSize.width) / 2, y: (s - symbolSize.height) / 2,
            width: symbolSize.width, height: symbolSize.height
        ))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
