import AppKit
import Combine
import CryptoKit
import ImageIO
import TickRestCore
import UniformTypeIdentifiers

struct WallpaperItem: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var width: Int
    var height: Int
    var source: WallpaperSource
    var sourcePath: String?
    var cachedFile: String?
    var available: Bool
    var cachedSourceDate: Date? = nil
    var category: SystemWallpaperCategory? = nil
    var systemCategory: SystemWallpaperCategory {
        category ?? (sourcePath.map { URL(fileURLWithPath: $0).pathComponents.contains("Solid Colors") } == true ? .colors : .pictures)
    }
}

enum SystemWallpaperCategory: String, Codable, CaseIterable, Identifiable {
    case pictures, colors
    var id: String { rawValue }
    var title: String { L10n.text("background.category.\(rawValue)") }
}

struct WallpaperManifest: Codable {
    var items: [WallpaperItem] = []
    var lastSync: Date?
    var syncFailures: [String]? = nil
    func visibleItems(source: WallpaperSource) -> [WallpaperItem] {
        items.filter { $0.source == source && (source != .system || $0.available) }
    }
}

struct WallpaperImageRequest: Equatable {
    var source: WallpaperSource
    var selectedID: String?
    var desktopURL: URL?
    var screenID: String
    var maximumPixels: Int
    var revision: Int
    var viewport: CGSize? = nil
    var fit: WallpaperFit = .fill
    var desktopFailure: WallpaperReadFailure? = nil
    var cacheDesktopOriginal = true

    func hasSameContent(as other: Self) -> Bool {
        var candidate = self
        candidate.maximumPixels = other.maximumPixels
        candidate.viewport = other.viewport
        candidate.cacheDesktopOriginal = other.cacheDesktopOriginal
        return candidate == other
    }
}

struct WallpaperReadFailure: Error, Equatable {
    enum Kind: String {
        case noDesktopURL, screenUnavailable, dynamicResource, notDownloaded,
             missingFile, permissionDenied, unsupportedType, multipleFrames,
             tooLarge, decodeFailed, noSelection
    }
    let kind: Kind
    var resource: String = ""
    var message: String {
        let key = "background.failure.\(kind.rawValue)"
        return [.noDesktopURL, .screenUnavailable, .noSelection].contains(kind) ? L10n.text(key) : L10n.text(key, resource)
    }
}

struct ResolvedWallpaper {
    var image: CGImage?
    var usedFallback: Bool = false
    var originalSize: CGSize?
    var failure: WallpaperReadFailure? = nil
}

