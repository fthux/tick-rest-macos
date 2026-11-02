import AppKit
import SwiftUI
import XCTest
@testable import TickRestApp

final class ReleaseNotesMarkdownTests: XCTestCase {
    func testHeadingsAndParagraphsKeepTheirStructure() {
        let notes = ReleaseNotesMarkdown("# 新版本\n\n## Improvements\n\nFirst paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(notes.blocks.map { String($0.text.characters) },
                       ["新版本", "Improvements", "First paragraph.", "Second paragraph."])
        XCTAssertEqual(notes.blocks.map(\.headingLevel), [1, 2, nil, nil])
        XCTAssertTrue(notes.blocks.allSatisfy { $0.marker == nil })
    }

    func testInlineFormattingAndLinksSurviveParsing() throws {
        let text = try XCTUnwrap(ReleaseNotesMarkdown(
            "**Bold** *italic* ~~removed~~ `code` [Details](https://example.com/notes)"
        ).blocks.first?.text)
        XCTAssertEqual(String(text.characters), "Bold italic removed code Details")
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        XCTAssertTrue(text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && $0.font != nil })
        XCTAssertTrue(text.runs.contains { $0.link == URL(string: "https://example.com/notes") })
    }

    func testNestedListsAndContinuationParagraphs() {
        let notes = ReleaseNotesMarkdown("""
        - First

          3. Nested

          Continuation
        - Second

        3. Third
        4. Fourth
        """)
        XCTAssertEqual(notes.blocks.map(\.marker), ["•", "3.", nil, "•", "3.", "4."])
        XCTAssertEqual(notes.blocks.map(\.listDepth), [1, 2, 1, 1, 1, 1])
    }

    func testCodeBlocksKeepLiteralMarkdownAndLineBreaks() throws {
        let block = try XCTUnwrap(ReleaseNotesMarkdown("```sh\n# comment\necho '**literal**'\n```").blocks.first)
        XCTAssertTrue(block.isCode)
        XCTAssertNil(block.headingLevel)
        XCTAssertEqual(String(block.text.characters), "# comment\necho '**literal**'\n")
    }

    func testQuotesDividersPlainTextAndEmptyNotes() {
        let notes = ReleaseNotesMarkdown("> Quote\n\n---\n\nPlain text: version 1.0.2")
        XCTAssertEqual(notes.blocks.count, 3)
        XCTAssertEqual(notes.blocks[0].quoteDepth, 1)
        XCTAssertTrue(notes.blocks[1].isDivider)
        XCTAssertEqual(String(notes.blocks[2].text.characters), "Plain text: version 1.0.2")
        XCTAssertTrue(ReleaseNotesMarkdown(" \n\n").blocks.isEmpty)
    }

    @MainActor func testMarkdownLayoutFitsAndRendersInLightAndDarkAppearance() throws {
        _ = NSApplication.shared
        let markdown = """
        ## 新功能 / What's New

        - 支持 **Markdown** 更新说明和 *强调*。
        - 打开 [版本详情](https://github.com/fthux/tick-rest-macos/releases)。
          - 嵌套列表与 `inline code`

        ### 修复 / Fixes

        1. 保留有序列表。
        2. 普通段落不会强制添加圆点。

        > 设置和统计数据会保留。

        ```sh
        # This is a code comment
        echo "Tick Rest"
        ```

        ---

        感谢使用。Thank you!
        """
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/release-notes-markdown")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            let view = NSHostingView(rootView: ScrollView {
                ReleaseNotesMarkdownView(markdown: markdown).textSelection(.enabled).padding(20)
            }.frame(width: 440, height: 560)
                .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, scheme))
            XCTAssertEqual(view.fittingSize, NSSize(width: 440, height: 560))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("\(name).png"))
            window.close()
        }
    }
}
