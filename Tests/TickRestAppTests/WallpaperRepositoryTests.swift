import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TickRestCore
@testable import TickRestApp

/// ImageIO, filesystem and pure configuration only. Never launch NSApplication or construct windows.
final class WallpaperRepositoryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func image(_ name: String, width: Int = 1000, height: Int = 600, orientation: Int = 1, frames: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let type = url.pathExtension == "tiff" ? UTType.tiff : url.pathExtension == "jpg" ? UTType.jpeg : UTType.png
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil))
        for _ in 0..<frames {
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
    }
    private func repository(roots: [URL] = []) -> WallpaperRepository {
        WallpaperRepository(directory: root.appendingPathComponent("library"), systemRoots: roots)
    }
    private func request(source: WallpaperSource, id: String? = nil, url: URL? = nil, screen: String = "display-1", pixels: Int = 300) -> WallpaperImageRequest {
        WallpaperImageRequest(source: source, selectedID: id, desktopURL: url, screenID: screen, maximumPixels: pixels, revision: 0)
    }
    func testSystemCategoriesPersistAfterSourceRemovalAndReadLegacyCatalogues() throws {
        let picture = try image("system/Photo.png")
        let color = try image("system/Solid Colors/Blue.png")
        let repo = repository(roots: [picture.deletingLastPathComponent()])
        var manifest = try repo.synchronize(WallpaperManifest())
        let colorItem = try XCTUnwrap(manifest.items.first { $0.name == "Blue" })
        XCTAssertEqual(colorItem.systemCategory, .colors)
        XCTAssertEqual(manifest.items.first { $0.name == "Photo" }?.systemCategory, .pictures)
        try repo.cacheSystem(colorItem.id, in: &manifest)
        try FileManager.default.removeItem(at: color)
        manifest = try repo.synchronize(manifest)
        XCTAssertEqual(repo.load().items.first { $0.id == colorItem.id }?.systemCategory, .colors)
        var legacy = colorItem
        legacy.category = nil
        XCTAssertEqual(legacy.systemCategory, .colors)
        legacy.sourcePath = picture.path
        XCTAssertEqual(legacy.systemCategory, .pictures)
    }
    func testImportedCopiesSurviveSourceRemovalAndDeletingNeverRemovesOriginal() throws {
        let original = try image("original.png"), second = try image("second.png")
        let repo = repository(); var manifest = WallpaperManifest()
        let first = try repo.importImage(original, into: &manifest)
        let other = try repo.importImage(second, into: &manifest)
        XCTAssertEqual(manifest.items.count, 2)
        XCTAssertEqual(repo.load().items, manifest.items)
        try FileManager.default.removeItem(at: original)
        let result = repo.resolve(request(source: .custom, id: first.id))
        XCTAssertNotNil(result.image); XCTAssertFalse(result.usedFallback)
        XCTAssertEqual(result.originalSize, CGSize(width: 1000, height: 600))
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.image).width, 300)
        XCTAssertNotNil(repo.thumbnail(first))
        try repo.removeCustom(other.id, from: &manifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(manifest.items.map(\.id), [first.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(repo.localURL(other.cachedFile!)).path))
        XCTAssertNil(repo.resolve(request(source: .custom, id: other.id)).image)
    }
    func testInvalidOrAnimatedImageDoesNotReplaceValidSelection() throws {
        let valid = try image("valid.png"), animated = try image("animated.tiff", frames: 2)
        let corrupt = root.appendingPathComponent("broken.png"); try Data("invalid".utf8).write(to: corrupt)
        let repo = repository(); var manifest = WallpaperManifest()
        let item = try repo.importImage(valid, into: &manifest)
        for url in [animated, corrupt] { XCTAssertThrowsError(try repo.importImage(url, into: &manifest)) }
        XCTAssertEqual(manifest.items.map(\.id), [item.id])
        XCTAssertEqual(repo.load().items.map(\.id), [item.id])
        XCTAssertNotNil(repo.resolve(request(source: .custom, id: item.id)).image)
    }
    func testScanFiltersDescriptorsVideosThumbnailsAndDynamicAssetsAndDeduplicates() throws {
        let system = root.appendingPathComponent("system")
        let staticImage = try image("system/Static.png")
        _ = try image("system/.thumbnails/Preview.png")
        _ = try image("system/animated.tiff", frames: 2)
        _ = try image("system/dynamic.asset/AssetData/Still.png")
        let dynamicInfo = try PropertyListSerialization.data(fromPropertyList: ["MobileAssetProperties": ["isDynamic": true]], format: .xml, options: 0)
        try dynamicInfo.write(to: system.appendingPathComponent("dynamic.asset/Info.plist"))
        for (name, properties) in [("Dynamic.madesktop", ["isDynamic": true]), ("Missing.madesktop", ["isDynamic": false])] {
            try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0).write(to: system.appendingPathComponent(name))
        }
        try Data("video".utf8).write(to: system.appendingPathComponent("Video.mov"))
        try FileManager.default.createSymbolicLink(at: system.appendingPathComponent("Alias.png"), withDestinationURL: staticImage)
        let repo = repository(roots: [system, system])
        let manifest = try repo.synchronize(WallpaperManifest())
        XCTAssertEqual(manifest.items.count, 2)
        XCTAssertEqual(manifest.items.filter(\.available).map(\.name), ["Static"])
        XCTAssertEqual(manifest.items.filter { !$0.available }.map(\.name), ["Missing"])
        XCTAssertNotNil(manifest.lastSync)
        XCTAssertEqual(try repo.synchronize(manifest).items.map(\.id), manifest.items.map(\.id))
        XCTAssertNotNil(repo.thumbnail(try XCTUnwrap(manifest.items.first { $0.available })))
    }
    func testDefaultScanFindsUserDownloadedWallpapersAndFiltersNonStaticResources() throws {
        // Mirror the default search directories under a temporary home, without scanning the real user's files.
        let home = root.appendingPathComponent("home")
        let roots = WallpaperRepository.defaultSystemRoots(homeDirectory: home).map { url in
            url.path.hasPrefix(home.path + "/") ? url : root.appendingPathComponent("fixtures" + url.path)
        }
        let downloadPath = "home/Library/Application Support/com.apple.mobileAssetDesktop"
        let downloaded = try image("\(downloadPath)/Big Sur Aerial.jpg")
        _ = try image("\(downloadPath)/Catalina.tiff", frames: 2)
        _ = try image("\(downloadPath)/.thumbnails/Preview.png")
        let legacy = try image("fixtures/Library/Desktop Pictures/Legacy.png")
        let repo = repository(roots: roots)
        var manifest = try repo.synchronize(WallpaperManifest())
        XCTAssertEqual(Set(manifest.visibleItems(source: .system).map(\.name)), ["Big Sur Aerial", "Legacy"])
        let item = try XCTUnwrap(manifest.items.first { $0.name == "Big Sur Aerial" })
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(item.sourcePath)).resolvingSymlinksInPath(), downloaded.resolvingSymlinksInPath())
        XCTAssertEqual(item.systemCategory, .pictures)
        XCTAssertNotNil(repo.thumbnail(item))
        try repo.cacheSystem(item.id, in: &manifest)
        let resolved = repo.resolve(request(source: .system, id: item.id))
        XCTAssertNotNil(resolved.image); XCTAssertFalse(resolved.usedFallback)
        XCTAssertEqual(resolved.originalSize, CGSize(width: 1000, height: 600))
        try FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
        manifest = try repo.synchronize(manifest)
        XCTAssertTrue(manifest.visibleItems(source: .system).contains { $0.id == item.id })
        XCTAssertNotNil(repo.resolve(request(source: .system, id: item.id)).image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }
    func testCachedSystemSelectionSurvivesSourceDisappearanceAndSync() throws {
        let source = try image("system/Static.png")
        let repo = repository(roots: [source.deletingLastPathComponent()])
        var manifest = try repo.synchronize(WallpaperManifest())
        let id = try XCTUnwrap(manifest.items.first?.id)
        try repo.cacheSystem(id, in: &manifest)
        try FileManager.default.removeItem(at: source)
        manifest = try repo.synchronize(manifest)
        XCTAssertEqual(manifest.items.map(\.id), [id]); XCTAssertTrue(manifest.items[0].available)
        XCTAssertNil(manifest.items[0].sourcePath)
        let result = repo.resolve(request(source: .system, id: id))
        XCTAssertNotNil(result.image); XCTAssertFalse(result.usedFallback)
        try repo.removeCustom(id, from: &manifest)
        XCTAssertEqual(manifest.items.map(\.id), [id])
    }
    func testDesktopFallbackIsIsolatedByDisplayAndPreservesOriginalResolution() throws {
        let source = try image("desktop.jpg", width: 1600, height: 900)
        let repo = repository()
        XCTAssertNotNil(repo.resolve(request(source: .desktop, url: source, pixels: 120)).image)
        try FileManager.default.removeItem(at: source)
        let fallback = repo.resolve(request(source: .desktop, pixels: 1000))
        XCTAssertTrue(fallback.usedFallback)
        XCTAssertEqual(try XCTUnwrap(fallback.image).width, 1000)
        XCTAssertEqual(fallback.originalSize, CGSize(width: 1600, height: 900))
        XCTAssertNil(repo.resolve(request(source: .desktop, screen: "display-2")).image)
        XCTAssertNil(repo.resolve(request(source: .desktop, screen: "../../outside")).image)
    }
    func testResolvedImagesReuseDecodedPixelsWithoutReusingThumbnailResolution() throws {
        let source = try image("large.png", width: 1600, height: 900)
        let repo = repository(); var manifest = WallpaperManifest()
        let item = try repo.importImage(source, into: &manifest)
        let small = request(source: .custom, id: item.id, pixels: 120)
        let full = request(source: .custom, id: item.id, pixels: 1600)
        let thumbnail = try XCTUnwrap(repo.resolve(small).image)
        let first = try XCTUnwrap(repo.resolve(full).image)
        let second = try XCTUnwrap(repo.resolve(full).image)
        XCTAssertTrue(first === second, "Repeated presentations should reuse the decoded bitmap")
        XCTAssertFalse(first === thumbnail)
        XCTAssertEqual(thumbnail.width, 120)
        XCTAssertEqual(first.width, 1600)
        try repo.removeCustom(item.id, from: &manifest)
        XCTAssertNil(repo.resolve(full).image, "Memory cache must not resurrect a removed selection")
    }
    func testDesktopDecodedCacheInvalidatesWhenFileChangesOrDisappears() throws {
        let source = try image("desktop.png")
        let repo = repository()
        let value = request(source: .desktop, url: source)
        let first = try XCTUnwrap(repo.resolve(value).image)
        XCTAssertTrue(first === repo.resolve(value).image)
        _ = try image("desktop.png", width: 600, height: 1000)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: source.path)
        let replaced = repo.resolve(value)
        XCTAssertFalse(first === replaced.image)
        XCTAssertEqual(replaced.originalSize, CGSize(width: 600, height: 1000))
        try FileManager.default.removeItem(at: source)
        let fallback = repo.resolve(value)
        XCTAssertTrue(fallback.usedFallback)
        XCTAssertNotNil(fallback.failure)
        XCTAssertEqual(fallback.originalSize, CGSize(width: 600, height: 1000))
    }
    func testSyncRefreshesCachedSystemImageWhenItsSourceChanges() throws {
        let source = try image("system/Static.png", width: 1000, height: 600)
        let repo = repository(roots: [source.deletingLastPathComponent()])
        var manifest = try repo.synchronize(WallpaperManifest())
        let id = try XCTUnwrap(manifest.items.first?.id)
        try repo.cacheSystem(id, in: &manifest)
        _ = try image("system/Static.png", width: 600, height: 1000)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: source.path)
        manifest = try repo.synchronize(manifest)
        XCTAssertEqual(manifest.items.first?.id, id)
        XCTAssertEqual(manifest.items.first?.width, 600)
        let result = repo.resolve(request(source: .system, id: id))
        XCTAssertEqual(result.originalSize, CGSize(width: 600, height: 1000))
        XCTAssertEqual(try XCTUnwrap(result.image).height, 300)
    }
    func testOrientationAppliedBeforeDimensionsAndThumbnailDecode() throws {
        let source = try image("portrait.tiff", width: 1200, height: 800, orientation: 6)
        let size = try XCTUnwrap(WallpaperRepository.dimensions(source))
        XCTAssertEqual(size.0, 800); XCTAssertEqual(size.1, 1200)
        let decoded = try XCTUnwrap(WallpaperRepository.decode(source, maximumPixels: 300))
        XCTAssertEqual(decoded.width, 200); XCTAssertEqual(decoded.height, 300)
    }
    func testCorruptLibraryAndUnsafeFileNamesDoNotReadOutsideStorage() throws {
        let repo = repository(); try FileManager.default.createDirectory(at: repo.directory, withIntermediateDirectories: true)
        let original = try image("outside.png")
        let invalid = WallpaperItem(id: "custom-good", name: "Bad", width: 1, height: 1, source: .custom,
                                    sourcePath: nil, cachedFile: "../outside.png", available: true)
        let data = try JSONEncoder().encode(WallpaperManifest(items: [invalid]))
        try data.write(to: repo.directory.appendingPathComponent("library.json"))
        XCTAssertTrue(repo.load().items.isEmpty)
        XCTAssertNil(repo.resolve(request(source: .custom, id: invalid.id)).image)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        for name in ["../outside.png", "a/b.png", "", ".", "..", "a\\b.png"] { XCTAssertNil(repo.localURL(name)) }
        try Data("bad".utf8).write(to: repo.directory.appendingPathComponent("library.json"))
        XCTAssertTrue(repo.load().items.isEmpty)
    }
    func testProtectionMaintainsTextAndButtonContrastEvenOverWhite() {
        // Worst case is white underneath the minimum-opacity dark backing.
        let opacity = OverlayBackground().normalized.protection
        let surface = SRGBColor(red: 1 - opacity, green: 1 - opacity, blue: 1 - opacity)
        let palette = OverlayPalette(background: .init(red: 0, green: 0, blue: 0), protected: true)
        XCTAssertFalse(palette.usesDarkText)
        let linear = pow((surface.red + 0.055) / 1.055, 2.4)
        XCTAssertGreaterThanOrEqual(1.05 / (linear + 0.05), 4.5)
        for prominent in [false, true] {
            let color = palette.buttonBackgroundComponents(prominent: prominent, highlighted: true)
            let luminance = color.red <= 0.04045 ? color.red / 12.92 : pow((color.red + 0.055) / 1.055, 2.4)
            XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5)
        }
    }

    func testFillDecodeDoesNotEnlargeAnAlreadySufficientSource() throws {
        for (width, height) in [(6000, 1500), (1500, 6000)] {
            let url = try image("wide-\(width).png", width: width, height: height)
            let viewport = width > height ? CGSize(width: 1920, height: 1080) : CGSize(width: 1080, height: 1920)
            let decoded = try XCTUnwrap(WallpaperRepository.decode(url, maximumPixels: 1920, viewport: viewport, fit: .fill))
            let rect = BackgroundGeometry.imageRect(image: CGSize(width: decoded.width, height: decoded.height),
                                                    viewport: viewport, fit: .fill, position: .init())
            XCTAssertLessThanOrEqual(rect.width / Double(decoded.width), 1.002)
            XCTAssertLessThanOrEqual(rect.height / Double(decoded.height), 1.002)
            let fit = try XCTUnwrap(WallpaperRepository.decode(url, maximumPixels: 1920, viewport: viewport, fit: .fit))
            XCTAssertLessThanOrEqual(Double(fit.width), viewport.width); XCTAssertLessThanOrEqual(Double(fit.height), viewport.height)
            let stretch = try XCTUnwrap(WallpaperRepository.decode(url, maximumPixels: 1920, viewport: viewport, fit: .stretch))
            XCTAssertGreaterThanOrEqual(Double(stretch.width), viewport.width * 0.998)
            XCTAssertGreaterThanOrEqual(Double(stretch.height), viewport.height * 0.998)
        }
    }

    func testDownloadedDescriptorResolvesThroughMobileAssetIdentity() throws {
        let directory = root.appendingPathComponent("system")
        _ = try image("system/Static.png")
        _ = try image("system/download.asset/AssetData/unrelated-file-name.png")
        let info: [String: Any] = ["MobileAssetProperties": ["mobileAssetID": "Downloaded", "isDynamic": false]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("download.asset/Info.plist"))
        for name in ["Static", "Downloaded"] {
            let properties: [String: Any] = ["isDynamic": false, "mobileAssetID": name]
            try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
                .write(to: directory.appendingPathComponent(name + ".madesktop"))
        }
        let manifest = try repository(roots: [directory]).synchronize(WallpaperManifest())
        XCTAssertEqual(manifest.items.count, 2)
        XCTAssertTrue(manifest.items.allSatisfy(\.available))
        XCTAssertEqual(Set(manifest.items.map(\.name)), ["Static", "Downloaded"])
    }

    func testOneFailedRefreshPreservesCacheAndPublishesHealthyEntries() throws {
        let source = try image("system/A.png")
        let repo = repository(roots: [source.deletingLastPathComponent()])
        var previous = try repo.synchronize(WallpaperManifest())
        let id = try XCTUnwrap(previous.items.first?.id)
        try repo.cacheSystem(id, in: &previous)
        _ = try image("system/B.png")
        let result = try repo.synchronize(previous) { count in
            if count == 2 {
                try! Data("resource changed during scan".utf8).write(to: source)
                try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: source.path)
            }
        }
        XCTAssertTrue(result.items.contains { $0.name == "B" && $0.available })
        XCTAssertTrue(result.items.contains { $0.id == id && $0.available })
        XCTAssertEqual(result.syncFailures?.count, 1)
        XCTAssertNotNil(repo.resolve(request(source: .system, id: id)).image)
        XCTAssertEqual(repo.load().items, result.items)
    }

    func testCorruptIndexIsBackedUpAndPrivateCopiesRemainManageable() throws {
        let repo = repository(); var manifest = WallpaperManifest()
        let old = try repo.importImage(image("original.png"), into: &manifest)
        let index = repo.directory.appendingPathComponent("library.json")
        let damaged = Data("invalid catalogue".utf8)
        try damaged.write(to: index)
        var recovered = repo.load()
        XCTAssertEqual(repo.loadErrorKey, "background.library_recovered")
        XCTAssertTrue(recovered.items.contains { $0.id == old.id })
        _ = try repo.importImage(image("new.png"), into: &recovered)
        XCTAssertEqual(repo.load().items.count, 2)
        let backups = try FileManager.default.contentsOfDirectory(at: repo.directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-damaged-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), damaged)
        XCTAssertNotNil(repo.resolve(request(source: .custom, id: old.id)).image)
        try repo.removeCustom(old.id, from: &recovered)
        XCTAssertFalse(repo.load().items.contains { $0.id == old.id })
    }

    func testDamageAfterLoadCannotSilentlyDiscardExistingPrivateCopies() throws {
        let repo = repository(); var manifest = WallpaperManifest()
        let old = try repo.importImage(image("original.png"), into: &manifest)
        let index = repo.directory.appendingPathComponent("library.json")
        let damaged = Data("invalid catalogue".utf8); try damaged.write(to: index)
        XCTAssertThrowsError(try repo.save(WallpaperManifest()))
        XCTAssertEqual(try Data(contentsOf: index), damaged)
        XCTAssertTrue(repo.load().items.contains { $0.id == old.id })
    }

    @MainActor func testRecoveryWarningSurvivesSubsequentSynchronization() async throws {
        let language = L10n.language
        defer { L10n.language = language }
        L10n.language = "en"
        let repo = repository(); var manifest = WallpaperManifest()
        _ = try repo.importImage(image("original.png"), into: &manifest)
        try Data("invalid catalogue".utf8).write(to: repo.directory.appendingPathComponent("library.json"))
        let library = WallpaperLibrary(directory: repo.directory, systemRoots: [])
        let warning = try XCTUnwrap(library.recoveryWarning)
        await library.synchronize()
        XCTAssertEqual(library.recoveryWarning, warning)
        XCTAssertEqual(library.items.count, 1)
        XCTAssertNil(library.error)
        L10n.language = "zh-Hans"
        XCTAssertNotEqual(library.recoveryWarning, warning)
    }

    @MainActor func testImageLoadingDoesNotWaitForTheMutationQueue() async throws {
        let repo = repository(); var manifest = WallpaperManifest()
        let item = try repo.importImage(image("original.png"), into: &manifest)
        let mutation = DispatchQueue(label: "wallpaper-test-blocked-mutation")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        mutation.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let library = WallpaperLibrary(directory: repo.directory, systemRoots: [], mutationQueue: mutation)
        let sync = Task { await library.synchronize() }
        await Task.yield()
        let decoded = expectation(description: "Image read completes while catalogue work is blocked")
        let imageRequest = request(source: .custom, id: item.id)
        let read = Task {
            let value = await library.resolve(imageRequest)
            XCTAssertNotNil(value.image); decoded.fulfill()
        }
        await fulfillment(of: [decoded], timeout: 1)
        release.signal()
        await read.value; await sync.value
    }

    func testOnlyAvailableSystemWallpapersAreVisible() {
        func item(_ id: String, source: WallpaperSource, available: Bool) -> WallpaperItem {
            WallpaperItem(id: id, name: id, width: 1000, height: 600, source: source,
                          sourcePath: nil, cachedFile: nil, available: available)
        }
        let manifest = WallpaperManifest(items: [item("ready", source: .system, available: true),
                                                 item("missing", source: .system, available: false),
                                                 item("custom", source: .custom, available: false)])
        XCTAssertEqual(manifest.visibleItems(source: .system).map(\.id), ["ready"])
        // Unavailable custom items remain manageable/removable.
        XCTAssertEqual(manifest.visibleItems(source: .custom).map(\.id), ["custom"])
    }

    func testDesktopDescriptorResolvesStaticAssetAndExplainsMissingResourceWithCachedFallback() throws {
        let source = try image("system/download.asset/AssetData/resource.png", width: 1600, height: 900)
        let system = root.appendingPathComponent("system")
        let info: [String: Any] = ["MobileAssetProperties": ["mobileAssetID": "Static", "isDynamic": false]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: system.appendingPathComponent("download.asset/Info.plist"))
        let descriptor = system.appendingPathComponent("Static.madesktop")
        try PropertyListSerialization.data(fromPropertyList: ["mobileAssetID": "Static", "isDynamic": false], format: .binary, options: 0)
            .write(to: descriptor)
        let repo = repository(roots: [system])
        let first = repo.resolve(request(source: .desktop, url: descriptor))
        XCTAssertNotNil(first.image); XCTAssertNil(first.failure); XCTAssertFalse(first.usedFallback)
        XCTAssertEqual(first.originalSize, CGSize(width: 1600, height: 900))
        try FileManager.default.removeItem(at: source)
        let fallback = repo.resolve(request(source: .desktop, url: descriptor, pixels: 1000))
        XCTAssertTrue(fallback.usedFallback); XCTAssertNotNil(fallback.image)
        XCTAssertEqual(fallback.failure?.kind, .notDownloaded)
        XCTAssertEqual(fallback.originalSize, CGSize(width: 1600, height: 900))
    }

    func testDynamicDesktopDescriptorDoesNotUseItsStaticLookingThumbnailOrFrame() throws {
        let image = try image("system/Still.png")
        let system = image.deletingLastPathComponent()
        let descriptor = system.appendingPathComponent("Still.madesktop")
        let properties: [String: Any] = ["mobileAssetID": "Still", "isDynamic": true, "thumbnailPath": image.path]
        try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0).write(to: descriptor)
        let result = repository(roots: [system]).resolve(request(source: .desktop, url: descriptor))
        XCTAssertNil(result.image); XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(result.failure?.kind, .dynamicResource)
        XCTAssertEqual(result.failure?.resource, "Still")
    }

    func testDesktopFailureReasonsDistinguishMissingFormatCorruptionAndMultipleFrames() throws {
        let repo = repository()
        XCTAssertEqual(repo.resolve(request(source: .desktop)).failure?.kind, .noDesktopURL)
        XCTAssertEqual(repo.resolve(request(source: .desktop, url: root.appendingPathComponent("absent.png"))).failure?.kind, .missingFile)
        let unsupported = root.appendingPathComponent("movie.mov")
        try Data("movie".utf8).write(to: unsupported)
        XCTAssertEqual(repo.resolve(request(source: .desktop, url: unsupported)).failure?.kind, .unsupportedType)
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data("invalid".utf8).write(to: corrupt)
        XCTAssertEqual(repo.resolve(request(source: .desktop, url: corrupt)).failure?.kind, .decodeFailed)
        let frames = try image("frames.tiff", frames: 2)
        XCTAssertEqual(repo.resolve(request(source: .desktop, url: frames)).failure?.kind, .multipleFrames)
        let otherDisplay = WallpaperImageRequest(source: .desktop, selectedID: nil, desktopURL: nil, screenID: "missing", maximumPixels: 300,
                                                 revision: 0, desktopFailure: .init(kind: .screenUnavailable))
        XCTAssertEqual(repo.resolve(otherDisplay).failure?.kind, .screenUnavailable)
    }
}
