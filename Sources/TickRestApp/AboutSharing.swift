import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TickRestCore
import UniformTypeIdentifiers

enum AboutQRCode {
    static func image(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        // Keep a four-module white quiet zone in both the popover and exported PNG.
        let extent = CGRect(x: 0, y: 0, width: code.extent.width + 8, height: code.extent.height + 8)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: extent)
        let padded = code.transformed(by: CGAffineTransform(translationX: 4, y: 4)).composited(over: white)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    static let websiteImage = image(for: AboutLinks.website)
}

struct AboutQRCodeView: View {
    @State private var saveError: String?
    var body: some View {
        VStack(spacing: 14) {
            Text(L10n.text("about.qr_title")).font(.headline)
            if let code = AboutQRCode.websiteImage {
                Image(decorative: code, scale: 1).resizable().interpolation(.none)
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
