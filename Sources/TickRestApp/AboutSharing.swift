import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TickRestCore
import UniformTypeIdentifiers

enum AboutQRCode {
    private static func renderedImage(for url: URL, includesIcon: Bool) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "H"
        guard let code = filter.outputImage else { return nil }
        // Keep a four-module white quiet zone in both the popover and exported PNG.
        let extent = CGRect(x: 0, y: 0, width: code.extent.width + 8, height: code.extent.height + 8)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        var result = code.transformed(by: CGAffineTransform(translationX: 4, y: 4)).composited(over: white)

        if includesIcon,
           let iconURL = L10n.resourceBundle.url(forResource: "AppIcon", withExtension: "png"),
           let icon = CIImage(contentsOf: iconURL) {
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let backingSize = code.extent.width * 0.36
            let iconSize = code.extent.width * 0.29
            let backingRect = CGRect(x: center.x - backingSize / 2, y: center.y - backingSize / 2,
                                     width: backingSize, height: backingSize)
            let iconRect = CGRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2,
                                  width: iconSize, height: iconSize)
            let backing = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: backingRect)
            let scaledIcon = icon.transformed(by: CGAffineTransform(
                scaleX: iconSize / icon.extent.width, y: iconSize / icon.extent.height
            )).transformed(by: CGAffineTransform(translationX: iconRect.minX, y: iconRect.minY))
            result = scaledIcon.composited(over: backing.composited(over: result))
        }

        let padded = result
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    static func image(for url: URL) -> CGImage? { renderedImage(for: url, includesIcon: true) }
    static func baseImage(for url: URL) -> CGImage? { renderedImage(for: url, includesIcon: false) }

    static let appIcon = L10n.resourceBundle.url(forResource: "AppIcon", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
    static let websiteImage = image(for: AboutLinks.website)
    static let websiteBaseImage = baseImage(for: AboutLinks.website)
}

struct AboutQRCodeView: View {
    @State private var saveError: String?
    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.text("about.qr_title")).font(.headline)
            if let code = AboutQRCode.websiteImage, let base = AboutQRCode.websiteBaseImage {
                ZStack {
                    Image(decorative: base, scale: 1).resizable().interpolation(.none)
                    if let icon = AboutQRCode.appIcon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                            .padding(220 * 0.035)
                            .frame(width: 220 * 0.29, height: 220 * 0.29)
                            .background(.white)
                    }
                }
                .frame(width: 220, height: 220)
                .accessibilityLabel(L10n.text("about.qr_title"))
                Text(AboutLinks.website.absoluteString).font(.caption).textSelection(.enabled)
                Button(L10n.text("about.save_qr")) { save(code) }.buttonStyle(.bordered)
            } else {
                Text(L10n.text("about.qr_error")).foregroundStyle(.secondary)
            }
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
        }
        .padding(20).frame(width: 280)
    }

    private func save(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(AppIdentity.name)-QR.png"
        panel.canCreateDirectories = true
        saveError = nil
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                saveError = L10n.text("about.qr_save_error")
            }
        }
    }
}
