import AppKit
import TickRestCore

/// A non-template attachment preserves the dot's color beside the native template icon.
final class StatusDotRenderer {
    private var cachedColor: StatusDotColor?
    private var cachedAppearance: String?
    private var cachedImage: NSImage?

    func title(text: String, color: StatusDotColor?, appearance: NSAppearance, font: NSFont) -> NSAttributedString {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let result = NSMutableAttributedString(string: "", attributes: attributes)
        if let color {
            result.append(NSAttributedString(string: " ", attributes: attributes))
            let attachment = NSTextAttachment()
            attachment.image = image(color: color, appearance: appearance)
            attachment.bounds = NSRect(x: 0, y: (font.capHeight - 14) / 2, width: 10, height: 14)
            result.append(NSAttributedString(attachment: attachment))
        }
        if !text.isEmpty { result.append(NSAttributedString(string: " " + text, attributes: attributes)) }
        return result
    }

    private func image(color: StatusDotColor, appearance: NSAppearance) -> NSImage {
        let appearanceKey = appearance.name.rawValue
        if cachedColor == color, cachedAppearance == appearanceKey, let cachedImage { return cachedImage }
        var outline = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance { outline = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor }
        let image = NSImage(size: NSSize(width: 10, height: 14), flipped: false) { _ in
            let circle = NSBezierPath(ovalIn: NSRect(x: 2, y: 4, width: 6, height: 6))
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            circle.fill()
            outline.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 0.5; circle.stroke()
            return true
        }
        image.isTemplate = false
        cachedColor = color; cachedAppearance = appearanceKey; cachedImage = image
        return image
    }
}
