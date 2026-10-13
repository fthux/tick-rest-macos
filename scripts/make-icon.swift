import AppKit
import Foundation
import SwiftUI

@MainActor
func generateIcons() throws {
    let directory = URL(fileURLWithPath: "packaging/AppIcon.iconset", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let side: CGFloat = 1024
    // Render in light appearance so the app icon and About artwork stay identical.
    // The bottom is the existing SwiftUI orange theme; the top adds 25% white.
    let renderer = ImageRenderer(content:
        ZStack {
            Color.orange
            LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
            Image(systemName: "leaf.fill")
                .font(.system(size: side * 0.58)).foregroundStyle(.white)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
        .environment(\.colorScheme, .light)
    )
    guard let artwork = renderer.cgImage else { fatalError("Could not render the app icon") }
    let aboutImage = NSBitmapImageRep(cgImage: artwork)
    try aboutImage.representation(using: .png, properties: [:])!.write(to:
        URL(fileURLWithPath: "Sources/TickRestCore/Resources/AppIcon.png"))
    let image = NSImage(cgImage: artwork, size: NSSize(width: side, height: side))
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = size * scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .high
            let n = CGFloat(pixels)
            // Standard macOS icon inset; the About resource has no outer canvas padding.
            image.draw(in: NSRect(x: n * 0.1, y: n * 0.1, width: n * 0.8, height: n * 0.8),
                       from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let suffix = scale == 2 ? "@2x" : ""
            try bitmap.representation(using: .png, properties: [:])!.write(to:
                directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
    let conversion = Process()
    conversion.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    conversion.arguments = ["-c", "icns", directory.path, "-o", "packaging/AppIcon.icns"]
    try conversion.run(); conversion.waitUntilExit()
    guard conversion.terminationStatus == 0 else { fatalError("Could not export AppIcon.icns") }
}

try MainActor.assumeIsolated { try generateIcons() }
