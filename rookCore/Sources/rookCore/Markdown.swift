import Foundation

/// One rendered block of a Markdown document — a paragraph, header, list item, fenced code block, block
/// quote, thematic break, or GFM table. The view draws one of these per row; nothing about HOW it is drawn
/// (fonts, insets, colors) lives here, which is what keeps the parser host-free.
public struct MarkdownBlock: Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case header(level: Int)
        /// `ordinal == nil` means a BULLET. Foundation hands every list item an ordinal (bullets are numbered
        /// 1, 2, 3 too), so the ordinal is only meaningful when the item's own list is an `orderedList`.
        /// `depth` is 1-based: a top-level item is 1, an item nested inside it is 2.
        case listItem(ordinal: Int?, depth: Int)
        case codeBlock(language: String?)
        case blockQuote(depth: Int)
        case thematicBreak
        /// Cells already grouped by row; `rows.first` is the header row when `hasHeader`.
        case table(rows: [[AttributedString]], hasHeader: Bool)
    }

    /// The identity of the block's INNERMOST presentation intent (Foundation's own per-block counter), or the
    /// TABLE's identity for `.table`. Unique per block within one parse, and stable across re-parses of the
    /// same text — which is exactly what a SwiftUI `ForEach` needs.
    public let id: Int
    public let kind: Kind
    /// Empty for `.table` (the text lives in the cells) and `.thematicBreak` (Foundation emits a literal `⸻`
    /// glyph for the rule, which is presentation, not content — the view draws its own divider).
    public let text: AttributedString

    public init(id: Int, kind: Kind, text: AttributedString) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Turns Markdown source into `MarkdownBlock`s using Foundation's own CommonMark+GFM parser — rook adds no
