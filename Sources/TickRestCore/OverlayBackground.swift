import Foundation
import CoreGraphics

public enum OverlayBackgroundKind: String, Codable, CaseIterable { case solid, gradient, wallpaper }
public enum BackgroundGradientKind: String, Codable, CaseIterable { case linear, radial }
public enum WallpaperSource: String, Codable, CaseIterable { case desktop, system, custom }
public enum WallpaperFit: String, Codable, CaseIterable { case fill, fit, stretch }

public struct BackgroundPoint: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0.5, y: Double = 0.5) { self.x = x; self.y = y }
    public var normalized: Self { Self(x: Self.clamp(x), y: Self.clamp(y)) }
    static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
}

public struct BackgroundGradientStop: Codable, Equatable, Identifiable {
    public var id: UUID
    public var color: SRGBColor
    public var location: Double
    public init(color: SRGBColor, location: Double, id: UUID = UUID()) {
        self.id = id; self.color = color; self.location = location
    }
}

public struct BackgroundGradient: Codable, Equatable {
    public var kind: BackgroundGradientKind = .linear
    public var stops: [BackgroundGradientStop]
    /// Zero points right; positive angles turn clockwise in screen coordinates.
    public var angle: Double = 45
    public var center = BackgroundPoint()
    /// Radius as a fraction of the distance to the furthest corner.
    public var radius: Double = 1
    public init(colors: [SRGBColor] = [.hex("16382D")!, .hex("6F9682")!]) {
        let colors = colors.count >= 2 ? Array(colors.prefix(5)) : [.hex("16382D")!, .hex("6F9682")!]
        // Deterministic initial IDs keep two default Settings values equal.
        // User-added stops still receive their own UUID.
        stops = colors.enumerated().map {
            .init(color: $0.element, location: Double($0.offset) / Double(colors.count - 1),
                  id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0.offset + 1))!)
        }
    }
    public var normalized: Self {
        var result = self
        result.angle = angle.isFinite ? (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) : 45
        result.center = center.normalized
        result.radius = radius.isFinite ? min(2, max(0.1, radius)) : 1
        if stops.count < 2 { result.stops = Self().stops }
        else {
            var seen = Set<UUID>()
            result.stops = stops.prefix(5).map {
                var stop = $0
                stop.location = BackgroundPoint.clamp(stop.location)
                if !seen.insert(stop.id).inserted { stop.id = UUID() }
                return stop
            }.sorted { $0.location < $1.location }
        }
        return result
    }
    public mutating func reverse() {
        stops = stops.reversed().map { .init(color: $0.color, location: 1 - $0.location, id: $0.id) }
    }
    public func matches(_ other: Self) -> Bool {
        let a = normalized, b = other.normalized
        return a.kind == b.kind && a.angle == b.angle && a.center == b.center && a.radius == b.radius
            && a.stops.map(\.color) == b.stops.map(\.color) && a.stops.map(\.location) == b.stops.map(\.location)
    }
}

public struct WallpaperBackground: Codable, Equatable {
    public var source: WallpaperSource = .desktop
    public var systemID: String?
    public var customID: String?
    public var fit: WallpaperFit = .fill
    public var position = BackgroundPoint()
    public var baseColor = Settings.defaultOverlayBackgroundColor
    public init() {}
    public var selectedID: String? { source == .system ? systemID : source == .custom ? customID : nil }
}

public struct WallpaperProtection: Codable, Equatable {
    public var desktop: Double
    public var system: Double
    public var custom: Double
    public init(value: Double = 0.65) { desktop = value; system = value; custom = value }
    public subscript(source: WallpaperSource) -> Double {
        get {
            switch source { case .desktop: return desktop; case .system: return system; case .custom: return custom }
        }
        set {
            switch source { case .desktop: desktop = newValue; case .system: system = newValue; case .custom: custom = newValue }
        }
    }
}

