import SwiftUI

/// Foundation parses Markdown blocks; SwiftUI Text renders their inline formatting.
/// Text alone does not lay out Markdown headings, lists, or code blocks.
struct ReleaseNotesMarkdown {
    struct Block: Identifiable {
        let id: Int
        var text: AttributedString
        let headingLevel: Int?
        let isCode: Bool
        let isDivider: Bool
        let listDepth: Int
        let quoteDepth: Int
        let marker: String?
    }

    let blocks: [Block]

    init(_ markdown: String) {
        let parsed = (try? AttributedString(markdown: markdown, options: .init(
            interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible
        ))) ?? AttributedString(markdown)
        var result: [Block] = []
        var seenItems = Set<Int>()
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .system(size: 13, design: .monospaced)
            }
            if let last = result.last, last.id == id {
                result[result.count - 1].text.append(text)
                continue
            }
            var heading: Int?
            var code = false, divider = false
            var depth = 0, quotes = 0
            var item: (id: Int, ordinal: Int)?
            var ordered = false
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .codeBlock: code = true
                case .thematicBreak: divider = true
                case .listItem(let ordinal):
                    if item == nil { item = (component.identity, ordinal) }
                case .orderedList:
                    if depth == 0 { ordered = true }
                    depth += 1
                case .unorderedList: depth += 1
                case .blockQuote: quotes += 1
                default: break
                }
            }
            var marker: String?
            if let item, seenItems.insert(item.id).inserted {
                marker = ordered ? "\(item.ordinal)." : "•"
            }
            result.append(Block(id: id, text: text, headingLevel: heading, isCode: code,
                                isDivider: divider, listDepth: depth, quoteDepth: quotes, marker: marker))
        }
        blocks = result
    }
}

struct ReleaseNotesMarkdownView: View {
    private let notes: ReleaseNotesMarkdown

    init(markdown: String) { notes = ReleaseNotesMarkdown(markdown) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(notes.blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    if block.listDepth > 0 {
                        Text(block.marker ?? "")
                            .frame(minWidth: 18, alignment: .trailing)
                    }
                    content(block)
                }
                .padding(.leading, block.quoteDepth > 0 ? 11 : 0)
                .overlay(alignment: .leading) {
                    if block.quoteDepth > 0 {
                        Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                    }
                }
                .padding(.leading, CGFloat(max(0, block.listDepth - 1) * 18 + max(0, block.quoteDepth - 1) * 10))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func content(_ block: ReleaseNotesMarkdown.Block) -> some View {
        if block.isDivider {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1).padding(.vertical, 4)
        } else if block.isCode {
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(size: 13, design: .monospaced))
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05))
            .cornerRadius(4)
        } else {
            Text(block.text)
                .font(block.headingLevel.map {
                    .system(size: CGFloat(max(14, 21 - $0 * 2)), weight: .semibold)
                } ?? .system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(block.headingLevel == nil ? [] : .isHeader)
        }
    }
}
