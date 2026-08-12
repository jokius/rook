import AppKit
import rookCore
import Darwin
import Foundation

/// The programmatic control channel: a POSIX unix-domain-socket listener that turns newline-delimited
/// JSON `ControlRequest`s into calls on the existing `AppActions` / `AppStore` seam — the same seam the
/// toolbar, menu bar, and palettes use. One request per connection: read a line, dispatch, write one
/// `ControlResponse`, close.
///
/// `@MainActor`: lifecycle and dispatch run on the main actor (the store is main-actor isolated). Only
/// the blocking accept/read loop runs on a background `DispatchQueue`; each decoded request hops back to
/// the main actor to execute. Best-effort: a bind failure logs and the app still launches.
@MainActor
final class ControlServer {
    /// The window library; commands dispatch onto a per-request target window's store. A `tree` or a
    /// placement/`active` command with no `args.window` targets the frontmost window; with
    /// `args.window` it targets that window (which must be open). An id/prefix session/workspace
    /// target with no `args.window` is resolved across ALL open windows so a captured id resolves
    /// regardless of which window is frontmost. The `window.*` commands drive the library itself.
    let library: WindowLibrary
    let actions: AppActions
    let settingsModel: SettingsModel
    private let socketPath: String

    /// The target-resolution query layer: owns the `emptyStore`/`store` frontmost-fallback and wraps the
    /// pure `ControlResolve` matcher with app-side store scoping and the pinned wire-error strings.
    let resolver: ControlTargetResolver

    /// The listening socket fd, or -1 when not listening. `start()` is idempotent on this.
    private var listenFD: Int32 = -1

    /// The held ownership-lock fd, or -1 when this process does not own `socketPath`.
    private var lockFD: Int32 = -1

    /// Set when another live instance owns `socketPath`, so this one will never bind or advertise it.
    private var refused = false

    /// The socket path the listener actually bound, or nil when it isn't listening (bind failed or
    /// not started).
    var boundSocketPath: String? { listenFD >= 0 ? socketPath : nil }

    /// Suffix marking the stand-in path a refused instance advertises. Nothing ever creates it, so every
    /// connection to it fails.
    static let unavailableSuffix = ".unavailable"

    /// The path spawned surfaces point `ROOK_SOCKET` at (resolved at init via `defaultSocketPath()`,
    /// honoring a test's `ROOK_CONTROL_SOCKET` override). Once this instance has REFUSED the real path
    /// because another one owns it, this becomes an unbindable sibling: a shell here must not reach the
    /// other app, which for a second instance sharing state is the user's live terminal (persisted session
    /// ids resolve there too). Leaving the variable UNSET is worse than a dead value — the shipped status
    /// hooks drop `--socket` when it is absent, and `rookctl` then resolves the very default the other
    /// instance is serving. Not `boundSocketPath`: a shell spawned BEFORE `start()` binds (the launch
    /// window's surfaces can materialize first) would get a nil there, leaking ROOK_SOCKET permanently.
    /// Equal to `boundSocketPath` once bound.
    var resolvedSocketPath: String { refused ? socketPath + ControlServer.unavailableSuffix : socketPath }
    /// The background queue running the blocking accept loop.
    private let acceptQueue = DispatchQueue(label: "com.rook.app.control.accept")

    /// Thread-safe cached window list, refreshed on the main actor after every dispatched command and
    /// read (under the lock) from the background accept loop. Lets `window.list` / `tree --window`
    /// queries be answered without the main actor, so a brief main-thread stall after a window close
    /// can't make the serial control server unresponsive to polls.
    private let cacheLock = NSLock()
    nonisolated(unsafe) private var cachedWindowNodes: [ControlWindowNode] = []

