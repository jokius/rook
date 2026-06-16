import agtCore
import SwiftUI

/// The detail-pane title-bar git pill: a branch glyph plus the branch name (or
/// `detached @ <shortsha>`), `↑N ↓N` when nonzero, a worktree chip for a linked
/// worktree, and a dimmed `*N` dirty marker when there are uncommitted changes.
/// Sits in the window toolbar's primary-action slot.
///
/// A `nil` status (the cwd is not a git work tree) renders nothing — no pill at
/// all, so the title bar is just the session name.
struct GitStatusPill: View {
    let status: GitStatus?

    var body: some View {
        if let status {
            pill(for: status)
        }
    }

    private func pill(for status: GitStatus) -> some View {
        // explicit Image + Text (not Label) so the glyph and text center-align in the
        // status bar; flat (no background) — the bottom status bar is the container.
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .imageScale(.small)
                .foregroundStyle(branchColor(status))
            Text(status.branchDisplay)
                .foregroundStyle(branchColor(status))
            if status.ahead > 0 {
                Text("↑\(status.ahead)").foregroundStyle(.cyan)
            }
            if status.behind > 0 {
                Text("↓\(status.behind)").foregroundStyle(.pink)
            }
            if let worktree = status.worktree {
                worktreeChip(worktree)
            }
            if status.dirty > 0 {
                Text("*\(status.dirty)").foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .accessibilityIdentifier("git-pill")
        .accessibilityValue(status.branchDisplay)
    }

    /// Green for the default branch (`main`/`master`), yellow for any other branch or
    /// a detached HEAD.
    private func branchColor(_ status: GitStatus) -> Color {
        status.branch == "main" || status.branch == "master" ? .green : .yellow
    }

    /// A small rectangular chip naming a linked worktree.
    private func worktreeChip(_ name: String) -> some View {
        Text(name)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
    }
}
