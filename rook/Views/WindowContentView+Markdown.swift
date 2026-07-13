import rookCore
import AppKit
import SwiftUI

/// The per-session Markdown preview panel on the far RIGHT: its draggable resize divider, the column (top
/// hairline + header + `MarkdownPanel`), and the header strip (file name + refresh/reveal/close). Rendered
/// inline inside `WindowContentView.splitRoot`; split out of `WindowContentView.swift` to keep that file
/// under the swiftlint size limit — the same shape as `WindowContentView+FileTree`.
extension WindowContentView {
    /// The width the preview column currently occupies (0 when closed) — the amount the FILE TREE's divider
    /// must discount from the window width to keep its own drag math (`totalWidth - cursor.x`) anchored to
    /// ITS right edge rather than the window's, since this panel sits to its right.
    var markdownColumnWidth: CGFloat {
        store.activeSession?.markdownPath == nil ? 0 : CGFloat(store.markdownWidth)
    }

    /// A 1px themed separator with a wider invisible grab handle, dragging the preview panel's width. This
    /// panel is the RIGHTMOST column, so — like the file tree — its width is the inverse of the cursor's
    /// absolute X: `totalWidth - cursor.x`. (Which is also why the file tree's own divider must be handed a
    /// `totalWidth` reduced by THIS panel's width when both are open; see `splitRoot`.)
    func markdownDivider(totalWidth: CGFloat) -> some View {
        Rectangle()
            .fill(chromeText.opacity(0.1))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        // absolute cursor X, never accumulated translation: the divider moves WITH the width,
                        // so a translation-based resize feeds back on itself and the line flickers.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                store.markdownWidth = min(AppStore.markdownWidthMax,
                                                          max(AppStore.markdownWidthMin, Double(totalWidth - value.location.x)))
                            }
                            // persist the new width once, on release, not on every drag tick.
                            .onEnded { _ in store.save() }
                    )
            }
    }

    /// The preview column: a top hairline, a compact header, then the rendered document — over the sidebar
    /// tint wash so it reads as chrome rather than as a second terminal.
    func markdownColumn(for session: Session, path: String) -> some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(chromeText.opacity(0.1))
                .frame(height: 1)
            markdownHeader(for: session, path: path)
            MarkdownPanel(path: path, refreshToken: session.markdownRefreshToken, textColor: chromeText,
                          onPreview: { actions.openMarkdown($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .background(sidebarTintWash)
    }

    /// The preview header strip: the file's name, plus reveal-in-Finder and close. There is no refresh button
    /// — the panel watches the file's directory and re-reads itself (see `MarkdownFile`).
    func markdownHeader(for session: Session, path: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.text")
                .foregroundStyle(chromeText.opacity(0.7))
            Text((path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(chromeText)
                .font(.system(size: 11, weight: .medium))
                .help(path)
            Spacer(minLength: 0)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeText.opacity(0.7))
            .help("Reveal in Finder")
            Button {
                actions.closeMarkdown()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(chromeText.opacity(0.7))
            .help("Close Preview")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
