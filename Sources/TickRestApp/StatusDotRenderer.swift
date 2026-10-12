import AppKit
import TickRestCore

/// Leave menu-bar text styling and symbol rendering to AppKit.
final class StatusDotRenderer {
    private var cachedColor: StatusDotColor?
    private var cachedImage: NSImage?

    func title(text: String, color: StatusDotColor?, font: NSFont) -> NSAttributedString {
        // An explicit foreground color overrides the status button's inactive
        // menu-bar text styling. Only specify the font, including on spaces.
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let result = NSMutableAttributedString(string: "", attributes: attributes)
        if let color {
            result.append(NSAttributedString(string: " ", attributes: attributes))
            let attachment = NSTextAttachment()
            attachment.image = image(color: color)
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - 6) / 2, width: 6, height: 6)
            result.append(NSAttributedString(attachment: attachment))
        }
        if !text.isEmpty { result.append(NSAttributedString(string: " " + text, attributes: attributes)) }
        return result
    }

    private func image(color: StatusDotColor) -> NSImage? {
        if cachedColor == color, let cachedImage { return cachedImage }
        // Retain a native palette symbol rather than a bitmap painted with a
        // captured appearance, so AppKit can render it in the current context.
        let configuration = NSImage.SymbolConfiguration(pointSize: 6, weight: .regular)
            .applying(.init(paletteColors: [NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)]))
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        cachedColor = color; cachedImage = image
        return image
    }
}
