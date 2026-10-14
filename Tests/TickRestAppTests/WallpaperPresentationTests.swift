import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    @MainActor private func selectRedWallpaper(model: AppController, directory: URL) async throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 6400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let url = directory.appendingPathComponent("red.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let imported = await model.wallpapers.importImages([url])
        let id = try XCTUnwrap(imported)
        model.update {
            $0.style = .overlay; $0.displayScope = .all
            $0.overlayBackground.kind = .wallpaper
            $0.overlayBackground.wallpaper.source = .custom
            $0.overlayBackground.wallpaper.customID = id
        }
    }

    func testWallpaperIsPresentOnFirstVisibleFrameForPreviewAndRest() async throws {
        try await withFixture { model, windows, directory in
            try await self.selectRedWallpaper(model: model, directory: directory)
            for preview in [true, false] {
                if preview { windows.preview() }
                else { model.action { $0.startNow(.short, now: Date()) } }
                XCTAssertTrue(self.panels.isEmpty, "Do not expose the fallback while preparing the wallpaper")
                let deadline = Date().addingTimeInterval(3)
                while self.panels.isEmpty && Date() < deadline {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
                let panels = self.panels
                XCTAssertEqual(panels.count, NSScreen.screens.count)
                for panel in panels {
                    let view = try XCTUnwrap(panel.contentView)
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
                    // Display profiles can add green/blue to pure red. Channel
                    // dominance still distinguishes the image from the green fallback.
                    XCTAssertGreaterThan(pixel.redComponent, max(pixel.greenComponent, pixel.blueComponent) + 0.4,
                        "The first visible frame must contain the selected image")
                }
                if preview { windows.hide() }
                else { model.action { $0.finish(now: Date()) } }
                XCTAssertTrue(self.panels.isEmpty)
            }
        }
    }

    func testCancellingWallpaperPreparationCannotReopenPreviewOrRest() async throws {
        try await withFixture { model, windows, directory in
            try await self.selectRedWallpaper(model: model, directory: directory)
            windows.preview()
            windows.hide()
            model.action { $0.startNow(.short, now: Date()) }
            model.action { $0.finish(now: Date()) }
            // Let both cancelled async preparations resume in the native run loop.
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(self.panels.isEmpty)
        }
    }

    func testCachedPreviewPresentsFullscreenWhileHDQueueIsBlocked() async throws {
        try await withFixture { model, windows, directory in
            let queue = DispatchQueue(label: "test.wallpaper-upgrade")
            model.wallpapers = WallpaperLibrary(directory: directory.appendingPathComponent("progressive-library"),
                systemRoots: [], imageQueue: queue)
            try await self.selectRedWallpaper(model: model, directory: directory)
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let request = PreparedWallpaper.request(wallpaper: model.settings.overlayBackground.wallpaper, screen: screen,
                maximumPixels: 1200, revision: model.wallpapers.revision)
            let preview = await PreparedWallpaper.load(request: request, screen: screen, library: model.wallpapers)
            XCTAssertNotNil(preview.result.image)
            queue.suspend()
            var suspended = true
            defer { if suspended { queue.resume() } }
            windows.preview(screen: screen)
            let deadline = Date().addingTimeInterval(1)
            while self.panels.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
            let panel = try XCTUnwrap(self.panels.first, "Cached preview must show without waiting for the HD queue")
            let hosting = try XCTUnwrap(panel.contentView as? NSHostingView<OverlayView>)
            let seed = try XCTUnwrap(hosting.rootView.preparedWallpaper)
            XCTAssertTrue(seed.result.image === preview.result.image)
            XCTAssertTrue(seed.needsUpgrade)
            windows.hide()
            queue.resume(); suspended = false
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertTrue(self.panels.isEmpty, "Cancelled HD completion must not reopen the window")
        }
    }

    func testLowResolutionSurfaceUpgradesAndKeepsImageIfHDReadFails() async throws {
        try await withFixture { model, _, directory in
            let queue = DispatchQueue(label: "test.wallpaper-surface-upgrade")
            model.wallpapers = WallpaperLibrary(directory: directory.appendingPathComponent("progressive-library"),
                systemRoots: [], imageQueue: queue)
            try await self.selectRedWallpaper(model: model, directory: directory)
            let wallpaper = model.settings.overlayBackground.wallpaper
            // A virtual 1920x1080 surface makes the low/high size difference
            // independent of which physical screens are connected to the test host.
            let request = PreparedWallpaper.request(wallpaper: wallpaper, screen: nil, maximumPixels: nil,
                revision: model.wallpapers.revision)
            let seed = await PreparedWallpaper.loadInitial(request: request, screen: nil, library: model.wallpapers)
            XCTAssertTrue(seed.needsUpgrade)
            XCTAssertEqual(seed.result.image?.width, 1200)
            for fails in [false, true] {
                queue.suspend()
                var suspended = true
                defer { if suspended { queue.resume() } }
                if fails {
                    let item = try XCTUnwrap(model.wallpapers.items.first)
                    try FileManager.default.removeItem(at: directory.appendingPathComponent("progressive-library/\(item.cachedFile!)"))
                }
                var results: [ResolvedWallpaper] = []
                let hosting = NSHostingView(rootView: WallpaperSurface(library: model.wallpapers, wallpaper: wallpaper,
                    screen: nil, onResolved: { results.append($0) }, prepared: seed))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting
                defer { window.close() }
                window.orderFrontRegardless()
                let firstDeadline = Date().addingTimeInterval(1)
                while results.isEmpty && Date() < firstDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
                XCTAssertEqual(results.count, 1)
                XCTAssertEqual(results.first?.image?.width, 1200)
                queue.resume(); suspended = false
                let finalDeadline = Date().addingTimeInterval(2)
                while results.count < 2 && Date() < finalDeadline { try await Task.sleep(nanoseconds: 1_000_000) }
                XCTAssertEqual(results.count, 2)
                if fails { XCTAssertNil(results.last?.image) }
                else { XCTAssertEqual(results.last?.image?.width, 1600) }
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let pixel = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(pixel.redComponent, max(pixel.greenComponent, pixel.blueComponent) + 0.4,
                    "Upgrade failure must preserve the visible low-resolution image")
            }
        }
    }

    func testFirstFrameDecodeIsBoundedForTallWallpaperOnWideScreen() async throws {
        try await withFixture { model, _, directory in
            try await self.selectRedWallpaper(model: model, directory: directory)
            let item = try XCTUnwrap(model.wallpapers.items.first)
            let url = directory.appendingPathComponent("Wallpapers/\(item.cachedFile!)")
            let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 4000, bitsPerComponent: 8, bytesPerRow: 2400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let request = PreparedWallpaper.request(wallpaper: model.settings.overlayBackground.wallpaper, screen: nil,
                maximumPixels: nil, revision: model.wallpapers.revision)
            let seed = await PreparedWallpaper.loadInitial(request: request, screen: nil, library: model.wallpapers)
            let image = try XCTUnwrap(seed.result.image)
            XCTAssertLessThanOrEqual(max(image.width, image.height), 1200)
            XCTAssertEqual(seed.result.originalSize, CGSize(width: 600, height: 4000))
            XCTAssertTrue(seed.needsUpgrade)
        }
    }

    func testUnavailableWallpaperStillPresentsFallbackAndCanClose() async throws {
        try await withFixture { model, windows, _ in
            model.update {
                $0.style = .overlay; $0.displayScope = .current
                $0.overlayBackground.kind = .wallpaper
                $0.overlayBackground.wallpaper.source = .custom
                $0.overlayBackground.wallpaper.customID = "missing-image"
            }
            windows.preview()
            let deadline = Date().addingTimeInterval(3)
            while self.panels.isEmpty && Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            XCTAssertEqual(self.panels.count, 1)
            windows.hide()
            XCTAssertTrue(self.panels.isEmpty)
        }
    }
}
