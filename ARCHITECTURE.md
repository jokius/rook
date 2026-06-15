# Architecture

`agt` is two modules: a host-free model package and an app target that adds the SwiftUI shell and the libghostty bridge.

## Module split

### agtCore (Swift package)

`agtCore/` is a local SwiftPM package that depends on Foundation and Observation only. It imports no GhosttyKit, AppKit, or Metal, so its tests run host-free via `swift test` with no app host, no `TEST_HOST`, and no Metal device. It holds the entire model and persistence layer:

- `Session` (`@Observable @MainActor final class`): one shell. Fields are `id`, `customName`, `currentCwd`, `initialCwd`, and the `surface` slot. `displayName` returns a non-blank `customName` (trimmed, matching `renameSession`), otherwise the basename of `currentCwd ?? initialCwd`. Basename pins: root `/` stays `/`, a trailing slash is ignored (`/a/b/` → `b`), and an empty path shows the home shorthand `~`.
- `Workspace` (`struct`): a stable `id`, a `name`, and an ordered array of `Session` references.
- `AppStore` (`@Observable @MainActor final class`): the workspace tree plus a single `selectedSessionID`. Owns the mutations (`addWorkspace`, `addSession`, `selectSession`, `renameSession`, `renameWorkspace`, `closeSession`, `moveSession`) and the persistence hooks (`snapshot`, `restore`, `save`). Every structural mutation — including `selectSession` (so a sidebar click persists immediately) — calls `save()`, as does app quit. A live `cd` does **not**: the PWD report updates `currentCwd` without saving, because OSC 7 fires on every prompt redraw and persisting each one would thrash the disk. The new cwd rides along on the next structural save or on quit, so a crash loses only cwd changes since the last save.
- `TerminalSurface` (`@MainActor protocol`, `AnyObject`): the minimal surface contract (`teardown()`) that `Session` owns. The concrete conformer lives in the app target, which keeps `agtCore` free of GhosttyKit.
- `Snapshot` and friends (`Codable, Equatable, Sendable` value types): the persisted form of the tree.
- `PersistenceStore`: JSON load/save at `~/Library/Application Support/agt/workspaces.json`, with the storage directory injectable for tests.

### App target (XcodeGen project)

The app target adds the SwiftUI views (`ContentView`, `SidebarView`, `TerminalView`) and the libghostty bridge (`GhosttyApp`, `GhosttyCallbacks`, `GhosttyResources`, `GhosttySurfaceView`). The bridge files are adapted from macterm (MIT). The app links `GhosttyKit.xcframework` and depends on the `agtCore` package.

Selection is a single `Session.ID?` rather than a `(workspaceID, sessionID)` tuple, because tuples are not `Hashable` and cannot back `List(selection:)`. Workspace rows are non-selectable disclosure headers; only sessions are detail targets, so one id suffices and the owning workspace is derived.

## Surface ownership

The surface lifecycle is the rule that keeps the C interop safe.

- `Session` owns its `GhosttySurfaceView` through `Session.surface`, marked `@ObservationIgnored` so assigning the lazily-created view never churns observation. Only `customName` and `currentCwd` are observed, so the sidebar refreshes when a rename or a PWD report lands.
- The detail pane swaps surfaces via `.id(session.id)`. `TerminalView(session).id(session.id)` gives each session its own representable identity. Switching sessions dismantles the old `TerminalView` and makes a new one, but because the surface is owned by the `Session` (not the representable), the old shell survives and the new session's `makeNSView` returns its cached view.
- `dismantleNSView` is a no-op. The surface is freed in exactly one place: `destroySurface()`, reached through `TerminalSurface.teardown()` when `AppStore.closeSession` removes the session. This single-owner, single-free rule is what makes passing the view as unretained `userdata` to libghostty safe.

## Concurrency contract at the C boundary

Swift 6 strict concurrency (`complete`) is on. The C-callback boundary is the highest-risk area and follows an explicit contract.

- The callback router, `GhosttyCallbacks`, is a `final class` marked `@unchecked Sendable` and is deliberately **not** `@MainActor`. It holds no mutable state. The C `@convention(c)` closures run synchronously off whatever thread libghostty calls from; they capture nothing and reach Swift through the `GhosttyApp.shared` singleton.
- Every `@MainActor` state touch from a callback hops through `DispatchQueue.main.async`. Any C string is copied into a Swift `String` value **before** the hop, because the `char*` is only valid for the synchronous callback duration. For example, the PWD callback builds `String(cString:)` in the nonisolated context, then dispatches `view.applyPwd(pwd)` onto the main actor.
- `MainActor.assumeIsolated` is used in exactly one place: the `RunLoop.main` `Timer` closure that drives the 120 Hz tick. A main-RunLoop timer is proven to fire on the main thread, so the assumption is valid there. It is never used in `action_cb`, `wakeup_cb`, or `close_surface_cb`, which are not guaranteed main-thread and would crash.
- The `surface` handle and the strdup buffer array on `GhosttySurfaceView` are `nonisolated(unsafe)`. The documented invariant: they are mutated only on the main actor (create/destroy), and the C callbacks that read them are serialized by libghostty's tick model.
- Passing the view as unretained `userdata` is valid only while the surface-free ordering holds: the `Session` retains the view until `destroySurface()`, which is the only place `ghostty_surface_free` runs. The `close_surface_cb` therefore only recovers the view and dispatches to the main actor; it never closes or frees synchronously.
- `Session` and `AppStore` are never made `Sendable`/`actor` explicitly; a `@MainActor` class is already implicitly `Sendable` via isolation. The `Snapshot` value types are `Sendable`, built on the main actor and handed to the file writer as a value.

## Load-bearing fragile points

These are the points where a small deviation produces a blank surface, broken keys, or a crash.

1. **terminfo sibling-dir layout.** libghostty derives `TERMINFO` as `dirname(GHOSTTY_RESOURCES_DIR)/terminfo` at shell spawn. `GHOSTTY_RESOURCES_DIR` points at `Contents/Resources/ghostty`, so the compiled terminfo database must sit as a direct sibling at `Contents/Resources/terminfo`. If broken, `TERM=xterm-ghostty` fails to resolve and keys break. `GhosttyResources` sets only `GHOSTTY_RESOURCES_DIR`; it never sets `TERMINFO`, because libghostty overwrites it at spawn.
2. **strdup buffer lifetime.** The `working_directory` (and later `initial_input`) `const char*` config fields are backed by heap buffers that must outlive `ghostty_surface_new`, since libghostty consumes `initial_input` asynchronously after the child spawns. They are retained on the instance in a `nonisolated(unsafe)` array and freed only in `destroySurface()`.
3. **xcframework `embed: false`.** `GhosttyKit.xcframework` is linked, not embedded. Embedding breaks the signature on non-Developer-ID builds.
4. **Non-zero backing size guard.** A surface is created only once the view has a non-zero backing size; the Metal layer renders blank otherwise. If `viewDidMoveToWindow` fires with a zero-size backing, a `pendingSurfaceCreation` flag defers creation until `setFrameSize` reports a real size. This is the most common blank-surface bug.
5. **Guard `ghostty_config_new()` nil.** The config constructor returns nil on allocation failure; the init fails loudly rather than proceeding. On `ghostty_app_new` failure, the config is freed before bailing.
