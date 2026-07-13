import rookCore
import AppKit
import SwiftUI

/// The rendered Markdown a preview panel is currently showing, kept in sync with the file on disk.
///
/// Split out of the view so the FSEvents watcher has a stable owner across SwiftUI body re-evaluations
/// (a view struct is recreated constantly; the stream must not be). The watcher is armed on the file's
/// PARENT DIRECTORY, never the file itself: agents and editors rewrite a file by writing a temp file and
/// `rename`-ing it over the target, which swaps the inode — a stream (or a `DispatchSource` fd) bound to
/// the old file goes silent exactly when the interesting change happens.
@MainActor @Observable
final class MarkdownFile {
    /// The parsed blocks of the current file, or empty when it is missing/unreadable (`missing`).
    private(set) var blocks: [MarkdownBlock] = []

    /// Whether the current path could not be read — the agent moved or deleted the file out from under an
    /// open panel. Rendered as an empty state rather than a blank panel, so the panel never lies.
    private(set) var missing = false

    /// The file this instance is rendering + watching, or nil before the first `open`.
    private var path: String?

    /// Debounce window collapsing an FS-event burst (a save, a `git checkout`, an agent's rewrite) into one
    /// re-read. Same knob and value as the file tree's refresh debounce.
    private static let reloadDebounce: TimeInterval = 0.2

    /// The FSEventStream on the file's parent directory, or nil before the first `open`.
    /// `nonisolated(unsafe)` so `deinit` can tear it down (the same contract as `FileTreePanel.Coordinator`).
    nonisolated(unsafe) private var eventStream: FSEventStreamRef?

    /// The pending debounced reload, cancelled-and-rescheduled on every event burst.
    nonisolated(unsafe) private var reloadWorkItem: DispatchWorkItem?

    deinit {
        reloadWorkItem?.cancel()
        stopWatching()
    }

    /// Points the panel at `path`: re-reads it, and (on a path change) re-arms the directory watch. Called
    /// for every `(path, refreshToken)` change, so a re-click on the same link re-reads from disk — which is
    /// the point when an agent keeps rewriting the file it just linked.
    func open(_ path: String) {
        if path != self.path {
            self.path = path
            startWatching(URL(fileURLWithPath: path).deletingLastPathComponent())
        }
        reload()
    }

    /// Re-reads the current file and re-parses it. A file that vanished flips `missing` instead of clearing
    /// to a blank panel.
    func reload() {
        guard let path, let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            blocks = []
            missing = path != nil
            return
        }
        missing = false
        blocks = MarkdownDocument.blocks(from: text)
    }

    // MARK: FSEvents live reload

    /// Arms an FSEventStream on `directory` (re-arming: any prior stream is stopped first) so a rewrite of
    /// the file — including the temp-file + `rename` dance every serious editor and agent performs — schedules
    /// a debounced re-read. The C callback carries no context, so `self` rides across as an unretained `info`
    /// pointer (safe because the stream never outlives this object: it is invalidated in `deinit`, and the
    /// object is released on the main actor by SwiftUI), and it hops to the main actor before touching state.
    ///
    /// Watching the whole directory means unrelated neighbours also wake us; the debounce absorbs that, and a
    /// re-read of one file is cheap. ponytail: filter events by name if a busy directory (a build output dir)
    /// ever shows up in a profile.
    private func startWatching(_ directory: URL) {
        stopWatching()
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let file = Unmanaged<MarkdownFile>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { file.scheduleReload() }
        }
        // kFSEventStreamCreateFlagFileEvents: report per-FILE events, not just "something in this dir changed"
        // — without it a rename-over-the-target can coalesce into a directory event we would still catch, but
        // file events keep the stream honest (and cheap) for the single path we care about.
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return
        }
        eventStream = stream
    }

    /// Stops and releases the current stream (idempotent). `nonisolated` so `deinit` can call it.
    nonisolated private func stopWatching() {
        guard let stream = eventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        eventStream = nil
    }

    /// Cancel-and-reschedule the debounced reload so one event burst reads the file once, on the main actor.
    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reloadDebounce, execute: work)
    }
}

