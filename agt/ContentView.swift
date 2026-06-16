import agtCore
import AppKit
import SwiftUI

/// Top-level layout: the workspace/session sidebar on the left, the active
/// session's terminal surface on the right. The detail pane swaps surfaces via
/// `.id(session.id)` — each session gets its own `TerminalView` identity, so the
/// session-owned surfaces survive switching.
///
/// The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`) so cross-workspace
/// drag-and-drop works natively. The bottom bar holds two add affordances: a
/// workspace button and a session menu (New Session / Open Directory…).
struct ContentView: View {
    @Bindable var store: AppStore
    let makeSurface: (Session) -> GhosttySurfaceView

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(store: store)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom) { bottomBar }
        } detail: {
            VStack(spacing: 0) {
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
        }
        // keep the system title bar showing the active session's name (NSWindow.title)
        // and surface the window un-minimized on launch.
        .background(WindowAccessor(title: windowTitle))
    }

    /// The active session's terminal, or a placeholder when nothing is selected.
    @ViewBuilder private var detailPane: some View {
        if let active = store.activeSession {
            TerminalView(session: active, makeSurface: makeSurface)
                .id(active.id)
        } else {
            Text("No session selected")
                .foregroundStyle(.secondary)
        }
    }

    /// A slim bottom status bar. Holds the active session's git status now and is the
    /// place for other info elements (the trailing area is intentionally left open).
    private var statusBar: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            GitStatusPill(status: store.activeSession?.gitStatus)
        }
        // symmetric vertical padding centers the content by construction (no reliance
        // on frame alignment); minHeight keeps the bar a consistent height when empty.
        // extra trailing inset keeps the right-aligned content clear of the window's
        // rounded bottom-right corner.
        .padding(.leading, 12)
        .padding(.trailing, 20)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 22)
        .background(.bar)
    }

    /// The titlebar text: the active session's display name, or "agt" when nothing
    /// is selected.
    private var windowTitle: String {
        store.activeSession?.displayName ?? "agt"
    }

    /// Two distinct add controls, source-list style: add a workspace, and a menu
    /// to add a session to the current workspace (default cwd) or a picked directory.
    private var bottomBar: some View {
        HStack(spacing: 2) {
            Button {
                store.addWorkspace(name: defaultWorkspaceName)
            } label: {
                Image(systemName: "rectangle.stack.badge.plus")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New Workspace")
            .accessibilityLabel("New Workspace")

            Menu {
                Button("New Session") { addSessionToCurrentWorkspace() }
                Button("Open Directory…") { openDirectoryThenAddSession() }
            } label: {
                Image(systemName: "plus.rectangle")
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New Session")
            .accessibilityLabel("Add session")
            .accessibilityIdentifier("add-session")

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.bar)
    }

    private var defaultWorkspaceName: String {
        "workspace \(store.workspaces.count + 1)"
    }

    /// The workspace a new session should land in: the selected session's
    /// workspace, else the last workspace. (Empty/specific workspaces can still be
    /// targeted via the workspace row's right-click menu.)
    private var currentWorkspaceID: UUID? {
        if let selected = store.selectedSessionID, let workspace = store.workspace(forSession: selected) {
            return workspace.id
        }
        return store.workspaces.last?.id
    }

    private func addSessionToCurrentWorkspace() {
        guard let workspaceID = currentWorkspaceID,
              let session = store.addSession(toWorkspace: workspaceID, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
        else { return }
        store.selectSession(session.id)
    }

    private func openDirectoryThenAddSession() {
        guard let workspaceID = currentWorkspaceID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a directory for the new session"
        guard panel.runModal() == .OK, let url = panel.url,
              let session = store.addSession(toWorkspace: workspaceID, cwd: url.path)
        else { return }
        store.selectSession(session.id)
    }
}

/// Sets the hosting `NSWindow.title` from SwiftUI. The scene is
/// `Window("agt", id: "main")` — a fixed string literal that owns the titlebar —
/// so `.navigationTitle` does not reliably override it; writing `window.title`
/// directly is the primary path.
///
/// The probe view's `window` is nil at make time, so the title cannot be applied
/// synchronously. Rather than a one-shot deferred read (which silently drops the
/// title if the window attaches after the block runs), `TitleProbeView` re-applies
/// the stored title from `viewDidMoveToWindow`, which fires exactly when the view
/// attaches to its window. `updateNSView` also re-applies whenever `title` changes
/// (the active session is renamed or switched).
private struct WindowAccessor: NSViewRepresentable {
    let title: String

    func makeNSView(context _: Context) -> TitleProbeView {
        let view = TitleProbeView()
        view.desiredTitle = title
        return view
    }

    func updateNSView(_ nsView: TitleProbeView, context _: Context) {
        nsView.desiredTitle = title
    }

    /// A zero-content probe that applies `desiredTitle` to its hosting window. It
    /// applies on `viewDidMoveToWindow` (window attachment) and on every
    /// `desiredTitle` change, so a launch where the window attaches late still lands
    /// the right title instead of leaving the scene's literal "agt".
    final class TitleProbeView: NSView {
        var desiredTitle: String = "" {
            didSet { window?.title = desiredTitle }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.title = desiredTitle
            // a window restored in a miniaturized state isn't on-screen, so a fresh
            // launch shows nothing and UI-test automation has nothing to hit. bring it
            // forward un-minimized; re-assert next tick because state restoration can
            // re-apply the miniaturized state right after the view attaches.
            bringForward(window)
            DispatchQueue.main.async { [weak self] in self?.bringForward(window) }
        }

        private func bringForward(_ window: NSWindow) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }
}
