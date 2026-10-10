import AppKit
import Foundation
import SwiftUI

@MainActor
func generateIcons() throws {
    let directory = URL(fileURLWithPath: "packaging/AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            // Render the same SwiftUI symbol, font and color used by SettingsView.about.
            let renderer = ImageRenderer(content:
                Image(systemName: "leaf.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = CGFloat(pixels) / 36
            guard let symbol = renderer.nsImage else {
                fatalError("The About page leaf icon could not be rendered")
            }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            let n = CGFloat(pixels)
            let factor = n * 0.95 / max(symbol.size.width, symbol.size.height)
            let width = symbol.size.width * factor
            let height = symbol.size.height * factor
            symbol.draw(in: NSRect(x: (n - width) / 2, y: (n - height) / 2,
                                   width: width, height: height),
                        from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let suffix = scale == 2 ? "@2x" : ""
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}

try MainActor.assumeIsolated { try generateIcons() }