/// Catalogue mutations are serialized; image reads use committed snapshots and
/// atomically replaced files. Tests do not need AppKit windows.
final class WallpaperRepository: @unchecked Sendable {
    private let decodedImages: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 8
        return cache
    }()
    let directory: URL
    let systemRoots: [URL]
    private let files = FileManager.default
    private(set) var loadErrorKey: String?
    private var preservedIndex: Data?
    private static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "webp"]
    static func defaultSystemRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures"),
            URL(fileURLWithPath: "/Library/Desktop Pictures"),
            URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture"),
            URL(fileURLWithPath: "/Library/AssetsV2/com_apple_MobileAsset_DesktopPicture"),
            // System Settings stores downloaded wallpapers in the user's library on newer macOS versions.
            homeDirectory.appendingPathComponent("Library/Application Support/com.apple.mobileAssetDesktop", isDirectory: true)
        ]
    }
    init(directory: URL, systemRoots: [URL] = WallpaperRepository.defaultSystemRoots()) {
        self.directory = directory; self.systemRoots = systemRoots.map { $0.resolvingSymlinksInPath() }
    }

    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 160 && name.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0)
        } && name != "." && name != ".."
    }
    func localURL(_ name: String) -> URL? {
        Self.safeName(name) ? directory.appendingPathComponent(name) : nil
    }
    func load() -> WallpaperManifest {
        let index = directory.appendingPathComponent("library.json")
        guard files.fileExists(atPath: index.path) else { return WallpaperManifest() }
        guard let data = try? Data(contentsOf: index),
              var manifest = try? JSONDecoder().decode(WallpaperManifest.self, from: data) else {
            do {
                try preserveDamagedIndex()
                loadErrorKey = "background.library_recovered"
            } catch { loadErrorKey = "background.library_preserve_error" }
            return recoverPrivateCopies()
        }
        var seen = Set<String>()
        manifest.items = manifest.items.filter {
            Self.safeName($0.id) && seen.insert($0.id).inserted && $0.source != .desktop
                && ($0.cachedFile.map(Self.safeName) ?? true) && $0.width >= 0 && $0.height >= 0
        }
        return manifest
    }
    func save(_ manifest: WallpaperManifest) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("library.json")
        if files.fileExists(atPath: index.path) {
            let data = try Data(contentsOf: index)
            if (try? JSONDecoder().decode(WallpaperManifest.self, from: data)) == nil {
                try preserveDamagedIndex()
                // If damage occurred after loading, require recovery before a
                // mutation can discard private copies that are still on disk.
                let recoveredIDs = Set(recoverPrivateCopies().items.map(\.id))
                guard recoveredIDs.isSubset(of: Set(manifest.items.map(\.id))) else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
    }
    private func preserveDamagedIndex() throws {
        let index = directory.appendingPathComponent("library.json")
        let data = try Data(contentsOf: index)
        guard data != preservedIndex else { return }
        let backup = directory.appendingPathComponent("library-damaged-\(UUID().uuidString).json")
        try files.copyItem(at: index, to: backup)
        preservedIndex = data
    }
    private func recoverPrivateCopies() -> WallpaperManifest {
        let urls = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? []
        var recovered = WallpaperManifest(), seen = Set<String>()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = url.deletingPathExtension().lastPathComponent
            let source: WallpaperSource
            if id.hasPrefix("custom-"), UUID(uuidString: String(id.dropFirst(7))) != nil { source = .custom }
            else if id.hasPrefix("system-") { source = .system }
            else { continue }
            guard Self.safeName(id), Self.safeName(url.lastPathComponent),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let (width, height) = Self.dimensions(url), Self.decode(url, maximumPixels: 64) != nil,
                  seen.insert(id).inserted else { continue }
            recovered.items.append(WallpaperItem(id: id, name: url.lastPathComponent, width: width, height: height,
                                                source: source, sourcePath: nil, cachedFile: url.lastPathComponent, available: true))
        }
        return recovered
    }
    private static func source(_ url: URL) -> CGImageSource? {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { return nil }
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }
    static func dimensions(_ url: URL) -> (Int, Int)? {
        guard let source = source(url), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              Double(width) * Double(height) <= 300_000_000 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
    static func decode(_ url: URL, maximumPixels: Int, viewport: CGSize? = nil, fit: WallpaperFit = .fill) -> CGImage? {
        guard let dimensions = dimensions(url), let source = source(url) else { return nil }
        var limit = maximumPixels
        if let viewport {
            let original = CGSize(width: dimensions.0, height: dimensions.1)
            // Stretch needs enough pixels on both axes, like fill, even though
            // its final render intentionally changes the aspect ratio.
            let rect = BackgroundGeometry.imageRect(image: original, viewport: viewport, fit: fit == .stretch ? .fill : fit, position: .init())
            if rect.width > 0, rect.height > 0 {
                // Cover the viewport's shorter axis before cropping, rather
                // than downsampling its longer axis and then enlarging it.
                limit = Int(ceil(min(max(original.width, original.height), max(rect.width, rect.height))))
            }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, min(8192, limit)),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    private func writePNG(_ image: CGImage, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        defer { try? files.removeItem(at: temporary) }
        guard let output = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
        if files.fileExists(atPath: url.path) { _ = try files.replaceItemAt(url, withItemAt: temporary) }
        else { try files.moveItem(at: temporary, to: url) }
    }
    func thumbnail(_ item: WallpaperItem) -> CGImage? {
        guard let url = localURL("thumb-\(item.id).png") else { return nil }
        return Self.decode(url, maximumPixels: 360)
    }
    private func cacheThumbnail(_ item: WallpaperItem, from url: URL) throws {
        guard let image = Self.decode(url, maximumPixels: 360), let target = localURL("thumb-\(item.id).png") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try writePNG(image, to: target)
    }
    func importImage(_ url: URL, into manifest: inout WallpaperManifest) throws -> WallpaperItem {
        guard let (width, height) = Self.dimensions(url), Self.decode(url, maximumPixels: 360) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = "custom-\(UUID().uuidString)"
        let name = "\(id).\(url.pathExtension.lowercased())"
        let target = localURL(name)!
        var item = WallpaperItem(id: id, name: url.lastPathComponent, width: width, height: height,
                                 source: .custom, sourcePath: nil, cachedFile: name, available: true)
        do {
            try files.copyItem(at: url, to: target)
            // Read the private copy, so later moves/removals of the source are harmless.
            try cacheThumbnail(item, from: target)
            manifest.items.append(item)
            try save(manifest)
        } catch {
            manifest.items.removeAll { $0.id == id }
            try? files.removeItem(at: target)
            if let thumbnail = localURL("thumb-\(id).png") { try? files.removeItem(at: thumbnail) }
            throw error
        }
        item.available = true
        return item
    }
    func removeCustom(_ id: String, from manifest: inout WallpaperManifest) throws {
        guard let item = manifest.items.first(where: { $0.id == id && $0.source == .custom }) else { return }
        var next = manifest; next.items.removeAll { $0.id == id }
        // Commit the catalogue before deleting files; originals are never touched.
        try save(next); manifest = next
        if let name = item.cachedFile, let url = localURL(name) { try? files.removeItem(at: url) }
        if let url = localURL("thumb-\(id).png") { try? files.removeItem(at: url) }
    }
    private func systemID(_ url: URL) -> String {
        "system-" + SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
    private func ancestorDirectories(_ url: URL, root: URL) -> [URL] {
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        var result: [URL] = []
        var parent = url.deletingLastPathComponent()
        while true {
            // FileManager's enumerator can use /private/var while Foundation
            // canonicalizes the configured root to /var. Compare components
            // after resolving both, also excluding similarly prefixed siblings.
            let components = parent.resolvingSymlinksInPath().pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { break }
            result.append(parent); parent.deleteLastPathComponent()
        }
        return result
    }
    private func hasDynamicAncestor(_ url: URL, root: URL) -> Bool {
        for parent in ancestorDirectories(url, root: root) {
            let info = parent.appendingPathComponent("Info.plist")
            if let data = try? Data(contentsOf: info),
               let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let attributes = dictionary["MobileAssetProperties"] as? [String: Any] ?? dictionary
                if attributes["isDynamic"] as? Bool == true || attributes["isVideo"] as? Bool == true { return true }
            }
        }
        return false
    }
    private func assetIdentity(_ url: URL, root: URL) -> String {
        for parent in ancestorDirectories(url, root: root) {
            if let data = try? Data(contentsOf: parent.appendingPathComponent("Info.plist")),
               let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let properties = dictionary["MobileAssetProperties"] as? [String: Any] ?? dictionary
                for key in ["mobileAssetID", "AssetID", "assetID", "id"] {
                    if let id = properties[key] as? String, !id.isEmpty { return id }
                }
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }
    func synchronize(_ previous: WallpaperManifest, progress: (Int) -> Void = { _ in }) throws -> WallpaperManifest {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var system: [WallpaperItem] = []
        var seen = Set<String>()
        var descriptors: [(item: WallpaperItem, assetID: String)] = []
        var resources: [String: String] = [:]
        for root in systemRoots {
            guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values?.isRegularFile == true, !url.path.lowercased().contains("thumbnail"),
                      !hasDynamicAncestor(url, root: root) else { continue }
                let id = systemID(url)
                guard seen.insert(id).inserted else { continue }
                if url.pathExtension.lowercased() == "madesktop" {
                    // A descriptor is not a wallpaper. Only report non-dynamic entries with missing local resources.
                    guard let data = try? Data(contentsOf: url),
                          let properties = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          properties["isDynamic"] as? Bool != true, properties["isVideo"] as? Bool != true else { continue }
                    let name = url.deletingPathExtension().lastPathComponent
                    let item = WallpaperItem(id: id, name: name, width: 0, height: 0, source: .system,
                                             sourcePath: nil, cachedFile: nil, available: false)
                    descriptors.append((item, properties["mobileAssetID"] as? String ?? name))
                    continue
                }
                guard let (width, height) = Self.dimensions(url) else { continue }
                let old = previous.items.first { $0.id == id }
                var item = WallpaperItem(id: id, name: url.deletingPathExtension().lastPathComponent,
                                         width: width, height: height, source: .system, sourcePath: url.path,
                                         cachedFile: old?.cachedFile, available: true, cachedSourceDate: old?.cachedSourceDate,
                                         category: url.pathComponents.contains("Solid Colors") ? .colors : .pictures)
                do { try cacheThumbnail(item, from: url) }
                catch { item.available = false }
                system.append(item); progress(system.count)
                resources[assetIdentity(url, root: root)] = id
            }
        }
        // A descriptor and its downloaded resource are one logical wallpaper.
        // Match MobileAsset metadata even when the file name/path is unrelated.
        var descriptorAssets = Set<String>()
        for descriptor in descriptors where descriptorAssets.insert(descriptor.assetID).inserted {
            if let id = resources[descriptor.assetID], let index = system.firstIndex(where: { $0.id == id }) {
                system[index].name = descriptor.item.name
            } else { system.append(descriptor.item) }
        }
        // Keep cached selections even when the OS later removes their source.
        for old in previous.items where old.source == .system && !system.contains(where: { $0.id == old.id }) {
            if let name = old.cachedFile, let url = localURL(name), files.fileExists(atPath: url.path) {
                var cached = old; cached.sourcePath = nil; cached.available = true; system.append(cached)
            }
        }
        var result = previous
        result.syncFailures = []
        result.items = previous.items.filter { $0.source == .custom } + system.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // Refresh private copies of previously selected images when the system replaces a file.
        for item in result.items where item.source == .system && item.cachedFile != nil && item.sourcePath != nil {
            do { try cacheSystem(item.id, in: &result, persist: false) }
            catch {
                result.syncFailures?.append(item.name + ": " + error.localizedDescription)
                if let index = result.items.firstIndex(where: { $0.id == item.id }) { result.items[index].available = false }
                if let index = result.items.firstIndex(where: { $0.id == item.id }),
                   let file = item.cachedFile, let url = localURL(file), let size = Self.dimensions(url), Self.decode(url, maximumPixels: 64) != nil {
                    result.items[index].available = true
                    result.items[index].width = size.0; result.items[index].height = size.1
                }
            }
        }
        result.lastSync = Date(); try save(result)
        return result
    }
    func cacheSystem(_ id: String, in manifest: inout WallpaperManifest, persist: Bool = true) throws {
        guard let index = manifest.items.firstIndex(where: { $0.id == id && $0.source == .system }) else { throw CocoaError(.fileNoSuchFile) }
        let item = manifest.items[index]
        let sourceDate = item.sourcePath.flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        if let name = item.cachedFile, let url = localURL(name), Self.decode(url, maximumPixels: 64) != nil,
           item.sourcePath == nil || sourceDate == nil || item.cachedSourceDate == sourceDate {
            manifest.items[index].available = true
            return
        }
        guard let path = item.sourcePath else { throw CocoaError(.fileNoSuchFile) }
        let source = URL(fileURLWithPath: path)
        guard Self.dimensions(source) != nil, Self.decode(source, maximumPixels: 64) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let name = "\(id).\(source.pathExtension.lowercased())"
        let target = localURL(name)!
        // Replace stale/corrupt copies without losing a valid selection on a failed copy.
        let temporary = directory.appendingPathComponent(UUID().uuidString + "." + source.pathExtension.lowercased())
        defer { try? files.removeItem(at: temporary) }
        try files.copyItem(at: source, to: temporary)
        guard Self.decode(temporary, maximumPixels: 64) != nil else { throw CocoaError(.fileReadCorruptFile) }
        if files.fileExists(atPath: target.path) { _ = try files.replaceItemAt(target, withItemAt: temporary) }
        else { try files.moveItem(at: temporary, to: target) }
        manifest.items[index].cachedFile = name; manifest.items[index].cachedSourceDate = sourceDate
        if persist { try save(manifest) }
    }

    private static func fileFailure(_ url: URL, error: Error) -> WallpaperReadFailure {
        let code = (error as NSError).code
        let kind: WallpaperReadFailure.Kind
        if code == CocoaError.fileReadNoPermission.rawValue { kind = .permissionDenied }
        else if code == CocoaError.fileReadNoSuchFile.rawValue || code == CocoaError.fileNoSuchFile.rawValue { kind = .missingFile }
        else { kind = .decodeFailed }
        return WallpaperReadFailure(kind: kind, resource: url.lastPathComponent)
    }
    private static func staticImageFailure(_ url: URL) -> WallpaperReadFailure? {
        let name = url.lastPathComponent
        guard url.isFileURL else { return .init(kind: .unsupportedType, resource: name) }
        do { _ = try url.resourceValues(forKeys: [.isRegularFileKey]) }
        catch { return fileFailure(url, error: error) }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return .init(kind: .permissionDenied, resource: name) }
        guard extensions.contains(url.pathExtension.lowercased()) else { return .init(kind: .unsupportedType, resource: name) }
        guard let source = source(url) else { return .init(kind: .decodeFailed, resource: name) }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .init(kind: .decodeFailed, resource: name) }
        guard count == 1 else { return .init(kind: .multipleFrames, resource: name) }
        guard dimensions(url) != nil else { return .init(kind: .tooLarge, resource: name) }
        return nil
    }
    /// NSWorkspace may return a MobileAsset descriptor rather than a raster.
    /// Resolve only resources confirmed to be static; never use thumbnails or
    /// choose an arbitrary frame from a dynamic/video wallpaper package.
    func staticDesktopResource(_ url: URL) -> Result<URL, WallpaperReadFailure> {
        guard url.isFileURL else { return .failure(.init(kind: .unsupportedType, resource: url.lastPathComponent)) }
        guard url.pathExtension.lowercased() == "madesktop" else {
            if let failure = Self.staticImageFailure(url) { return .failure(failure) }
            return .success(url)
        }
        let properties: [String: Any]
        do {
            let data = try Data(contentsOf: url)
            guard let decoded = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                return .failure(.init(kind: .decodeFailed, resource: url.lastPathComponent))
            }
            properties = decoded
        } catch { return .failure(Self.fileFailure(url, error: error)) }
        if properties["isDynamic"] as? Bool == true || properties["isVideo"] as? Bool == true {
            return .failure(.init(kind: .dynamicResource, resource: url.deletingPathExtension().lastPathComponent))
        }
        let id = properties["mobileAssetID"] as? String ?? url.deletingPathExtension().lastPathComponent
        var candidates: [(url: URL, area: Double)] = []
        // Include images beside a descriptor, useful for older macOS layouts.
        let roots = Set(systemRoots + [url.deletingLastPathComponent().resolvingSymlinksInPath()])
        for root in roots {
            guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values?.isRegularFile == true, Self.extensions.contains(file.pathExtension.lowercased()),
                      !file.path.lowercased().contains("thumbnail"), !hasDynamicAncestor(file, root: root),
                      assetIdentity(file, root: root) == id, Self.staticImageFailure(file) == nil,
                      let dimensions = Self.dimensions(file) else { continue }
                candidates.append((file, Double(dimensions.0) * Double(dimensions.1)))
            }
        }
        if let resource = candidates.sorted(by: { a, b in
            a.area == b.area ? a.url.path < b.url.path : a.area > b.area
        }).first { return .success(resource.url) }
        return .failure(.init(kind: .notDownloaded, resource: url.deletingPathExtension().lastPathComponent))
    }
    private func decodedImage(_ url: URL, request: WallpaperImageRequest) -> CGImage? {
        // Include the file version and render size: a thumbnail must never serve
        // a full-screen request, and replacing the desktop must invalidate it.
        guard let attributes = try? files.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            return Self.decode(url, maximumPixels: request.maximumPixels, viewport: request.viewport, fit: request.fit)
        }
        let key = "\(url.path.utf8.count):\(url.path)|\(modified.timeIntervalSince1970)|\(size)|\(attributes[.systemFileNumber] ?? "")|\(request.revision)|\(request.maximumPixels)|\(request.viewport?.width ?? 0)|\(request.viewport?.height ?? 0)|\(request.fit.rawValue)" as NSString
        if let image = decodedImages.object(forKey: key) { return image }
        guard let image = Self.decode(url, maximumPixels: request.maximumPixels, viewport: request.viewport, fit: request.fit) else { return nil }
        let cost = image.bytesPerRow * image.height
        if cost <= decodedImages.totalCostLimit { decodedImages.setObject(image, forKey: key, cost: cost) }
        return image
    }
    func resolve(_ request: WallpaperImageRequest, manifest snapshot: WallpaperManifest? = nil) -> ResolvedWallpaper {
        if request.source != .desktop {
            let manifest = snapshot ?? load()
            guard let item = manifest.items.first(where: { $0.id == request.selectedID && $0.source == request.source }) else {
                return ResolvedWallpaper(image: nil, usedFallback: true, failure: .init(kind: .noSelection))
            }
            let cached = item.cachedFile.flatMap(localURL)
            let source = item.sourcePath.map { URL(fileURLWithPath: $0) }
            for url in [cached, source].compactMap({ $0 }) {
                if let image = decodedImage(url, request: request) {
                    let dimensions = Self.dimensions(url)
                    return ResolvedWallpaper(image: image,
                                             originalSize: dimensions.map { CGSize(width: $0.0, height: $0.1) })
                }
            }
            return ResolvedWallpaper(image: nil, usedFallback: true,
                                     failure: source.map { Self.staticImageFailure($0) ?? .init(kind: .decodeFailed, resource: item.name) }
                                        ?? .init(kind: .missingFile, resource: item.name))
        }
        let cachePrefix = "desktop-\(request.screenID)"
        let cachedSources = Self.extensions.sorted().compactMap { localURL("\(cachePrefix).\($0)") }
        var failure = request.desktopFailure ?? WallpaperReadFailure(kind: .noDesktopURL)
        var resource: URL?
        if let url = request.desktopURL {
            switch staticDesktopResource(url) {
            case .success(let source): resource = source
            case .failure(let reason): failure = reason
            }
        }
        if let source = resource, let image = decodedImage(source, request: request) {
            if request.cacheDesktopOriginal, let cache = localURL("\(cachePrefix).\(source.pathExtension.lowercased())"), source.standardizedFileURL != cache.standardizedFileURL {
                try? files.createDirectory(at: directory, withIntermediateDirectories: true)
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
                defer { try? files.removeItem(at: temporary) }
                // Preserve the original resolution; a small settings preview must not downgrade the fallback.
                do {
                    let original = try files.attributesOfItem(atPath: source.path)
                    let existing = try? files.attributesOfItem(atPath: cache.path)
                    let unchanged = existing?[.modificationDate] as? Date == original[.modificationDate] as? Date
                        && existing?[.size] as? NSNumber == original[.size] as? NSNumber
                    if !unchanged {
                        try files.copyItem(at: source, to: temporary)
                        if files.fileExists(atPath: cache.path) { _ = try files.replaceItemAt(cache, withItemAt: temporary) }
                        else { try files.moveItem(at: temporary, to: cache) }
                        for old in cachedSources where old != cache { try? files.removeItem(at: old) }
                    }
                } catch {
                    // Display the readable source even when caching fails.
                }
            }
            let dimensions = Self.dimensions(source)
            return ResolvedWallpaper(image: image, originalSize: dimensions.map { CGSize(width: $0.0, height: $0.1) })
        }
        if let resource { failure = .init(kind: .decodeFailed, resource: resource.lastPathComponent) }
        for cache in cachedSources {
            if let image = decodedImage(cache, request: request) {
                let dimensions = Self.dimensions(cache)
                return ResolvedWallpaper(image: image, usedFallback: true,
                                         originalSize: dimensions.map { CGSize(width: $0.0, height: $0.1) }, failure: failure)
            }
        }
        return ResolvedWallpaper(image: nil, usedFallback: true, failure: failure)
    }
}

