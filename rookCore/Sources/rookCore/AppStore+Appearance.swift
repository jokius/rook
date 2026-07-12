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

    /// Sets (or clears, with nil) a workspace's sidebar icon. For an `.image` icon, `icon.value` must
    /// ALREADY point at the copy in `WorkspaceIconStorage` — the caller installs the file (the control
    /// server and the GUI both go through `WorkspaceIconStorage.install`), so this only swaps the spec.
    ///
    /// It does NOT delete the file a REPLACED icon was using: the `tree` read-back hands a script that
    /// exact path, and `workspace.icon <that path>` is the documented record-then-restore — deleting the
    /// file on replace would make restoring an image icon fail with `no such image file`. So a replaced (or
    /// cleared) icon's file is left in place, just like a deleted workspace's is (it can reopen from Open
    /// Recent). The cost is one orphaned file per image-icon pick — a few KB each, and icons are picked
    /// rarely. ponytail: a sweep would have to union every window's snapshot with recent-closed and the
    /// pending closes, which is more than the feature is worth; add it only if the dir ever actually grows.
    ///
    /// Delta-guarded, and a plain `save()` (unlike the color): picking an icon is a single event, not a
    /// continuous drag.
    func setWorkspaceIcon(_ id: UUID, icon: WorkspaceIcon?) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), workspaces[index].icon != icon else { return }
        workspaces[index].icon = icon
        save()
    }
}
