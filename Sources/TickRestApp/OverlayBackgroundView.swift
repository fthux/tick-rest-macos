import AppKit
import SwiftUI
import TickRestCore

extension SRGBColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    init?(swiftUIColor: Color) {
        guard let color = NSColor(swiftUIColor).usingColorSpace(.sRGB) else { return nil }
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent)
    }
}

struct BackgroundGradientView: View {
    let gradient: BackgroundGradient
    var body: some View {
        GeometryReader { geometry in
            let value = gradient.normalized
            let colors = Gradient(stops: value.stops.map { .init(color: $0.color.swiftUIColor, location: $0.location) })
            if value.kind == .linear {
                let endpoints = BackgroundGeometry.linearEndpoints(size: geometry.size, angle: value.angle)
                LinearGradient(gradient: colors, startPoint: UnitPoint(x: endpoints.0.x, y: endpoints.0.y),
                               endPoint: UnitPoint(x: endpoints.1.x, y: endpoints.1.y))
            } else {
                RadialGradient(gradient: colors, center: UnitPoint(x: value.center.x, y: value.center.y), startRadius: 0,
                               endRadius: BackgroundGeometry.radialRadius(size: geometry.size, center: value.center, fraction: value.radius))
            }
        }.clipped()
    }
}

/// Enlarge the text backing independently of the whole-screen thumbnail, so a
/// continuous opacity edit is visible at normal text size even on a large display.
struct BackgroundProtectionPreview: View {
    let background: OverlayBackground
    var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("background.protection_preview")).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                ZStack {
                    if background.kind == .gradient { BackgroundGradientView(gradient: background.gradient) }
                    else if let image {
                        Image(decorative: image, scale: 1).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    } else { Settings.defaultOverlayBackgroundColor.swiftUIColor }
                    HStack(spacing: 12) {
                        Image(systemName: "leaf").font(.title2)
                        Text(L10n.text("background.protection_sample")).font(.body).fixedSize(horizontal: false, vertical: true)
                    }.foregroundStyle(.white).padding(14)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(background.normalized.activeProtection)))
                        .shadow(color: .black.opacity(background.normalized.activeProtection * 0.7), radius: 10)
                        .padding(12)
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.frame(height: 96).clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

struct DesktopWallpaperSnapshot {
    var url: URL?
    var fit: WallpaperFit = .fill
    var baseColor = Settings.defaultOverlayBackgroundColor
    static func capture(_ screen: NSScreen?) -> Self {
        guard let screen else { return Self() }
        let workspace = NSWorkspace.shared
        var value = Self(url: workspace.desktopImageURL(for: screen))
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        if let scale = options[.imageScaling] as? NSNumber {
            if scale.intValue == NSImageScaling.scaleAxesIndependently.rawValue { value.fit = .stretch }
            else if scale.intValue == NSImageScaling.scaleProportionallyUpOrDown.rawValue {
                value.fit = options[.allowClipping] as? Bool == true ? .fill : .fit
            }
        }
        if let color = options[.fillColor] as? NSColor, let rgb = color.usingColorSpace(.sRGB) {
            value.baseColor = SRGBColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
        }
        return value
    }
    static func screenID(_ screen: NSScreen?) -> String {
        guard let screen else { return "unknown-display" }
        let identifier = ConnectedDisplay.identifier(for: screen)
        return WallpaperRepository.safeName(identifier) ? identifier : "unknown-display"
    }
    static func pixelSize(_ screen: NSScreen?) -> CGSize {
        guard let screen else { return CGSize(width: 1920, height: 1080) }
        return CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
    }
}

/// Request identity excludes timer ticks and crop edits. Desktop resources are captured once per presentation.
struct WallpaperSurface: View {
    @ObservedObject var library: WallpaperLibrary
    let wallpaper: WallpaperBackground
    let screen: NSScreen?
    var maximumPixels: Int?
    var refreshToken = 0
    var onResolved: ((ResolvedWallpaper) -> Void)?
    @State private var image: CGImage?
    @State private var desktop = DesktopWallpaperSnapshot()
    private var request: WallpaperImageRequest {
        let pixels = DesktopWallpaperSnapshot.pixelSize(screen)
        let scale: CGFloat = min(1, CGFloat(maximumPixels ?? Int(max(pixels.width, pixels.height))) / max(pixels.width, pixels.height))
        return WallpaperImageRequest(source: wallpaper.source, selectedID: wallpaper.selectedID, desktopURL: nil,
                                     screenID: DesktopWallpaperSnapshot.screenID(screen),
                                     maximumPixels: maximumPixels ?? Int(max(pixels.width, pixels.height)),
                                     revision: wallpaper.source == .desktop ? 0 : library.revision,
                                     viewport: CGSize(width: pixels.width * scale, height: pixels.height * scale), fit: wallpaper.fit)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if let image {
                    let fit = wallpaper.source == .desktop ? desktop.fit : wallpaper.fit
                    let rect = BackgroundGeometry.imageRect(image: CGSize(width: image.width, height: image.height),
                                                            viewport: geometry.size, fit: fit, position: wallpaper.position)
                    (wallpaper.source == .desktop ? desktop.baseColor : wallpaper.baseColor).swiftUIColor
                    Image(decorative: image, scale: 1).resizable().interpolation(.high)
                        .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                } else {
                    Settings.defaultOverlayBackgroundColor.swiftUIColor
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: RequestIdentity(request: request, refresh: refreshToken)) {
            var value = request
            let snapshot = wallpaper.source == .desktop ? DesktopWallpaperSnapshot.capture(screen) : DesktopWallpaperSnapshot()
            value.desktopURL = snapshot.url
            if wallpaper.source == .desktop, screen == nil { value.desktopFailure = .init(kind: .screenUnavailable) }
            if wallpaper.source == .desktop { value.fit = snapshot.fit }
            let result = await library.resolve(value)
            guard !Task.isCancelled else { return }
            desktop = snapshot; image = result.image; onResolved?(result)
        }
    }
    private struct RequestIdentity: Equatable { var request: WallpaperImageRequest; var refresh: Int }
}

struct OverlayBackgroundView: View {
    @ObservedObject var library: WallpaperLibrary
    let background: OverlayBackground
    let solid: SRGBColor
    var screen: NSScreen?
    var maximumPixels: Int?
    var refreshToken = 0
    var onResolved: ((ResolvedWallpaper) -> Void)?
    var body: some View {
        switch background.kind {
        case .solid: solid.swiftUIColor
        case .gradient: BackgroundGradientView(gradient: background.gradient)
        case .wallpaper:
            WallpaperSurface(library: library, wallpaper: background.wallpaper, screen: screen,
                             maximumPixels: maximumPixels, refreshToken: refreshToken, onResolved: onResolved)
        }
    }
}
