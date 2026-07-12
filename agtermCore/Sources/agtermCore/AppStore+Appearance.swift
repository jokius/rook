import Foundation

/// Per-workspace appearance: the sidebar icon's tint. The mutator lives here rather than in `AppStore`
/// so that file stays under the swiftlint size limit, like `AppStore+RecentClosed`.
public extension AppStore {
    /// Sets (or clears, with nil) a workspace's sidebar icon color. `hex` is a validated `#rrggbb` — the
    /// control boundary and the CLI both check it with `WatermarkConfig.isValidColorHex`, and the GUI feeds
    /// an `NSColor` it formatted itself.
    ///
    /// Delta-guarded, so a repeated set is a clean no-op (no write, no observation tick). Persists via
    /// `scheduleSave()` rather than `save()`: the color panel is continuous, so a live drag fires this
    /// dozens of times a second and each `save()` would synchronously re-encode and rewrite the whole
    /// snapshot on the main actor — the same reason `selectSession`/`setFontSize` debounce.
    func setWorkspaceColor(_ id: UUID, hex: String?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].colorHex != hex else { return }
        workspaces[index].colorHex = hex
        scheduleSave()
    }
}