    nonisolated private func cachedWindows() -> [ControlWindowNode] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cachedWindowNodes
    }

    @MainActor func refreshWindowCache() {
        let nodes = buildWindowList()
        cacheLock.lock(); cachedWindowNodes = nodes; cacheLock.unlock()
    }

    /// A cache-only response for read-only window queries, or nil to fall through to the main actor.
    /// Falls through on a cold cache (the main-actor path will populate it) and for `tree --window`
    /// targeting an OPEN window (building the tree needs the main actor); only the closed-window error
    /// and `window.list` are answered here.
    nonisolated func fastPathResponse(for request: ControlRequest) -> ControlResponse? {
        let nodes = cachedWindows()
        guard !nodes.isEmpty else { return nil }
        switch request.cmd {
        case .windowList:
            return ControlResponse(ok: true, result: ControlResult(windows: nodes))
        case .tree:
            guard let target = request.args?.window, !target.isEmpty else { return nil }
            let candidates = nodes.compactMap { UUID(uuidString: $0.id) }
            let active = nodes.first { $0.active }.flatMap { UUID(uuidString: $0.id) }
            guard case .resolved(let id) = ControlResolve.resolve(target, candidates: candidates, active: active),
                  let node = nodes.first(where: { $0.id == id.uuidString }), !node.open else { return nil }
            return ControlResponse(ok: false, error: "window not open — window.select it first")
        default:
            return nil
        }
    }

    /// Cap on a single request line, shared with the client through `ControlWire` so the two sides can't
    /// drift — `rookctl` checks the encoded request against the same number BEFORE connecting, which is
    /// what turns an oversized request into a readable error instead of a mid-write disconnect. Over the
    /// cap the line is rejected and the connection closed, so a bad client can never grow the buffer
    /// unbounded.
    nonisolated private static let maxLineBytes = ControlWire.maxRequestLineBytes

    /// Seconds a blocking client read may stall before it times out (EAGAIN → connection closed), so a
    /// stalled client can't park the serial accept loop forever.
    nonisolated private static let readTimeoutSeconds = 5

    /// Seconds a blocking response `write()` may stall before it times out, so a client that stops reading
    /// can't park the serial accept loop — `session.text --all` responses can be multi-MB and won't fit
    /// the socket buffer in one write, so an unresponsive reader would otherwise block indefinitely.
    nonisolated private static let writeTimeoutSeconds = 5

    /// Overall seconds a single connection's request read may take before it's abandoned. `readTimeoutSeconds`
    /// only bounds each `read()`, so a slow-loris client trickling one byte per interval (each under the
    /// per-read timeout) never sends a newline yet keeps the serial accept loop busy indefinitely. This caps
    /// the total read time; a legit one-line request arrives in milliseconds, far under the cap.
    nonisolated private static let readDeadlineSeconds = 10

    /// Overall seconds a single response write may take before it's abandoned. `SO_SNDTIMEO` only bounds
    /// each `write()`, so a slow-drip reader draining a multi-MB `session.text --all` a few bytes per
    /// interval keeps every write making progress and never trips the per-write timeout, parking the serial
    /// accept loop. This caps the total write time, symmetric with `readDeadlineSeconds`; a normal reader
    /// drains a response in milliseconds, far under the cap.
    nonisolated private static let writeDeadlineSeconds = 10

    init(library: WindowLibrary, actions: AppActions, settingsModel: SettingsModel, socketPath: String? = nil) {
        self.library = library
        self.actions = actions
        self.settingsModel = settingsModel
        self.resolver = ControlTargetResolver(library: library)
        self.socketPath = socketPath ?? ControlServer.defaultSocketPath()
        // ownership is decided HERE, not in `start()`. The launch window's surfaces are built during the
        // initial render pass and SNAPSHOT `ROOK_SOCKET` into the pty environment (`GhosttySurfaceView.env`
        // is a `let` read at spawn), while `start()` only runs from the scene's `.task` afterwards. Deciding
        // late would hand that first shell the owner's live socket, which is the one thing this guard exists
        // to prevent. Binding stays in `start()`; this only answers who owns the path.
        _ = acquireOwnership()
        // keep the read cache's `active` flag fresh across async frontmost changes (this server lives
        // for the app's lifetime, so the observer doesn't need removal).
        NotificationCenter.default.addObserver(forName: .rookWindowFrontmostChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
        // a GUI-only sidebar toggle (⌃⌘S / toolbar / menu / palette) mutates sidebarVisible without a
        // control command, so refresh the cache on it too — otherwise window.list's sidebarVisible lags.
        // queue nil (NOT .main) delivers synchronously on the posting thread: setSidebarVisible is
        // @MainActor, so the refresh runs on the main actor BEFORE the toggle returns. An async .main hop
        // would leave a window where a background window.list fast-path read still sees the stale cache.
        NotificationCenter.default.addObserver(forName: .rookSidebarVisibilityChanged, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
        // window.list carries LIVE NSWindow geometry + fullscreen/zoom state, read at cache-build time. A
        // user drag/resize/zoom/fullscreen changes it with NO control command, and a polling window.list is
        // fast-path-served so it never refreshes its own cache — so observe the AppKit window notifications
        // and refresh the cache on each. The fullscreen enter/exit notifications fire AFTER the async
        // transition, so the refreshed cache sees the settled `styleMask`. The notification is ignored (not
        // captured — a non-Sendable `Notification` can't cross into the `assumeIsolated` region under Swift 6);
        // it fires for ANY window, but a non-rook panel just rebuilds the same cheap rook nodes, and a
        // drag's didMove/didResize storm just keeps the cache current.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowCache() }
            }
        }
        // a window's NSWindow attaches a render pass or two AFTER its store loads, so the node cached right
        // after window.new carries no geometry/flags — and nothing else refreshes it on that path (see the
        // .rookWindowAttachmentChanged doc comment). Refresh on attach/detach so the cache is honest for
        // every opener, including GUI New Window and launch reopen-all, which run no control command at all.
        NotificationCenter.default.addObserver(forName: .rookWindowAttachmentChanged, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowCache() }
        }
    }

    /// The socket path the app and the CLI rendezvous on. `ROOK_CONTROL_SOCKET` is an explicit override
    /// (used by tests, whose sandboxed `ROOK_STATE_DIR` container path is too long for `sun_path`'s
    /// ~104-byte limit). Otherwise it is `<ROOK_STATE_DIR>/rook.sock` when that var is set (state
    /// isolation), else `<app support>/rook.sock`.
    static func defaultSocketPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["ROOK_CONTROL_SOCKET"] { return explicit }
        return ControlResolve.socketPath(stateDir: env["ROOK_STATE_DIR"], appSupport: PersistenceStore.defaultDirectory.path)
    }

    // MARK: - Lifecycle

    /// Bind and start listening. Idempotent: a no-op if already listening (the scene `.task` may re-run if
    /// the window is recreated, so a second `start()` must not attempt a second `bind`). On any failure it
    /// logs and returns, leaving the app to launch normally.
    func start() {
        guard listenFD < 0 else { return }

        guard socketPath.utf8.count < 104 else {
            log("control socket path too long (\(socketPath.utf8.count) bytes): \(socketPath)")
            return
        }

        // normally taken at init; retried here for the instance refused while the owner was still alive,
        // which reaches this again on a later window. `lockFD >= 0` first because flock is per open file
        // description: a second `open` of a file THIS process already locked conflicts with itself.
        guard lockFD >= 0 || acquireOwnership() else { return }

        // every failure below KEEPS the lock. Releasing it would let another instance bind the path while
        // this one still advertises it — the very leak the lock exists to close — and it buys nothing: the
        // next window's `start()` retries the bind through the `lockFD >= 0` arm above.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("control socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        // unlink the stale socket file (a force-quit that skipped applicationWillTerminate leaves one).
        // Holding the lock is what makes this safe: nobody else is serving the path, so whatever sits on
        // disk is a leftover.
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { buf in
                pathBytes.withUnsafeBufferPointer { src in
                    buf.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            log("control bind(\(socketPath)) failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // owner-only access (0600).
        chmod(socketPath, 0o600)

        guard listen(fd, 8) == 0 else {
            log("control listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(socketPath)
            return
        }

        listenFD = fd
        acceptLoop(fd: fd)
    }

    /// Close the listener and unlink the socket file.
    func stop() {
        // outside the guard: the lock is taken in `init`, so an instance that never bound (path too long,
        // a failed bind, or a refusal) still holds one and would otherwise keep it for the whole process.
        defer { releaseOwnership() }
        guard listenFD >= 0 else { return }
        close(listenFD)
        listenFD = -1
        unlink(socketPath)
    }

    /// Take the exclusive advisory lock that marks this process the owner of `socketPath` — held from init
    /// until `stop()` — and set `refused` when another live instance holds it.
    ///
    /// `connect` cannot answer the ownership question on Darwin: a live listener whose backlog is full
    /// refuses with the same `ECONNREFUSED` a socket nobody listens on returns (the backlog is 8, and one
    /// stalled client parks the serial accept loop for up to `readDeadlineSeconds`, so saturation is
    /// reachable), and a blocking `connect` against it returns immediately rather than stalling. `flock`
    /// carries no such ambiguity, is atomic against a second instance launching in the same moment, and the
    /// kernel releases it when a force-quit kills the holder — which is exactly the case the `unlink` in
    /// `start()` exists for.
    private func acquireOwnership() -> Bool {
        let lockPath = socketPath + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            log("control lock open(\(lockPath)) failed: \(String(cString: strerror(errno)))")
            return false
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            refused = true
            log("control socket \(socketPath) is already served by another instance — not binding")
            return false
        }
        lockFD = fd
        // clear it: `start()` re-runs from every window scene's task, so an instance refused while the owner
        // was alive reaches this line once the owner quits, and a stale `refused` would leave it advertising
        // the unavailable path forever on a socket it now serves.
        refused = false
        return true
    }

    /// Drop the ownership lock. The lock FILE is deliberately left behind: unlinking it would let the next
    /// instance create a fresh inode and lock that instead, which excludes nobody.
    private func releaseOwnership() {
        guard lockFD >= 0 else { return }
        close(lockFD)
        lockFD = -1
    }

    // MARK: - Accept / read loop

    /// Run the blocking accept loop on the background queue. Each accepted connection is handled inline
    /// (one request → one response → close); connections are rare and short, so a per-connection thread is
    /// unnecessary.
    private func acceptLoop(fd: Int32) {
        acceptQueue.async {
            while true {
                let conn = accept(fd, nil, nil)
                if conn < 0 {
                    // a closed listener (stop()) makes accept fail — exit the loop.
                    if errno == EBADF || errno == EINVAL { return }
                    continue
                }
                ControlServer.handleConnection(conn, server: self)
            }
        }
    }

    /// Read one newline-delimited request from `conn`, decode it, dispatch it on `server` (main actor),
    /// write the encoded response back, and close. A decode failure replies with a structured error rather
    /// than crashing. Runs on the background queue (called from `acceptLoop`).
    nonisolated private static func handleConnection(_ conn: Int32, server: ControlServer) {
        defer { close(conn) }
        // never let a write to a client that already hung up raise SIGPIPE (default-fatal) — that would
        // take the whole app down mid-request; SO_NOSIGPIPE turns it into a normal EPIPE write error.
        var noSigPipe: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        // bound the blocking read so a stalled client can't park the serial accept loop forever — a
        // timed-out read returns EAGAIN, which readLine treats as a read error and closes the connection.
        var readTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))

        // bound the blocking response write too — a large `session.text --all` reply may not fit the socket
        // buffer in one write, so a client that stopped reading would otherwise wedge the accept loop.
        var writeTimeout = timeval(tv_sec: writeTimeoutSeconds, tv_usec: 0)
        setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &writeTimeout, socklen_t(MemoryLayout<timeval>.size))

        guard let line = readLine(conn) else {
            writeResponse(conn, ControlResponse(ok: false, error: "request too large or read failed"))
            return
        }

        let request: ControlRequest
        do {
            request = try JSONDecoder().decode(ControlRequest.self, from: line)
        } catch {
            writeResponse(conn, ControlResponse(ok: false, error: "invalid request: \(error.localizedDescription)"))
            return
        }

        // fast-path read-only window queries from a thread-safe cache, WITHOUT hopping to the main
        // actor: a window close can briefly stall the main thread (surface teardown / re-render), and
        // the serial accept loop would otherwise go unresponsive to `window.list` polls behind it.
        if let cached = server.fastPathResponse(for: request) {
            writeResponse(conn, cached)
            return
        }

        // hop to the main actor to execute, blocking this background thread until it returns. dispatch
        // refreshes the window cache itself (single main-actor execution), so the fast path reflects
        // this command's mutations without a second hop that could queue behind a post-close stall.
        let response = runBlocking { await server.dispatch(request) }
        writeResponse(conn, response)
    }

    /// Read bytes from `conn` up to (and excluding) the first newline, capping at `maxLineBytes`. Returns
    /// nil on EOF-before-newline, read error, the `maxLineBytes` cap, or the `readDeadlineSeconds` overall cap.
    nonisolated private static func readLine(_ conn: Int32) -> Data? {
        var buffer = Data()
        var byte: UInt8 = 0
        // overall deadline: SO_RCVTIMEO bounds each read, but a slow trickle (a byte per sub-timeout
        // interval) would otherwise loop forever without a newline. cap the total read time too.
        let deadline = DispatchTime.now() + .seconds(readDeadlineSeconds)
        while true {
            if DispatchTime.now() > deadline { return nil }
            let n = read(conn, &byte, 1)
            if n == 0 { return buffer.isEmpty ? nil : buffer } // EOF: accept a trailing line without newline.
            if n < 0 {
                if errno == EINTR { continue } // a signal interrupted the blocking read; retry
                return nil
            }
            if byte == UInt8(ascii: "\n") { return buffer }
            buffer.append(byte)
            if buffer.count > maxLineBytes { return nil }
        }
    }

    /// Encode `response` and write it back as a single newline-terminated line.
    nonisolated private static func writeResponse(_ conn: Int32, _ response: ControlResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            // overall deadline: SO_SNDTIMEO bounds each write(), but a slow-drip reader making a few bytes
            // of progress per interval never trips it, so cap the total write time like readLine's deadline.
            let deadline = DispatchTime.now() + .seconds(writeDeadlineSeconds)
            while offset < data.count {
                if DispatchTime.now() > deadline { return }
                let n = write(conn, base + offset, data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue } // retry an interrupted write
                    return
                }
                if n == 0 { return }
                offset += n
            }
        }
    }

    /// Run an async closure to completion on a fresh task, blocking the calling (background) thread until it
    /// finishes. Used to bridge the synchronous read loop to the main-actor dispatch without an actor hop on
    /// the loop thread itself.
    nonisolated private static func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    /// A minimal mutable box to ferry the async result back across the semaphore.
    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: - Dispatch

    /// Execute a request against the store/actions seam. Never throws across the socket: any failure is a
    /// `{"ok":false,"error":…}` response.
    private func dispatch(_ request: ControlRequest) async -> ControlResponse {
        // refresh the read cache within this same main-actor execution (a window mutation just ran), so
        // the background fast path sees the new state without a separate hop that could stall.
        defer { refreshWindowCache() }
        if let response = await ControlDispatcher(actions: self).dispatch(request) {
            return response
        }
        switch request.cmd {
        case .tree, .eventsRead,
                .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename,
                .sessionReveal, .sessionMove,
                .workspaceNew, .workspaceSelect, .workspaceRename, .workspaceDelete, .workspaceMove, .workspaceFocus,
                .workspaceFilter, .workspaceColor, .workspaceIcon, .workspaceRoot, .workspaceCollapse,
                .workspaceExpand,
                .sessionSplit, .sessionSplitClose, .sessionScratch, .sessionFileTree, .sessionMarkdown,
                .sessionFocus, .sessionResize,
                .surfaceZoom,
                .sessionStatus, .sessionAgent, .sessionFlag, .sessionSeen, .sessionRestore, .notify,
                .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .configReload, .themeSet, .themeList,
                .sidebar, .sidebarMode, .sidebarExpand, .sidebarCollapse, .sessionType, .sessionCopy,
                .sessionPaste, .sessionSelectAll,
                .sessionSearch, .sessionOverlayOpen, .sessionOverlayClose, .sessionOverlayResize,
                .sessionOverlayResult, .sessionBackground, .sessionText, .quick, .quickType, .quickText,
                .windowNew, .windowList, .windowSelect,
                .windowClose, .windowRename, .windowDelete, .windowResize, .windowMove, .windowZoom,
                .windowFullscreen, .windowMinimize, .restoreClear, .dashboard:
            return ControlResponse(ok: false, error: "control dispatcher did not handle \(request.cmd.rawValue)")
        case .debugAppearance:
            return setDebugAppearance(args: request.args)
        case .pickOpen, .pickResult, .pickCancel:
            preconditionFailure("pick command returned nil from ControlDispatcher")
        case .sessionHudOpen, .sessionHudUpdate, .sessionHudClose:
            preconditionFailure("hud command returned nil from ControlDispatcher")
        }
    }

    /// UI-TEST-ONLY seam: force the app-level appearance so an XCUITest can simulate a macOS light/dark
    /// flip deterministically (macOS XCUITest has no API to change the system appearance). Setting
    /// `NSApp.appearance` changes `NSApp.effectiveAppearance`; this arm ALSO posts
    /// `.rookSystemAppearanceChanged` directly, so the REAL flip path (scheme sync → debounced
    /// zoom-preserving reload) is exercised end to end without depending on whether KVO fires on an
    /// explicit set (production relies on the KVO observer firing on a genuine system flip). Refused
    /// outside an XCUITest launch, and deliberately EXEMPT from the four-point keep-in-sync (no rookctl
    /// subcommand, absent from the catalog/skill) — test scaffolding, not a control surface. Setting
    /// echoes the resulting effective side in `result.text`; the BARE form (no name) reads the side the
    /// last config feed applied (`SettingsModel.lastAppliedIsDark`), which a test polls to assert the
    /// flip actually drove the reload — a suppressed flip leaves it on the old side.
    private func setDebugAppearance(args: ControlArgs?) -> ControlResponse {
        guard ContentView.isUITestLaunch else {
            return ControlResponse(ok: false, error: "debug.appearance is a UI-test-only seam")
        }
        guard args?.name != nil else {
            return ControlResponse(ok: true, result: ControlResult(
                text: settingsModel.lastAppliedIsDark ? "dark" : "light"))
        }
        guard let side = trimmed(args?.name), side == "light" || side == "dark" else {
            return ControlResponse(ok: false, error: "debug.appearance requires light|dark")
        }
        // take the validated `side` directly — do NOT re-read `currentIsDark()`, whose
        // `effectiveAppearance` may not have settled synchronously right after the set (the same
        // "take the delivered value, never re-read" rule the production `SystemAppearanceObserver` follows).
        let isDark = side == "dark"
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        // drive the flip pipeline directly (a duplicate KVO post, if any, is same-side-suppressed).
        NotificationCenter.default.post(name: .rookSystemAppearanceChanged, object: nil,
                                        userInfo: ["isDark": isDark])
        return ControlResponse(ok: true, result: ControlResult(text: isDark ? "dark" : "light"))
    }

    /// Clear every open session's saved foreground command (the restore-running-command capture) and
    /// persist, so the next launch restores plain shells. The live fields are normally already nil
    /// (consumed at restore); the SAVE is what wipes the on-disk copy from the last quit, also closing
    /// the force-quit re-fire window. Drives `restore.clear` / `rookctl restore clear`. App-global like
    /// `keymap.reload` (no `--window` selector — it clears every open window).
    ///
    /// Also disarms the PENDING capture slots, where a launch restore parks the argv until each surface
    /// mounts: the socket binds before the later windows' decks have mounted, so a clear arriving in that
    /// gap would answer ok and then watch those windows run the commands anyway. The `session.restore`
    /// pins are deliberately untouched — they are sticky, and this command clears captures.
    func clearRestoreCommands() -> ControlResponse {
        for session in library.allOpenSessions() {
            session.foregroundCommand = nil
            session.splitForegroundCommand = nil
            session.clearPendingForegroundCommands()
        }
        library.saveAllOpen()
        return ControlResponse(ok: true)
    }

    /// Project a window's workspace tree into the wire `ControlTree`, marking the active session and the
    /// active workspace (the one owning the selected session).
    func buildTree(in store: AppStore) -> ControlTree {
        let shellBasename = ProcessInfo.processInfo.environment["SHELL"].map(CommandRestore.basename)
        // the projected window owns its quick terminal; find its id by store identity to read the live
        // QuickTerminalController.isVisible (a nil controller — never opened, or the window is tearing
        // down — reads as not visible).
        let windowID = library.windowID(for: store)
        // the projected window's dashboard controller (nil until WindowContentView registers it), read
        // LIVE for the four dashboard read-backs — tree-only, since the keyboard-driven dashboard bypasses
        // the command path and a cached copy would go stale (same reason as zoomedSurface/quickVisible).
        let dashboard = DashboardControllerRegistry.shared.controller(for: windowID)
        return store.controlTree(
            foreground: { session in
                (session.surface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.running(for: $0, shellBasename: shellBasename)
                }
            },
            splitForeground: { session in
                (session.splitSurface as? GhosttySurfaceView).flatMap {
                    ForegroundProcess.running(for: $0, shellBasename: shellBasename)
                }
            },
            fontSize: { ($0.addressableSurface as? GhosttySurfaceView)?.currentFontSize() },
            splitFontSize: { ($0.splitSurface as? GhosttySurfaceView)?.currentFontSize() },
            scratchFontSize: { ($0.scratchSurface as? GhosttySurfaceView)?.currentFontSize() },
            quickVisible: { windowID.flatMap { QuickTerminalRegistry.shared.controller(for: $0)?.isVisible } ?? false },
            zoomedSurface: { windowID.flatMap { TerminalZoomRegistry.shared.controller(for: $0)?.target?.controlID } },
            // Resolve through the projected window's registry entry on every tree build. This is deliberately
            // tree-only: window.list is cache-backed, so mirroring a GUI-resolved pick there would go stale.
            pickPending: { windowID.flatMap { PickRegistry.shared.controller(for: $0)?.pending?.id } },
            dashboardMembers: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.members.map(\.controlRef)
            },
            dashboardHighlighted: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.highlighted?.controlRef
            },
            dashboardFontSize: {
                guard let dashboard, dashboard.isOpen else { return nil }
                return dashboard.appliedFontSize
            },
            dashboardFontMode: {
                guard let dashboard, dashboard.isOpen else { return nil }
                switch dashboard.fontMode {
                case .auto: return "auto"
                case .fixed: return "fixed"
                case .untouched: return "untouched"
                }
            }
        )
    }

    /// Creates a session in `workspaceID` of `store` with the `session.new` args (cwd default $HOME,
    /// optional command/name), focuses it when it lands in the frontmost window (so a keymap `session new`
    /// opens focused like the GUI New Session; a background `--window` target keeps focus), and returns the
    /// new id. Shared by the id- and name-addressed paths of the `.sessionNew` arm. `at` is the anchor-relative
    /// insertion slot for `--after`/`--before` (clamped in `AppStore`); nil appends. With `options.noSelect`
    /// the session is created in the background — `addSession` skips selecting it and the focus call is
    /// suppressed, leaving the current selection and focus untouched. `options.wait` holds a `--command`
    /// session open after the command exits. `options.shell` is persisted on the session, so every pane it
    /// ever spawns — main, split, scratch, and the same panes after a relaunch — runs the caller's shell.
    func makeSessionResponse(in store: AppStore, workspaceID: UUID,
                             options: ControlSessionCreateOptions, at index: Int? = nil) -> ControlResponse {
        // an explicit --cwd wins; else the destination workspace's root (when set and still a real
        // directory); else $HOME. Mirrors the GUI path (AppActions.resolvedNewSessionCwd).
        let root = AppActions.existingDirectory(store.workspaces.first { $0.id == workspaceID }?.root)
        let cwd = options.cwd ?? root ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd,
                                             command: options.command, name: options.name,
                                             wait: options.wait ?? false, at: index,
                                             select: !options.noSelect, shell: options.shell) else {
            return ControlResponse(ok: false, error: "could not create session")
        }
        if !options.noSelect, store === library.activeStore { actions.focusActiveSession() }
        return ControlResponse(ok: true, result: ControlResult(id: session.id.uuidString))
    }

    /// `value` trimmed of surrounding whitespace, or nil if absent or blank after trimming.
    func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Internal, not private: the command arms live in `ControlServer+*.swift` extensions, which cannot
    /// reach a private member declared here.
    func log(_ message: @autoclosure () -> String) {
        NSLog("rook: %@", message())
    }
}