/// The per-session Markdown preview panel: a scrolling render of the file's blocks, live-reloaded from disk.
///
/// Deliberately NOT a `WKWebView` and not a dependency: `MarkdownDocument` (stdlib `AttributedString`, which
/// is cmark-gfm underneath) already yields headers, nested lists, code fences, block quotes, links and GFM
/// tables, which is everything an agent's plan/README actually contains.
/// ponytail: no images and no syntax highlighting (the stdlib parser reports a code fence's language but does
/// not colour it), and a `- [ ]` checkbox renders as the literal `[ ]` — swap in a WebView only if those
/// three start to matter.
struct MarkdownPanel: View {
    let path: String
    let refreshToken: Int
    /// The chrome text colour, tracked from the terminal theme by the enclosing `WindowContentView`.
    let textColor: Color
    /// Re-targets this panel at another Markdown file — a `[plan](./plan.md)` cross-link inside the rendered
    /// document. Injected rather than reached for, so the panel stays a pure view over a path.
    let onPreview: (String) -> Void

    @State private var file = MarkdownFile()

    var body: some View {
        Group {
            if file.missing {
                ContentUnavailableView("File not found", systemImage: "doc.questionmark",
                                       description: Text((path as NSString).lastPathComponent))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(file.blocks) { block in
                            view(for: block)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                    .textSelection(.enabled)
                }
            }
        }
        .foregroundStyle(textColor)
        // re-reads on a path change AND on a refresh-token bump (a re-click of the same link), because the
        // file behind an unchanged path is exactly what an agent keeps rewriting.
        .task(id: FileKey(path: path, token: refreshToken)) { file.open(path) }
        // an inline link opens in the browser, not in this panel: the panel renders local Markdown, and a
        // click-through to arbitrary web content is the system browser's job. A LOCAL link goes through the
        // same policy as a terminal click, so a `[plan](./plan.md)` cross-link re-targets the panel.
        .environment(\.openURL, OpenURLAction { url in
            guard let action = linkAction(url) else { return .discarded }
            action()
            return .handled
        })
    }

    /// The identity of "which file, which read" — a change of either re-runs the load task.
    private struct FileKey: Equatable {
        let path: String
        let token: Int
    }

    /// Routes a clicked inline link: a web URL to the system browser, a relative/absolute Markdown link to
    /// this same panel (resolved against the OPEN FILE's directory, which is what a Markdown link means),
    /// and anything else to Finder — the same three outcomes `LinkPolicy` gives a terminal click.
    private func linkAction(_ url: URL) -> (() -> Void)? {
        let cwd = (path as NSString).deletingLastPathComponent
        switch LinkPolicy.disposition(for: url.absoluteString, cwd: cwd) {
        case let .open(target): return { NSWorkspace.shared.open(target) }
        case let .preview(target): return { onPreview(target.path) }
        case let .reveal(target): return { NSWorkspace.shared.activateFileViewerSelecting([target]) }
        case .ignore: return nil
        }
    }

    // MARK: Block rendering

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph:
            Text(block.text)
        case let .header(level):
            Text(block.text)
                .font(.system(size: Self.headerSize(level), weight: .semibold))
                .padding(.top, level <= 2 ? 6 : 2)
        case let .listItem(ordinal, depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordinal.map { "\($0)." } ?? "•")
                    .foregroundStyle(textColor.opacity(0.6))
                    .monospacedDigit()
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth - 1) * 16)
        case let .codeBlock(language):
            Text(block.text)                                     // the fence's trailing newline is already trimmed
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(textColor.opacity(0.06), in: .rect(cornerRadius: 6))
                .accessibilityLabel(language.map { "Code block, \($0)" } ?? "Code block")
        case let .blockQuote(depth):
            Text(block.text)
                .foregroundStyle(textColor.opacity(0.8))
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(textColor.opacity(0.25))
                        .frame(width: 2)
                }
                .padding(.leading, CGFloat(depth - 1) * 10)
        case .thematicBreak:
            Divider().overlay(textColor.opacity(0.2))
        case let .table(rows, hasHeader):
            table(rows: rows, hasHeader: hasHeader)
        }
    }

    /// A GFM table. `Grid` sizes the columns to their content, which is what a hand-written Markdown table
    /// expects; a header row is drawn bold with a rule under it.
    private func table(rows: [[AttributedString]], hasHeader: Bool) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                GridRow {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(cell).fontWeight(hasHeader && index == 0 ? .semibold : .regular)
                    }
                }
                if hasHeader, index == 0 {
                    Divider().overlay(textColor.opacity(0.2)).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(8)
        .background(textColor.opacity(0.04), in: .rect(cornerRadius: 6))
    }

    /// Header point sizes, `#` through `######`, tapering to body size — the panel is a reading pane in a
    /// narrow column, so h1 stays modest rather than filling the width.
    private static func headerSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 13
        }
    }
}
