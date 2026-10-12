import Foundation
import CoreGraphics
import Testing
@testable import TickRestCore

struct FullscreenBackgroundTests {
    @Test func wallpaperProtectionValuesAreIndependentAndSurviveDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        var data = SavedData()
        data.settings.overlayBackground.kind = .gradient
        data.settings.overlayBackground.activeProtection = 0.72
        data.settings.overlayBackground.kind = .wallpaper
        let expected: [WallpaperSource: Double] = [.desktop: 0.6, .system: 0.8, .custom: 0.9]
        for source in WallpaperSource.allCases {
            data.settings.overlayBackground.wallpaper.source = source
            data.settings.overlayBackground.activeProtection = expected[source]!
        }
        try store.save(data)
        var loaded = store.load().settings.overlayBackground
        for source in WallpaperSource.allCases {
            loaded.wallpaper.source = source
            #expect(loaded.normalized.activeProtection == expected[source])
        }
        loaded.kind = .gradient
        #expect(loaded.activeProtection == 0.72)
        #expect(store.loadErrorKey == nil)
    }

    @Test func legacySharedProtectionMigratesWithoutChangingTheCurrentAppearance() throws {
        var old = OverlayBackground()
        old.kind = .wallpaper; old.wallpaper.source = .system; old.protection = 0.83
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "wallpaperProtection")
        var migrated = try JSONDecoder().decode(OverlayBackground.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.activeProtection == 0.83)
        migrated.activeProtection = 0.7
        migrated.wallpaper.source = .desktop
        #expect(migrated.activeProtection == 0.83)
        migrated.wallpaper.source = .custom
        #expect(migrated.activeProtection == 0.83)
        migrated.kind = .gradient
        #expect(migrated.activeProtection == 0.83)
    }

    @Test func eachWallpaperProtectionIsNormalizedIndependently() {
        var background = OverlayBackground()
        background.wallpaperProtection.desktop = .nan
        background.wallpaperProtection.system = -1
        background.wallpaperProtection.custom = 2
        background.protection = 0.78
        let result = background.normalized
        #expect(result.wallpaperProtection.desktop == 0.65)
        #expect(result.wallpaperProtection.system == 0.6)
        #expect(result.wallpaperProtection.custom == 0.9)
        #expect(result.protection == 0.78)
    }

    @Test func defaultSettingsRemainEqualAcrossIndependentInitializations() {
        #expect(Settings() == Settings())
        #expect(OverlayBackground() == OverlayBackground())
    }
    @Test(arguments: [OverlayBackgroundKind.solid, .gradient, .wallpaper])
    func appearanceChangesPreserveWarningRestAndQueuedPlan(_ kind: OverlayBackgroundKind) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let engine = Engine(settings: Settings())
        engine.tick(seconds: engine.settings.shortInterval - engine.settings.prewarning, now: now)
        let warning = engine.effects
        var settings = engine.settings
        settings.overlayBackground.kind = kind
        settings.overlayBackground.gradient = BackgroundPresets.gradients[2].gradient
        settings.overlayBackground.wallpaper.source = .custom
        settings.overlayBackground.wallpaper.customID = "custom-example"
        settings.overlayBackground.wallpaper.position = .init(x: 0.25, y: 0.75)
        settings.overlayBackground.protection = 0.8
        engine.updateSettings(settings)
        #expect(engine.effects == warning && engine.graceRemaining == 0)
        engine.tick(seconds: settings.prewarning, now: now)
        #expect(engine.isResting)
        engine.tick(seconds: 3, now: now)
        engine.applyPlan(.preset(.pomodoro), now: now)
        let reminder = try #require(engine.reminder)
        let pending = engine.pendingPlan
        settings = engine.settings; settings.overlayBackground.gradient.angle = 180
        engine.updateSettings(settings)
        #expect(engine.reminder == reminder && engine.pendingPlan == pending && engine.graceRemaining == 0)
    }

    @Test func allBackgroundTypesAndInactivePreferencesSurviveDiskRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(url: directory.appendingPathComponent("state.json"))
        for kind in OverlayBackgroundKind.allCases {
            var data = SavedData()
            data.settings.overlayBackground.kind = kind
            data.settings.overlayBackgroundColor = .hex("AA6633")!
            data.settings.overlayBackground.gradient = BackgroundPresets.gradients[5].gradient
            data.settings.overlayBackground.gradient.center = .init(x: 0.3, y: 0.7)
            data.settings.overlayBackground.wallpaper.source = .system
            data.settings.overlayBackground.wallpaper.systemID = "system-example"
            data.settings.overlayBackground.wallpaper.customID = "custom-example"
            data.settings.overlayBackground.wallpaper.fit = .fit
            data.settings.overlayBackground.wallpaper.position = .init(x: 0.2, y: 0.6)
            data.settings.overlayBackground.wallpaper.baseColor = .hex("DDEEFF")!
            try store.save(data)
            let loaded = store.load()
            #expect(store.loadErrorKey == nil && loaded.settings == data.settings)
        }
    }

    @Test(arguments: ["missing", "invalid", "null", "unknown"])
    func legacyAndBrokenBackgroundPreserveAllOtherPreferences(_ variant: String) throws {
        var saved = SavedData()
        saved.settings.language = "ko"
        saved.settings.overlayBackgroundColor = .hex("334455")!
        saved.snapshot.shortElapsed = 45
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var settings = try #require(json["settings"] as? [String: Any])
        switch variant {
        case "missing": settings.removeValue(forKey: "overlayBackground")
        case "null": settings["overlayBackground"] = NSNull()
        case "unknown":
            var background = settings["overlayBackground"] as! [String: Any]
            background["kind"] = "future-format"; settings["overlayBackground"] = background
        default: settings["overlayBackground"] = ["gradient": "broken"]
        }
        json["settings"] = settings
        let result = try JSONDecoder().decode(SavedData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(result.settings.overlayBackground.kind == .solid)
        #expect(result.settings.overlayBackgroundColor == .hex("334455"))
        #expect(result.settings.language == "ko" && result.snapshot.shortElapsed == 45)
    }

    @Test func invalidGeometryAndGradientParametersAreBounded() {
        var background = OverlayBackground()
        background.gradient.angle = .infinity
        background.gradient.radius = -10
        background.gradient.center = .init(x: .nan, y: 8)
        background.wallpaper.position = .init(x: -2, y: .infinity)
        background.protection = .nan
        let normalized = background.normalized
        #expect(normalized.gradient.angle == 45 && normalized.gradient.radius == 0.1)
        #expect(normalized.gradient.center == .init(x: 0.5, y: 1))
        #expect(normalized.wallpaper.position == .init(x: 0, y: 0.5))
        #expect(normalized.protection == 0.65)
        #expect(BackgroundGeometry.imageRect(image: .zero, viewport: .zero, fit: .fill, position: .init()) == .zero)
        background.gradient.stops = []
        #expect(background.normalized.gradient.stops.count == 2)
        background.gradient.stops = (0..<8).map { .init(color: .hex("ABCDEF")!, location: Double($0) - 2) }
        #expect(background.normalized.gradient.stops.count == 5)
        #expect(background.normalized.gradient.stops.allSatisfy { (0...1).contains($0.location) })
    }

    @Test func reversalPreservesSmoothStopPositionsAndColorOrder() {
        var gradient = BackgroundGradient(colors: [.hex("000000")!, .hex("FF0000")!, .hex("FFFFFF")!])
        gradient.stops[1].location = 0.2
        let original = gradient
        gradient.reverse()
        #expect(gradient.stops.map(\.location) == [0, 0.8, 1])
        #expect(gradient.stops.map(\.color) == original.stops.reversed().map(\.color))
        gradient.reverse()
        #expect(abs(gradient.stops[1].location - original.stops[1].location) < 0.0001)
    }

    @Test(arguments: [CGSize(width: 1920, height: 1080), CGSize(width: 3440, height: 1440), CGSize(width: 1080, height: 1920)])
    func imageFitAndCropCoverDifferentMonitorShapes(_ viewport: CGSize) {
        let image = CGSize(width: 2400, height: 1600)
        let bounds = CGRect(origin: .zero, size: viewport)
        for position in [BackgroundPoint(x: 0, y: 0), .init(), .init(x: 1, y: 1)] {
            let filled = BackgroundGeometry.imageRect(image: image, viewport: viewport, fit: .fill, position: position)
            #expect(filled.minX <= 0 && filled.minY <= 0)
            #expect(filled.maxX >= viewport.width - 0.0001 && filled.maxY >= viewport.height - 0.0001)
            #expect(abs(filled.width / filled.height - image.width / image.height) < 0.0001)
            let fitted = BackgroundGeometry.imageRect(image: image, viewport: viewport, fit: .fit, position: position)
            #expect(bounds.insetBy(dx: -0.0001, dy: -0.0001).contains(fitted))
            #expect(abs(fitted.midX - bounds.midX) < 0.0001 && abs(fitted.midY - bounds.midY) < 0.0001)
            let stretched = BackgroundGeometry.imageRect(image: image, viewport: viewport, fit: .stretch, position: position)
            #expect(stretched == bounds)
        }
    }

    @Test func draggingRespectsCropDirectionAndClampsAtEdges() {
        let image = CGSize(width: 3000, height: 1000), viewport = CGSize(width: 1000, height: 1000)
        let left = BackgroundGeometry.draggedPosition(start: .init(), translation: CGSize(width: 500, height: 0), image: image, viewport: viewport)
        #expect(left.x == 0.25 && left.y == 0.5)
        let edge = BackgroundGeometry.draggedPosition(start: .init(), translation: CGSize(width: -9000, height: 9000), image: image, viewport: viewport)
        #expect(edge.x == 1 && edge.y == 0.5)
    }

    @Test(arguments: [CGSize(width: 3840, height: 1080), CGSize(width: 1080, height: 3840)])
    func gradientDirectionIsStableAcrossAspectRatios(_ size: CGSize) {
        let points = BackgroundGeometry.linearEndpoints(size: size, angle: 45)
        let dx = (points.1.x - points.0.x) * size.width
        let dy = (points.1.y - points.0.y) * size.height
        #expect(abs(dx - dy) < 0.0001)
        let radius = BackgroundGeometry.radialRadius(size: size, center: .init(x: 0, y: 0), fraction: 1)
        #expect(abs(radius - hypot(size.width, size.height)) < 0.0001)
    }

    @Test func hexInputRejectsMalformedValues() {
        #expect(SRGBColor.hex(" #1a2e26 ")?.hexString == "#1A2E26")
        for input in ["123", "1234567", "12#3456", "#GG1122", "##112233", "😀12345"] { #expect(SRGBColor.hex(input) == nil) }
    }
}