/// grammar of its own. `AttributedString(markdown:options:)` with `interpretedSyntax: .full` keeps the BLOCK
/// structure (`.inlineOnly*` throws it away and returns one flat string), tagging every run with a
/// `PresentationIntent` whose `components` run from the INNERMOST intent outward (`components.first` is the
/// paragraph, `.last` the outermost list/table). Inline attributes — `.link`, bold/italic — ride along on the
/// runs, so the block's `text` is already styled and the view never re-parses.
///
/// Blocking is therefore a group-by, not a state machine: consecutive runs whose innermost intent identity
/// matches are one block, and a change of identity starts the next. Tables are the one exception — Foundation
/// emits them CELL by cell (each cell is its own innermost intent), so cells are accumulated by row identity
/// under the table identity and spliced back in at the position of the first cell, which is how a table keeps
/// its place between its neighbours.
public enum MarkdownDocument {
    /// Parse `markdown` into blocks. Never throws: a malformed document is parsed as far as it goes
    /// (`returnPartiallyParsedIfPossible`), and if even that fails the source is handed back as one plain
    /// paragraph rather than silently rendering nothing. Empty input yields NO blocks.
    public static func blocks(from markdown: String) -> [MarkdownBlock] {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full              // block intents; `.inlineOnly*` would drop them
        options.allowsExtendedAttributes = true        // keeps imageURL and friends on the runs
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }
        return blocks(from: document)
    }

    /// The group-by over an already-parsed document. Split out so tests can feed a hand-built `AttributedString`.
    static func blocks(from document: AttributedString) -> [MarkdownBlock] {
        var builder = Builder()
        var groupID: Int?
        var groupComponents: [PresentationIntent.IntentType] = []
        var groupText = AttributedString()

        for run in document.runs {
            let components = run.presentationIntent?.components ?? []
            let identity = components.first?.identity ?? -1   // components: INNERMOST first
            if identity != groupID {
                builder.append(id: groupID, components: groupComponents, text: groupText)
                groupID = identity
                groupComponents = components
                groupText = AttributedString()
            }
            groupText.append(document[run.range])
        }
        builder.append(id: groupID, components: groupComponents, text: groupText)
        return builder.finish()
    }

    /// Accumulates blocks in source order. Its only real job is the table splice: a table's cells arrive as N
    /// separate groups, so the first cell parks a PLACEHOLDER block in the output (holding the table's slot
    /// between its neighbours) and every later cell of that table fills rows in behind it; `finish()` swaps the
    /// placeholders for the assembled tables. Building the slot up front — rather than inserting at a recorded
    /// index afterwards — is what keeps a second table's position correct when the first one lands.
    private struct Builder {
        private var blocks: [MarkdownBlock] = []
        private var slots: [Int: Int] = [:]                              // table identity -> index in `blocks`
        private var rows: [Int: [(id: Int, cells: [AttributedString])]] = [:]   // table identity -> rows, in order
        private var headerRows: Set<Int> = []                            // table identities that have a header row

        mutating func append(id: Int?, components: [PresentationIntent.IntentType], text: AttributedString) {
            guard let id else { return }                                 // the very first flush has no group yet
            if let table = components.first(where: { $0.kind.isTable }) {
                appendCell(text, components: components, tableID: table.identity)
                return
            }
            let kind = MarkdownDocument.kind(for: components)
            blocks.append(MarkdownBlock(id: id, kind: kind, text: MarkdownDocument.blockText(kind, text)))
        }

        private mutating func appendCell(_ text: AttributedString, components: [PresentationIntent.IntentType], tableID: Int) {
            if slots[tableID] == nil {
                slots[tableID] = blocks.count
                blocks.append(MarkdownBlock(id: tableID, kind: .table(rows: [], hasHeader: false), text: AttributedString()))
            }
            var rowID = -1
            for component in components {
                switch component.kind {
                case .tableHeaderRow:
                    rowID = component.identity
                    headerRows.insert(tableID)
                case .tableRow:
                    rowID = component.identity
                default:
                    break
                }
            }
            var tableRows = rows[tableID] ?? []
            if let index = tableRows.firstIndex(where: { $0.id == rowID }) {
                tableRows[index].cells.append(text)
            } else {
                tableRows.append((id: rowID, cells: [text]))
            }
            rows[tableID] = tableRows
        }

        func finish() -> [MarkdownBlock] {
            var out = blocks
            for (tableID, index) in slots {
                out[index] = MarkdownBlock(
                    id: tableID,
                    kind: .table(rows: (rows[tableID] ?? []).map(\.cells), hasHeader: headerRows.contains(tableID)),
                    text: AttributedString()
                )
            }
            return out
        }
    }

    /// The block's own text, cleaned of what is presentation rather than content: a fenced code block's run
    /// carries the trailing newline that closed the fence, and a thematic break carries a literal `⸻` glyph.
    static func blockText(_ kind: MarkdownBlock.Kind, _ text: AttributedString) -> AttributedString {
        switch kind {
        case .thematicBreak:
            return AttributedString()
        case .codeBlock:
            var trimmed = text
            while let last = trimmed.characters.last, last.isNewline {
                trimmed.removeSubrange(trimmed.index(beforeCharacter: trimmed.endIndex)..<trimmed.endIndex)
            }
            return trimmed
        default:
            return text
        }
    }

    /// Classify one block from its intent chain. The FIRST leaf-ish intent wins (header/code/rule are always
    /// innermost and can't nest), while lists and quotes are counted on the way out to get their depth — a
    /// nested bullet arrives as `paragraph < listItem < unorderedList < listItem < unorderedList`, so `depth`
    /// is simply how many list intents the chain carries. The item's OWN list is the innermost one, which is
    /// why only that first `orderedList`/`unorderedList` decides whether the ordinal is real or a bullet.
    ///
    /// ponytail: checkbox items (`- [ ] todo`) are NOT recognized — Foundation has no task-list intent, so the
    /// marker survives as the literal text `[ ] todo` inside an ordinary list item. Upgrade path is a
    /// swift-markdown (cmark-gfm) parse, which is a whole dependency; not worth it until someone asks.
    static func kind(for components: [PresentationIntent.IntentType]) -> MarkdownBlock.Kind {
        var leaf: MarkdownBlock.Kind?
        var ordinal: Int?
        var isListItem = false
        var isOrdered = false
        var listDepth = 0
        var quoteDepth = 0

        for component in components {
            switch component.kind {
            case .header(let level):
                leaf = leaf ?? .header(level: level)
            case .codeBlock(let languageHint):
                leaf = leaf ?? .codeBlock(language: languageHint)
            case .thematicBreak:
                leaf = leaf ?? .thematicBreak
            case .listItem(let number):
                if !isListItem {
                    isListItem = true
                    ordinal = number
                }
            case .orderedList:
                listDepth += 1
                if listDepth == 1 { isOrdered = true }   // the innermost list is the item's own
            case .unorderedList:
                listDepth += 1
            case .blockQuote:
                quoteDepth += 1
            default:
                break
            }
        }

        if let leaf { return leaf }
        if isListItem { return .listItem(ordinal: isOrdered ? ordinal : nil, depth: max(1, listDepth)) }
        if quoteDepth > 0 { return .blockQuote(depth: quoteDepth) }
        return .paragraph
    }
}

private extension PresentationIntent.Kind {
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}
