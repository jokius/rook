import rookCore
import SwiftUI

/// A small SF-Symbol agent-status glyph for the attention list — the status's symbol tinted with the
/// configured status color, mirroring the sidebar's AppKit `StatusIconView`. Both surfaces draw from the
/// SAME resolvers (`AgentStatus.symbolName(shape:)` + `GhosttyApp.statusColor(for:override:)`) so they
/// can't drift, including the per-call `session.status --shape`/`--color` overrides. Only ever built for
/// a non-idle status (idle has no symbol and is filtered out before any glyph is shown).
struct StatusGlyph: View {
    let status: AgentStatus
    /// Optional per-call `#rrggbb` tint override (the session's `AgentIndicator.color`); nil = the
    /// Settings-configured status color.
    var colorHex: String?
    /// Optional per-call silhouette override (the session's `AgentIndicator.shape`); nil = the status'
    /// own semantic glyph.
    var shape: StatusShape?

    var body: some View {
        Image(systemName: status.symbolName(shape: shape))
            .foregroundStyle(Color(nsColor: GhosttyApp.shared.statusColor(for: status, override: colorHex)))
    }
}
