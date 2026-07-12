import agtermCore
import AppKit
import UniformTypeIdentifiers

/// Per-workspace appearance actions (the sidebar icon color) — the GUI half of `workspace.color`, driven
/// by the sidebar workspace row's Color… / Reset Color context-menu items. Split out of `AppActions` so
/// that file stays under the swiftlint size limit, like `AppActions+Palette`.
extension AppActions {
    /// Sets (or clears, with nil) a workspace's sidebar icon color. Clean no-op on an unknown id. The
    /// store delta-guards and debounces the write, so the color panel's continuous drag is cheap.
    func setWorkspaceColor(_ id: UUID, hex: String?, in store: AppStore? = nil) {
        guard uiActionsEnabled else { return }
        guard let store = store ?? self.store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setWorkspaceColor(id, hex: hex)
    }

    /// Sets (or clears, with nil) a workspace's sidebar icon. An `.image` icon must already point at its
    /// state-dir copy — `pickWorkspaceIcon` installs the file first.
    func setWorkspaceIcon(_ id: UUID, icon: WorkspaceIcon?, in store: AppStore? = nil) {
        guard uiActionsEnabled else { return }
        guard let store = store ?? self.store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setWorkspaceIcon(id, icon: icon)
    }

    /// Clears both the icon and the color, restoring the default workspace glyph in the theme tint.
    func resetWorkspaceAppearance(_ id: UUID, in store: AppStore? = nil) {
        guard uiActionsEnabled else { return }
        guard let store = store ?? self.store, store.workspaces.contains(where: { $0.id == id }) else { return }
        store.setWorkspaceIcon(id, icon: nil)
        store.setWorkspaceColor(id, hex: nil)
    }

    /// "Icon…": pick an image file for a workspace's sidebar icon. The file is COPIED into the state dir,
    /// so the icon survives the original being moved or deleted.
    ///
    /// Only image files are offered here. An SF Symbol name has no GUI picker on purpose: there is no
    /// public API to enumerate SF Symbols, so it would mean hand-curating and maintaining a symbol list —
    /// symbols (and emoji) are set over the control channel with `agtermctl workspace icon`.
    func pickWorkspaceIcon(_ id: UUID, in store: AppStore? = nil) {
        guard uiActionsEnabled else { return }
        guard let store = store ?? self.store, store.workspaces.contains(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Workspace Icon"
        panel.allowedContentTypes = [.svg, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let icon = try WorkspaceIconStorage.install(source: source, workspaceID: id)
            store.setWorkspaceIcon(id, icon: icon)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Opens the shared system color panel to pick a workspace's icon color, previewing live: the panel is
    /// continuous, so every drag tick calls back and re-tints the row immediately.
    ///
    /// `NSColorPanel.shared` is process-wide (Settings' SwiftUI `ColorPicker` drives the same panel), so the
    /// target/action are pointed at THIS workspace on open and cleared when the panel closes — otherwise a
    /// later Settings color edit would keep re-tinting the last workspace picked here.
    func pickWorkspaceColor(_ id: UUID, in store: AppStore? = nil) {
        guard uiActionsEnabled else { return }
        let store = store ?? self.store
        guard let store, let workspace = store.workspaces.first(where: { $0.id == id }) else { return }
        WorkspaceColorPanelTarget.shared.begin(workspaceID: id, store: store, actions: self,
                                               current: NSColor(agtermHex: workspace.colorHex))
    }
}

/// The `NSColorPanel` target/action sink for the workspace color picker. AppKit's color panel is a
/// singleton with a single target/action, and it long-outlives the context menu that opened it, so the
/// current workspace + store are held here rather than captured in a closure the menu owns.
@MainActor
final class WorkspaceColorPanelTarget: NSObject {
    static let shared = WorkspaceColorPanelTarget()

    private var workspaceID: UUID?
    private weak var store: AppStore?
    private weak var actions: AppActions?

    func begin(workspaceID: UUID, store: AppStore, actions: AppActions, current: NSColor?) {
        self.workspaceID = workspaceID
        self.store = store
        self.actions = actions
        let panel = NSColorPanel.shared
        panel.showsAlpha = false // the tint is applied at full alpha; an alpha channel would be silently dropped
        if let current { panel.color = current }
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosed),
                                              name: NSWindow.willCloseNotification, object: panel)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ panel: NSColorPanel) {
        guard let workspaceID, let store, let actions else { return }
        actions.setWorkspaceColor(workspaceID, hex: panel.color.agtermHexString, in: store)
    }

    /// Release the panel back to its other users (the Settings color pickers) once this pick is over.
    /// `NSColorPanel` exposes no `target` getter, so ownership is tracked by our own `workspaceID`: this
    /// only fires for a panel THIS type opened (the observer is registered in `begin` and removed here).
    @objc private func panelClosed() {
        let panel = NSColorPanel.shared
        guard workspaceID != nil else { return }
        panel.setTarget(nil)
        panel.setAction(nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: panel)
        workspaceID = nil
        store = nil
        actions = nil
    }
}
