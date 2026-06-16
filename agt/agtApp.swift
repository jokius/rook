import agtCore
import AppKit
import SwiftUI

@main
struct agtApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @State private var store: AppStore
    @State private var gitStatusService: GitStatusService

    init() {
        let store = agtApp.restoredStore()
        _store = State(initialValue: store)
        _gitStatusService = State(initialValue: GitStatusService(store: store))
    }

    var body: some Scene {
        Window("agt", id: "main") {
            ContentView(store: store) { Self.makeSurface(for: $0, store: store, service: gitStatusService) }
                .frame(minWidth: 640, minHeight: 400)
                .task {
                    appDelegate.store = store
                    // start the active-session refresh loop + focus observers once
                    // the scene appears (idempotent if the task re-runs).
                    gitStatusService.start()
                }
                // refresh git status for the active session whenever the selection
                // changes, so the result is observable as soon as a session is shown.
                .onChange(of: store.selectedSessionID, initial: true) {
                    gitStatusService.refreshActive()
                }
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }

    /// Loads the persisted snapshot and restores it; if there's nothing saved,
    /// seeds a single default workspace with one session at $HOME.
    @MainActor
    private static func restoredStore() -> AppStore {
        // UI tests pass AGT_STATE_DIR to isolate persistence in a temp dir so a
        // run never touches the user's real workspaces.json.
        let persistence = ProcessInfo.processInfo.environment["AGT_STATE_DIR"]
            .map { PersistenceStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? PersistenceStore()
        let store = AppStore(persistence: persistence)
        let snapshot = persistence.load()
        guard !snapshot.workspaces.isEmpty else {
            let workspace = store.addWorkspace(name: "workspace 1")
            store.addSession(toWorkspace: workspace.id, cwd: FileManager.default.homeDirectoryForCurrentUser.path)
            return store
        }
        store.restore(from: snapshot)
        return store
    }

    /// Surface factory: creates a libghostty-backed view for the session, spawning
    /// a login shell in the session's initial working directory. On shell exit the
    /// view calls back to close the owning session in the store.
    @MainActor
    private static func makeSurface(for session: Session, store: AppStore, service: GitStatusService) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: session.initialCwd)
        view.session = session
        let sessionID = session.id
        view.onExit = { store.closeSession(sessionID) }
        view.onCwdChange = { service.requestRefresh(sessionID: sessionID) }
        return view
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The shared app state, handed over once the scene appears so the delegate can
    /// persist it on terminate.
    var store: AppStore?

    func applicationWillFinishLaunching(_: Notification) {
        // a Debug app launched from DerivedData (ad-hoc signed) never hands the Dock a
        // non-default tile icon via the usual runtime path. set it explicitly. load the
        // artwork straight from the compiled asset catalog rather than via
        // NSWorkspace.icon(forFile:), whose Icon Services cache is keyed by bundle path
        // and the DerivedData path is reused across rebuilds, so it serves a stale tile.
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        // Boot libghostty: init, config, app_new, 120fps tick.
        _ = GhosttyApp.shared
    }

    func applicationWillTerminate(_: Notification) {
        store?.save()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
