import Foundation
import Testing
@testable import rookCore

/// These tests pin what Foundation's own CommonMark+GFM parser actually hands us — including its ceilings —
/// so a stdlib change that quietly drops an intent (or starts recognizing one we documented as unsupported)
/// fails here instead of in the preview panel.
struct MarkdownTests {
    /// Sugar: the kinds of every block, in source order.
    private func kinds(_ markdown: String) -> [MarkdownBlock.Kind] {
        MarkdownDocument.blocks(from: markdown).map(\.kind)
    }

    private func plain(_ block: MarkdownBlock) -> String {
        String(block.text.characters)
    }

    @Test func headersCarryTheirLevel() {
        #expect(kinds("# one\n\n## two\n\n### three") == [
            .header(level: 1), .header(level: 2), .header(level: 3),
        ])
        #expect(MarkdownDocument.blocks(from: "# one").map { String($0.text.characters) } == ["one"])
    }

    @Test func paragraphKeepsItsInlineLink() throws {
        let blocks = MarkdownDocument.blocks(from: "see [the docs](https://rook.app/docs) now")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .paragraph)
        #expect(plain(blocks[0]) == "see the docs now")
        // the inline `.link` attribute survives the block grouping — the view renders it, it is not re-parsed
        let links = blocks[0].text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://rook.app/docs")!])
    }

    @Test func nestedBulletsCarryDepthAndNoOrdinal() {
        let blocks = MarkdownDocument.blocks(from: "- one\n- two\n  - nested\n")
        #expect(blocks.map(\.kind) == [
            .listItem(ordinal: nil, depth: 1),
            .listItem(ordinal: nil, depth: 1),
            .listItem(ordinal: nil, depth: 2),
        ])
        #expect(blocks.map(plain) == ["one", "two", "nested"])
    }

    @Test func orderedListCarriesItsOrdinal() {
        // Foundation numbers BULLET items too, so the ordinal is only surfaced when the item's own list is
        // ordered — that is the whole point of the `ordinal: nil` bullet case above.
        #expect(kinds("1. first\n2. second\n") == [
            .listItem(ordinal: 1, depth: 1),
            .listItem(ordinal: 2, depth: 1),
        ])
    }

    @Test func fencedCodeBlockKeepsItsLanguageAndDropsTheFenceNewline() {
        let blocks = MarkdownDocument.blocks(from: "```swift\nlet x = 1\n```")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .codeBlock(language: "swift"))
        #expect(plain(blocks[0]) == "let x = 1")   // the trailing newline that closed the fence is presentation
    }

    @Test func fenceWithoutALanguageHasNoneAndKeepsInteriorNewlines() {
        let blocks = MarkdownDocument.blocks(from: "```\na\nb\n```")
        #expect(blocks[0].kind == .codeBlock(language: nil))
        #expect(plain(blocks[0]) == "a\nb")
    }

    @Test func blockQuoteCarriesItsDepth() {
        let blocks = MarkdownDocument.blocks(from: "> quoted")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .blockQuote(depth: 1))
        #expect(plain(blocks[0]) == "quoted")
    }

    @Test func thematicBreakHasNoText() {
        let blocks = MarkdownDocument.blocks(from: "a\n\n---\n\nb")
        #expect(blocks.map(\.kind) == [.paragraph, .thematicBreak, .paragraph])
        // Foundation emits a literal `⸻` glyph for the rule; we strip it, the view draws its own divider
        #expect(plain(blocks[1]).isEmpty)
    }

    @Test func gfmTableGroupsCellsIntoRows() throws {
        let markdown = """
        | A | B |
        | - | - |
        | 1 | 2 |
        | 3 | 4 |
        """
        let blocks = MarkdownDocument.blocks(from: markdown)
        #expect(blocks.count == 1)
        guard case .table(let rows, let hasHeader) = blocks[0].kind else {
            Issue.record("expected a table, got \(blocks[0].kind)")
            return
        }
        #expect(hasHeader)
        #expect(rows.count == 3)                                  // header + 2 body rows
        #expect(rows.allSatisfy { $0.count == 2 })
        #expect(rows.map { $0.map { String($0.characters) } } == [["A", "B"], ["1", "2"], ["3", "4"]])
        #expect(plain(blocks[0]).isEmpty)                         // the text lives in the cells
    }

    @Test func tableKeepsItsPlaceBetweenNeighbours() {
        // the splice is the one non-trivial bit of the grouping: a table arrives as N separate cell groups and
        // still has to land as ONE block, in the right slot.
        let markdown = """
        before

        | A |
        | - |
        | 1 |

        after

        | B |
        | - |
        | 2 |

        end
        """
        let blocks = MarkdownDocument.blocks(from: markdown)
        #expect(blocks.count == 5)
        #expect(blocks.map(plain) == ["before", "", "after", "", "end"])
        #expect(blocks.map { if case .table = $0.kind { return true } else { return false } }
                == [false, true, false, true, false])
        #expect(Set(blocks.map(\.id)).count == 5)                 // ids stay unique across the splice
    }

    @Test func checkboxItemStaysALiteral() {
        // ceiling, documented on purpose: Foundation has no task-list intent, so `- [ ] todo` is an ordinary
        // list item whose text still carries the marker. Upgrading means a real cmark-gfm dependency.
        let blocks = MarkdownDocument.blocks(from: "- [ ] todo")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .listItem(ordinal: nil, depth: 1))
        #expect(plain(blocks[0]) == "[ ] todo")
    }

    @Test func emptyInputYieldsNoBlocks() {
        #expect(MarkdownDocument.blocks(from: "").isEmpty)
        #expect(MarkdownDocument.blocks(from: "\n\n").isEmpty)   // whitespace-only is nothing to render, too
    }

    @Test func idsAreUniquePerBlock() {
        let blocks = MarkdownDocument.blocks(from: "# h\n\npara\n\n- a\n- b\n\n> q\n")
        #expect(blocks.count == 5)
        #expect(Set(blocks.map(\.id)).count == blocks.count)
    }
}
