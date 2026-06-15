# agt — project notes

`agt` is a native macOS SwiftUI terminal on libghostty, with a two-level workspace -> session vertical sidebar. Read `README.md` for the overview and `ARCHITECTURE.md` for the module split, surface ownership, and the C-boundary concurrency contract before changing the bridge.

## Toolchain

- The app target is generated with `xcodegen` and built with `xcodebuild` (Xcode 26). `mise` is not used; call `xcodegen`, `xcodebuild`, and `swift` directly through the scripts.
- The `agtCore` package is built and tested with `swift test` (Swift 6, strict concurrency `complete`). It is independent of Xcode and libghostty.
- `gh` is required by `scripts/setup.sh` to download release artifacts.

## Build and test commands

- `scripts/setup.sh` — download and extract `GhosttyKit.xcframework` and the ghostty resources. Idempotent; skips work if both are already present.
- `scripts/run.sh` — setup, `xcodegen generate`, `xcodebuild` Debug, then launch.
- `scripts/build.sh` — same but Release, no launch.
- `cd agtCore && swift test` — run the host-free unit tests (`scripts/test.sh` wraps this).

The app must build and `swift test` must stay green after every change.

## GhosttyKit.xcframework

- Source: the `thdxg/ghostty` fork's release artifacts, pinned in `scripts/setup.sh` to tag `build-2026-06-14`. Bump the `TAG` variable deliberately when adopting a newer libghostty.
- `setup.sh` downloads `GhosttyKit.xcframework.tar.gz` and `ghostty-resources.tar.gz` via `gh release download`.
- The xcframework, `agt/Resources/ghostty`, and `agt/Resources/terminfo` are gitignored and never committed. There is no Zig build and no submodule.
- The xcframework is linked with `embed: false` in `project.yml`. Never embed it; embedding breaks the signature on non-Developer-ID builds.

## Module boundary

- `agtCore` must not import GhosttyKit, AppKit, or Metal. Keeping it host-free is what lets `swift test` run with no app host. Model, persistence, and naming logic go here; the surface contract is the `TerminalSurface` protocol, which the app target's `GhosttySurfaceView` conforms to.
- The app target owns all SwiftUI and libghostty code.

## libghostty gotchas

- **terminfo sibling dir.** `GHOSTTY_RESOURCES_DIR` points at `Contents/Resources/ghostty`; libghostty derives `TERMINFO` as `dirname(...)/terminfo` at shell spawn, so the compiled terminfo database must be a sibling at `Contents/Resources/terminfo`. `GhosttyResources` sets only `GHOSTTY_RESOURCES_DIR` and never `TERMINFO` (libghostty overwrites it at spawn). If this layout breaks, `TERM=xterm-ghostty` fails and keys break.
- **Surface lifecycle.** `Session` owns its `GhosttySurfaceView` (`@ObservationIgnored`). The detail pane swaps surfaces via `.id(session.id)`; `dismantleNSView` is a no-op. `ghostty_surface_free` runs only in `destroySurface()` (reached via `teardown()` on close). This single-owner, single-free rule is what makes passing the view as unretained `userdata` safe.
- **Non-zero backing size.** Create the surface only when the view has a non-zero backing size, else the Metal layer renders blank. `pendingSurfaceCreation` defers creation until `setFrameSize` reports a real size.
- **strdup buffer lifetime.** `working_directory` (and `initial_input`) `const char*` buffers must outlive `ghostty_surface_new`; they are held in a `nonisolated(unsafe)` array and freed only in `destroySurface()`.

## C-callback isolation

- `GhosttyCallbacks` is `@unchecked Sendable`, not `@MainActor`. C closures capture nothing and reach Swift via `GhosttyApp.shared`.
- Copy any `char*` into a Swift `String` before hopping; every `@MainActor` touch goes through `DispatchQueue.main.async`.
- `MainActor.assumeIsolated` is allowed only in the `RunLoop.main` timer closure, never in the other callbacks.
- `close_surface_cb` only recovers the view and dispatches to the main actor; it never frees synchronously.