final class WallpaperLibrary: ObservableObject {
    @Published private(set) var manifest: WallpaperManifest
    @Published private(set) var busy = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var error: String?
    private let recoveryWarningKey: String?
    var recoveryWarning: String? { recoveryWarningKey.map { L10n.text($0) } }
    @Published private(set) var revision = 0
    private let repository: WallpaperRepository
    private let queue: DispatchQueue
    private let imageQueue: DispatchQueue
    // Keep a few recent surfaces available for an immediate first frame. The
    // CGImages are shared with the repository cache, rather than copied.
    private var recentImages: [(request: WallpaperImageRequest, result: ResolvedWallpaper)] = []
    init(directory: URL, systemRoots: [URL]? = nil,
         mutationQueue: DispatchQueue = DispatchQueue(label: "tickrest.wallpaper", qos: .utility),
         imageQueue: DispatchQueue = DispatchQueue(label: "tickrest.wallpaper-images", qos: .userInitiated)) {
        queue = mutationQueue
        self.imageQueue = imageQueue
        repository = systemRoots.map { WallpaperRepository(directory: directory, systemRoots: $0) } ?? WallpaperRepository(directory: directory)
        manifest = repository.load()
        recoveryWarningKey = repository.loadErrorKey
    }
    var items: [WallpaperItem] { manifest.items }
    func thumbnailURL(_ id: String) -> URL? { repository.localURL("thumb-\(id).png") }
    private func work<T>(_ body: @escaping (WallpaperRepository) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [repository] in
                do { continuation.resume(returning: try body(repository)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    @MainActor func synchronize() async {
        guard !busy else { return }; busy = true; scannedCount = 0; error = nil
        let previous = manifest
        do {
            manifest = try await work { repository in
                try repository.synchronize(previous) { count in
                    DispatchQueue.main.async { self.scannedCount = count }
                }
            }
            revision += 1
            if let failures = manifest.syncFailures, !failures.isEmpty {
                error = L10n.text("background.sync_partial_error", failures.joined(separator: "\n"))
            }
        } catch { self.error = L10n.text("background.sync_error", error.localizedDescription) }
        busy = false
    }
    @MainActor func importImages(_ urls: [URL]) async -> String? {
        guard !busy else { return nil }; busy = true; error = nil
        let previous = manifest
        do {
            let result = try await work { repository -> (WallpaperManifest, String?, [String]) in
                var next = previous, selected: String?, failures: [String] = []
                for url in urls {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do { selected = try repository.importImage(url, into: &next).id }
                    catch { failures.append(url.lastPathComponent + ": " + error.localizedDescription) }
                }
                return (next, selected, failures)
            }
            manifest = result.0; revision += 1
            if !result.2.isEmpty { error = L10n.text("background.import_error", result.2.joined(separator: "\n")) }
            busy = false; return result.1
        } catch { self.error = L10n.text("background.import_error", error.localizedDescription); busy = false; return nil }
    }
    @MainActor func selectSystem(_ id: String) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        let previous = manifest
        do {
            manifest = try await work { repository in
                var next = previous; try repository.cacheSystem(id, in: &next); return next
            }
            revision += 1; busy = false; return true
        } catch { self.error = L10n.text("background.read_error", error.localizedDescription); busy = false; return false }
    }
    @MainActor func remove(_ id: String) async -> Bool {
        guard !busy else { return false }; busy = true; error = nil
        let previous = manifest
        do {
            manifest = try await work { repository in
                var next = previous; try repository.removeCustom(id, from: &next); return next
            }
            revision += 1; busy = false; return true
        } catch { self.error = L10n.text("background.remove_error", error.localizedDescription); busy = false; return false }
    }
    @MainActor func cachedResolution(_ request: WallpaperImageRequest) -> (request: WallpaperImageRequest, result: ResolvedWallpaper)? {
        recentImages.filter { $0.request.hasSameContent(as: request) }
            .max { $0.request.maximumPixels < $1.request.maximumPixels }
    }
    @MainActor func resolve(_ request: WallpaperImageRequest) async -> ResolvedWallpaper {
        // Read a committed immutable catalogue. Scanning/importing can proceed
        // on the mutation queue without delaying a reminder's image decode.
        let snapshot = manifest
        let result: ResolvedWallpaper = await withCheckedContinuation { continuation in
            imageQueue.async { [repository] in
                continuation.resume(returning: repository.resolve(request, manifest: snapshot))
            }
        }
        if result.image != nil, !Task.isCancelled {
            recentImages.removeAll { $0.request == request }
            recentImages.append((request, result))
            while recentImages.count > 8 || recentImages.reduce(0, { $0 + ($1.result.image.map { $0.bytesPerRow * $0.height } ?? 0) }) > 96 * 1024 * 1024 {
                recentImages.removeFirst()
            }
        }
        return result
    }
}
