import AppKit
import SwiftUI
import XCTest
import TickRestCore
@testable import TickRestApp

extension AppIntegrationTests {
    func testVisiblePickerSelectionsRefreshAfterLiveLanguageChange() async throws {
        try await withFixture { model, _, _ in
            let navigation = SettingsNavigation(); navigation.page = .appearance
            let view = NSHostingView(rootView: SettingsView(model: model, navigation: navigation))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 890, height: 708),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = view; window.orderFrontRegardless()
            defer { window.close() }
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "ko"] {
                model.update { $0.language = language }
                try await Task.sleep(nanoseconds: 300_000_000)
                view.layoutSubtreeIfNeeded()
                for key in ["style.gentle", "reminder.size.normal", "start_mode.automatic", "sound.glass"] {
                    XCTAssertTrue(self.containsText(L10n.text(key), in: view),
                                  "Live \(language) picker selection must show \(L10n.text(key)) instead of its old language")
                }
            }
        }
    }

}