public struct OverlayBackground: Codable, Equatable {
    public var kind: OverlayBackgroundKind = .solid
    public var gradient = BackgroundGradient()
    public var wallpaper = WallpaperBackground()
    /// Gradient protection; retained as the legacy decoding key.
    public var protection: Double = 0.65
    public var wallpaperProtection = WallpaperProtection()
    public init() {}
    public var activeProtection: Double {
        get { kind == .wallpaper ? wallpaperProtection[wallpaper.source] : protection }
        set {
            if kind == .wallpaper { wallpaperProtection[wallpaper.source] = newValue }
            else { protection = newValue }
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, gradient, wallpaper, protection, wallpaperProtection }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(OverlayBackgroundKind.self, forKey: .kind)
        gradient = try values.decode(BackgroundGradient.self, forKey: .gradient)
        wallpaper = try values.decode(WallpaperBackground.self, forKey: .wallpaper)
        protection = try values.decode(Double.self, forKey: .protection)
        // Start all sources at the user's old value, then persist them independently.
        wallpaperProtection = try values.decodeIfPresent(WallpaperProtection.self, forKey: .wallpaperProtection)
            ?? WallpaperProtection(value: protection)
    }
    private static func clampedProtection(_ value: Double) -> Double {
        value.isFinite ? min(0.9, max(0.6, value)) : 0.65
    }
    public var normalized: Self {
        var result = self
        result.gradient = gradient.normalized
        result.wallpaper.position = wallpaper.position.normalized
        result.protection = Self.clampedProtection(protection)
        for source in WallpaperSource.allCases {
            result.wallpaperProtection[source] = Self.clampedProtection(wallpaperProtection[source])
        }
        return result
    }
}

public extension SRGBColor {
    static func hex(_ text: String) -> Self? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isASCII && $0.isHexDigit }), let number = UInt32(value, radix: 16) else { return nil }
        return Self(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
    }
    var hexString: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
}

public enum BackgroundPresets {
    public static let solid: [(name: String, color: SRGBColor)] = [
        ("forest", Settings.defaultOverlayBackgroundColor), ("ocean", .hex("172B42")!),
        ("twilight", .hex("30283F")!), ("graphite", .hex("262A30")!),
        ("sage", .hex("DCE6DC")!), ("cream", .hex("F2EBDD")!)
    ]
    public static let gradients: [(name: String, gradient: BackgroundGradient)] = {
        var result = [(String, BackgroundGradient)]()
        for (name, first, last) in [("forest", "16382D", "6F9682"), ("ocean", "10243A", "386B89"),
                                    ("twilight", "302448", "8A739F"), ("sunset", "D99183", "F1D5AF"),
                                    ("mint", "CFE8DD", "EAF1DF"), ("night", "435477", "151C2D")] {
            var gradient = BackgroundGradient(colors: [.hex(first)!, .hex(last)!])
            if name == "night" { gradient.kind = .radial }
            result.append((name, gradient))
        }
        return result
    }()
}

/// Pure geometry shared by previews and actual screens; all coordinates are top-left based.
public enum BackgroundGeometry {
    public static func imageRect(image: CGSize, viewport: CGSize, fit: WallpaperFit, position: BackgroundPoint) -> CGRect {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
              [image.width, image.height, viewport.width, viewport.height].allSatisfy(\.isFinite) else { return .zero }
        if fit == .stretch { return CGRect(origin: .zero, size: viewport) }
        let ratios = (viewport.width / image.width, viewport.height / image.height)
        let scale = fit == .fill ? max(ratios.0, ratios.1) : min(ratios.0, ratios.1)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        let p = position.normalized
        let x = fit == .fill ? p.x : 0.5, y = fit == .fill ? p.y : 0.5
        return CGRect(x: (viewport.width - size.width) * x, y: (viewport.height - size.height) * y, width: size.width, height: size.height)
    }
    public static func linearEndpoints(size: CGSize, angle: Double) -> (BackgroundPoint, BackgroundPoint) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return (.init(x: 0, y: 0), .init(x: 1, y: 1)) }
        let radians = (angle.isFinite ? angle : 45) * .pi / 180
        let dx = cos(radians), dy = sin(radians)
        let halfSpan = (abs(dx) * size.width + abs(dy) * size.height) / 2
        let x = dx * halfSpan / size.width, y = dy * halfSpan / size.height
        return (.init(x: 0.5 - x, y: 0.5 - y), .init(x: 0.5 + x, y: 0.5 + y))
    }
    public static func radialRadius(size: CGSize, center: BackgroundPoint, fraction: Double) -> Double {
        let p = center.normalized
        return hypot(max(p.x, 1 - p.x) * size.width, max(p.y, 1 - p.y) * size.height) * fraction
    }
    public static func draggedPosition(start: BackgroundPoint, translation: CGSize, image: CGSize, viewport: CGSize) -> BackgroundPoint {
        let rect = imageRect(image: image, viewport: viewport, fit: .fill, position: start)
        let dx = viewport.width - rect.width, dy = viewport.height - rect.height
        return BackgroundPoint(x: abs(dx) > 0.5 ? start.x + translation.width / dx : start.x,
                               y: abs(dy) > 0.5 ? start.y + translation.height / dy : start.y).normalized
    }
}
