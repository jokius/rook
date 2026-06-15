# agt

`agt` is a small native macOS terminal built on [libghostty](https://ghostty.org), Ghostty's terminal embedding library. The app shell is SwiftUI; only the terminal surface itself is a thin AppKit bridge, because libghostty renders into a Metal layer and needs raw key, IME, and mouse events that SwiftUI does not expose.

The distinguishing feature is a two-level workspace tree in a vertical sidebar: user-named workspaces (for example "work", "personal") each contain individual shell sessions. Ghostty itself has no vertical tabs and no workspace grouping; `agt` provides exactly that and nothing more.

## Approach

`agt` links the prebuilt `GhosttyKit.xcframework` from the [thdxg/ghostty](https://github.com/thdxg/ghostty) fork's release artifacts. There is no Zig build, no git submodule, and no source checkout of Ghostty. The xcframework and the accompanying ghostty resources (themes, shell-integration scripts, compiled terminfo database) are downloaded by `scripts/setup.sh`, are gitignored, and are never committed.

The project is split into two modules:

- `agtCore` is a host-free Swift package (Foundation and Observation only, no GhosttyKit, AppKit, or Metal). It holds the model, persistence, and naming logic and is covered by unit tests.
- The app target adds the SwiftUI views and the libghostty bridge.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the module split, the surface-ownership rules, and the concurrency contract at the C boundary.

## Requirements

- macOS 14 or later.
- Xcode 26 with `xcodegen` and `gh` on `PATH`.

## Build and run

```sh
scripts/setup.sh   # download the xcframework + ghostty resources (idempotent)
scripts/run.sh     # setup, generate the Xcode project, build Debug, launch
```

`scripts/build.sh` produces a Release build without launching. The unit tests run independently of Xcode and libghostty:

```sh
cd agtCore && swift test
```

`scripts/test.sh` is a wrapper for the same command.

## Features

- Two-level sidebar tree: workspaces, each containing sessions. One libghostty surface per session.
- Default session name is the basename of the session's working directory. Renaming a session pins a custom name; clearing it reverts to the basename.
- New session, new workspace, rename, and close (close a session from its context menu, or it closes itself when the shell exits).
- Move a session between workspaces. The context menu (`Move to`) is the guaranteed path; drag-and-drop onto a workspace header is also supported but best-effort, since cross-section drag in a `List` is unreliable. The same session instance is kept either way, so its surface and live shell survive the move.
- Auto-persist on every change and on quit; restore the tree, names, selection, and each session's working directory on the next launch.

## Restore limitations

Restore reconstructs the structure, not the running processes. Three limitations follow from the design:

1. Live processes are not reattached. A running `vim` or `npm run dev` does not survive a restart. Each restored session re-spawns a fresh login shell in its saved working directory. True process survival would require a tmux-style backend, which is out of scope.
2. The saved working directory depends on the `GHOSTTY_ACTION_PWD` callback, which only fires when the shell has Ghostty shell-integration / OSC 7 active (auto-injected for zsh, bash, fish, and nu when the shell-integration resources are present). If the working directory is never reported, a session restores to the directory it was created in.
3. The live working directory is persisted on quit and on every structural change (adding, closing, moving, renaming, or selecting a session), but not on every `cd` — OSC 7 fires on each prompt redraw, so saving each one would thrash the disk. A crash or force-quit therefore loses only the working-directory changes made since the last structural change or quit.

## Attribution

The libghostty integration files (app initialization, runtime callbacks, surface `NSView`, resource resolution) are adapted from [macterm](https://github.com/thdxg/macterm) (`thdxg/macterm`, MIT), which builds under the same Swift 6 strict-concurrency toolchain `agt` targets. The model, sidebar, and persistence are original to `agt`.
