import rookCore
import SwiftUI

/// A small SF-Symbol agent-status glyph for the attention list — the status's symbol tinted with the
/// configured status color, mirroring the sidebar's AppKit `StatusIconView`. Both surfaces draw from the
/// SAME resolvers (`AgentStatus.symbolName(override:configured:)` + `GhosttyApp.statusColor(for:override:)`)
/// so they can't drift, including the per-call `session.status --shape`/`--color` overrides. Only ever built
/// for a non-idle status (idle has no symbol and is filtered out before any glyph is shown).
struct StatusGlyph: View {
    let status: AgentStatus
    /// Optional per-call `#rrggbb` tint override (the session's `AgentIndicator.color`); nil = the
    /// Settings-configured status color.
    var colorHex: String?
    /// Optional per-call silhouette override (the session's `AgentIndicator.shape`); nil = the
    /// Settings-configured shape for this status, else the status' own semantic glyph. Only the PER-CALL
    /// half is passed in: the configured half is read off `GhosttyApp` here, exactly like the configured
    /// color, so the three carriers that feed this view (`PaletteItem`, `SessionSwitcherRow`, the
    /// recent-sessions popover row) need no new field and cannot drift from the sidebar.
    var shape: StatusShape?

    var body: some View {
        Image(systemName: status.symbolName(override: shape, configured: GhosttyApp.shared.statusShape(for: status)))
            .foregroundStyle(Color(nsColor: GhosttyApp.shared.statusColor(for: status, override: colorHex)))
    }
}
