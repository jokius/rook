---
paths:
  - "rookUITests/**/*.swift"
---

## UI tests

- `rookUITests/` is an XCUITest target that launches the real app and drives the sidebar (rename,
  close, move, drag, add-session) through the accessibility API — the coverage the host-free `rookCore`
  unit tests can't provide.
  Run with `xcodebuild test -project rook.xcodeproj -scheme rook -destination 'platform=macOS'`.
- **PRE-FLIGHT, BEFORE EVERY RUN THAT TAKES OVER THE KEYBOARD AND SCREEN: check the active keyboard
  layout and switch it to ABC, then put it back when the run ends.**
  This is the FIRST step of an XCUITest run, ahead of building or picking `-only-testing` — the maintainer
  has given standing permission to flip the layout for a run, so just do it rather than asking.
  A Cyrillic (or any non-latin) layout does not fail loudly; it corrupts a whole CLASS of results at once —
  `app.typeText` reaches the shell as Cyrillic, `typeKey` chords stop matching menu key equivalents
  (⌘W/⌘⇧D/Ctrl-C), and the run comes back with assertion failures that read exactly like product bugs.
  Triage that starts from such a run blames the code and "fixes" tests that were never broken, which costs
  far more than the two seconds this check takes.
  Read the ACTIVE layout with `defaults read com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID`
  (verified to track a live switch).
  **Do NOT read `AppleSelectedInputSources` to answer this question** — it lists the ENABLED sources, and it
  answered `ABC` on a machine whose active layout was `com.apple.keylayout.Russian`, i.e. it hands out a
  false all-clear.
  Switch (and confirm) with the Carbon TIS API, the only way that takes effect live — a `defaults write` of
  the key above does not:
  ```swift
  // swift /tmp/kbd.swift        -> print the active layout id
  // swift /tmp/kbd.swift ABC    -> select the enabled layout whose id ends with ABC, then print it
  import Carbon
  let want = CommandLine.arguments.dropFirst().first
  func now() -> String {
      guard let s = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { return "unknown" }
      return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
  }
  if let want {
      let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
      for s in (TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]) ?? [] {
          guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID),
                (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String).hasSuffix(want) else { continue }
          TISSelectInputSource(s); usleep(300_000); break
      }
  }
  print(now())
  ```
  **Do the switch in the SAME shell command that launches `xcodebuild`, not as an earlier separate step** —
  measured: a layout set to ABC was back on `com.apple.keylayout.Russian` minutes later, because the user
  kept typing (and macOS can hold an input source PER APP, so focusing the app under test can flip it back
  on its own).
  A check that passed when you ran it proves nothing about the run you start afterwards.
  Print the layout again when the run ends, so the log says what the run actually executed on.
  The same pre-flight covers the other two ENVIRONMENTAL blockers documented below, which are equally
  invisible in the failure text: a screen-occluding window (the synthesize-event timeout) and an open system
  authentication prompt.
  Check all three before reading a single assertion failure as a product bug.
  This is not hypothetical bookkeeping: a full 220-test run on a Cyrillic layout came back with 40 failures,
  22 of them pure layout/occlusion noise spread across six suites, and it took a fan-out of ten agents to
  work out which of the 40 were real.
- **POST-RUN, EVERY TIME: sweep up after the run — it litters OUTSIDE the repo, where only the maintainer
  trips over it.**
  The per-test state needs nothing from you: `ControlAPITestCase.tearDown` already removes its
  `ROOK_STATE_DIR`, its socket, and its marker dir.
  What it does NOT cover:
  1. **Screenshots on the Desktop.**
     macOS writes captures there as PNG by default (`com.apple.screencapture location` unset), and a run
     whose synthesized chords reach the SYSTEM instead of the app can trip ⌘⇧3/⌘⇧4/⌘⇧5 — the suites fire
     plenty of ⌘⇧-shaped chords (⌘⇧D/N/E/Y/J/←), and a mis-resolved one lands on the capture shortcut.
     Observed for real after a Cyrillic run: a pile of screenshots on the Desktop that the maintainer found,
     not the run.
     **You almost certainly cannot clean these yourself — `~/Desktop` is TCC-protected and `ls` answers
     `Operation not permitted`** — so SAY SO: tell the user to check the Desktop, rather than assuming the
     screen is clean because your `ls` returned nothing.
     The layout pre-flight above is the prevention; this is the cure.
  2. **`.xcresult` bundles in `build/DerivedData/Logs/Test/`.**
     Measured at 414 MB for TWO runs, and gitignored — so nothing ever complains and they accumulate
     silently.
     Delete the ones you are done reading.
  3. **Anything you built or wrote outside the session scratchpad** (a `/tmp` helper, a compiled probe), and
     any dev instance you launched — `kill <pid>`, never `pkill` (see the root CLAUDE.md ban).
  4. **The keyboard layout you switched** — put it back where you found it.
- Tests pass `ROOK_STATE_DIR` (a temp dir) via launch environment to isolate persistence;
  the app honors it in `rookApp.restoredStore()`.
  The native `Open Directory…` panel is system UI, verified manually rather than in XCUITest.
- **Launch the app with `app.launchForUITest()` — never bare `app.launch()`.**
  Apple bug **FB11763863**: on macOS 15+/Xcode 16+ (incl.
  26) a SwiftUI `WindowGroup` app launched by another process (XCUITest,
  launchd) frequently **never auto-presents its window** — dock icon shows,
  no window, the scene's `.task`/`.onAppear` never fire, `NSApp.windows` stays empty,
  so elements exist in the AX tree (`waitForExistence` passes) but are un-hittable and every interaction
  silently no-ops.
  It is OS-version dependent, so the SAME app code "worked before" a macOS upgrade and breaks after.
  The fix lives in `AppDelegate.bringUITestWindowsForward` (UITest path):
  when no real window exists it fires a programmatic **reopen** — `NSWorkspace.shared.open(Bundle.main.bundleURL)`,
  the same event a dock click sends — and SwiftUI then creates the window.
  `XCUIApplication.activate()` / `NSApp.activate()` / `orderFrontRegardless()` / `.defaultLaunchBehavior(.presented)`
  do NOT help (the window is never created, not just un-focused).
  `launchForUITest()` (in `XCUIApplicationSidebarIsolation.swift`) feeds the `ROOK_UITEST_FORCE_SIDEBAR_VISIBLE`
  sentinel via launch **environment** (NOT `launchArguments` — args trip a related variant),
  launches, and `activate()`s.
  The reopen re-triggers macOS state restoration, so the `Settings` window is marked **non-restorable**
  (`SettingsView`'s `NonRestorableWindow`) or a stale Settings window resurrects and steals key focus.
  To diagnose this class of bug, `NSLog` `NSApp.windows.count` on a timer and read it via `log show --predicate 'eventMessage CONTAINS "…"'`;
  `total=0` for seconds = "never created".
  See [[reference_swiftui-windowgroup-no-window-xcuitest]].
- **Open a Settings tab via the retrying `settingsControl(tab:control:)` helper,
  not a one-shot `app.buttons[tab].click()`.** The reopen can leave a half-open/non-key Settings window
  that silently drops the first tab click; `settingsControl` re-clicks each tick until the expected control
  is hittable, which is what makes the Settings tests non-flaky.
- **Add a UI test when you add UI functionality**
  — don't ship UI behavior with only `rookCore` model-level unit tests.
  For behavior the accessibility tree can't observe (the Metal `GhosttySurfaceView`,
  transient non-persisted state), drive it through an observable side effect:
  e.g. the split test types `tty > <file>` into the focused pane and compares the written tty to verify
  which shell received the keystrokes and that focus follows.
- **Simulating a macOS light/dark flip: the `debug.appearance` control seam.**
  macOS XCUITest has no API to change the system appearance, so `AppearanceFlipUITests` drives the
  UI-test-only `debug.appearance` command (`light`|`dark`), which sets `NSApp.appearance` AND posts
  `.rookSystemAppearanceChanged` directly, driving the REAL flip path (scheme sync → debounced
  zoom-preserving reload) end to end.
  Production follows the appearance via an app-level KVO observer on `NSApplication.effectiveAppearance`
  (`SystemAppearanceObserver`); the seam posts the notification itself so the test does not depend on
  whether KVO fires on an explicit `NSApp.appearance` set.
  The arm is refused outside an XCUITest launch and is keep-in-sync EXEMPT (see [[control-api]]).
  Set an explicit STARTING side first so the test is independent of the machine's appearance,
  assert the response's echoed side to prove the flip reached the app,
  and poll the seam's BARE (read) form — it reports the last-applied side — to prove the flip actually
  drove the reload (a suppressed flip leaves it on the old side).
  Gotcha: on the current libghostty pin `update_config` does NOT reset the runtime font zoom,
  so a wrongly-routed zoom-clearing flip only BLIPS the persisted `fontSize` nil for ~0.4 s before the
  surface's CELL_SIZE report re-persists it — assert zoom preservation by SAMPLING the snapshot
  continuously, never by one settled read (it would pass on the broken path).
- **Driving an OSC terminal title in a test (and reading it back).**
  `Session.oscTitle`/`subtitleDetail` are ephemeral (never persisted) and the second line renders as
  a SwiftUI `Text`, so test through observable side effects, not the snapshot.
  Set a title by typing/injecting `printf '\033]2;TITLE\007'; cat` into the session — the trailing `; cat`
  is **LOAD-BEARING**: a one-shot printf sets the title but the local shell returns to its prompt where
  the title is cleared again (the prompt cycle), so it reverts to the cwd basename;
  `cat` holds the foreground so no prompt redraw fires, mirroring why a real `ssh` keeps its title but
  a quick local printf "looks broken" (see [[libghostty]]).
  Type **LITERAL** `\033`/`\007` (Swift `"printf '\\033]2;…\\007'"`) so the SESSION shell's printf expands
  them — do NOT pre-expand to raw ESC/BEL bytes (e.g. a host-side `printf` building the string),
  which injects control bytes the shell's line editor reads as keystrokes and garbles the command (it
  can even fire history/ZLE widgets and run an unrelated history command).
  Read the result through an observable: **line 1** (displayName) via the `session-row` static-text **VALUE**
  (not label — see `SidebarUITests`); **line 2** (`subtitleDetail`) via the `palette-subtitle` AX id
  read as VALUE in the Go-to-Session palette.
  Gotcha: `FileManager.default.homeDirectoryForCurrentUser` resolves DIFFERENTLY in the XCUITest runner
  process vs the app, so assert a cwd second line against a stable marker like `/Users/`,
  NOT the runner's own home.
  (`rookctl session.type` is the control-channel equivalent of the typed injection;
  `rookctl tree --json` now carries the raw `title`, which an e2e can poll instead of reading the AX
  tree.
  See `SessionSubtitleUITests` + `ControlAPIUITests.testTreeExposesOscTitle`.)
- **Driving an `NSOutlineView` row drag from XCUITest needs three things,
  ALL load-bearing (see `ReorderUITests.dragRow`).** Getting any one wrong means the drag silently does
  nothing — `validateDrop`/`acceptDrop` never fire and the model never mutates:
  (1) **SELECT the source row first** (`from.click()` + a short run-loop drain) — the outline only begins
  a drag from the *selected* row, so dragging an unselected row (e.g. a middle row that wasn't the last
  one touched) never starts a drag session at all.
  This was the actual cause of a "downward drag doesn't work" red herring — the up-drag happened to drag
  the just-renamed (hence selected) row, the down-drag dragged an unselected one.
  (2) **Drag via `coordinate(withNormalizedOffset:)`, NOT element-to-element** — a row's AX element is
  the recycled `NSTextField` inside the cell, while the drag tracking lives in the outline;
  a coordinate drag targets the outline machinery directly.
  (3) **Use the mouse-native `click(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)`,
  NOT the touch `press(forDuration:thenDragTo:)`** — `pressForDuration:` is the touch-events API and
  delivers an `NSDraggingInfo` only intermittently to AppKit.
  One drag per test launch is the reliable unit — a *second chained* native drag in the same method does
  not reliably re-start a drag session (it ends up testing XCTest's event injector,
  not the drop delegate), so cover a second direction in a separate `func test…` (fresh launch),
  never by chaining.
  To diagnose a non-delivering drag, `NSLog` from `validateDrop`/`acceptDrop` and read it with `log show --last 90s --predicate 'eventMessage CONTAINS "…"'`:
  *zero* events = the drag never started (selection/gesture problem); events present but the wrong `dest`
  = a drop-resolution bug in the delegate.
- **NEVER start a UI run — or ANYTHING else that seizes the screen, keyboard, or focus — without the user
  saying so in the CURRENT message.**
  The maintainer works on other projects on the same machine WHILE the agent runs, so a UI pass does not
  merely risk colliding with a hand-off (the note below): it interrupts whatever they are actually doing,
  synthesizing keystrokes into their windows for minutes.
  This covers `xcodebuild test` on `rookUITests`, synthetic `CGEvent`s, and programmatic keyboard-layout
  switching (`TISSelectInputSource`) alike.
  So: run everything that is SAFE (build, `make lint`, `swift test`, a dev-instance launch) on your own,
  then TELL the user a UI run is pending and OFFER it — never launch it silently, never "just quickly".
  Committing without the UI pass is fine for a narrow, otherwise-verified change; say so in the report
  instead of buying coverage with their screen.
  The same applies to any check needing their HANDS (a keystroke on a non-latin layout,
  a visual confirmation): state what is needed and WAIT.
- **NEVER run XCUITests while the user is interacting with a handed-off dev build — it HIJACKS their
  screen.** XCUITest launches/activates app instances and synthesizes REAL keyboard + mouse events on
  the live screen (`typeText`/`typeKey`/`click` drive the actual cursor and focus),
  so a UI run while the user is trying a build types into their windows and steals focus — it interrupts
  their work, hard.
  When you hand the user a build to try ("try it", a launched demo instance),
  do NOT start any `xcodebuild test` (UI target) until they say they're done.
  Run UI tests BEFORE handing off, or AFTER the user is finished — never concurrently with their hands-on
  testing, and never "in parallel/background" (background only hides the output,
  not the on-screen event synthesis).
  Host-free `swift test` is fine anytime (no screen interaction).
- **Dismiss the Settings window by ITS OWN close button.**
  ⌘W closes it too now and leaves the deck alone — pinned by
  `SettingsUITests.testCommandWClosesTheSettingsWindowNotTheSession` — but ONLY while Settings is the KEY
  window.
  The reopen path can leave it open and non-key, and there ⌘W reaches the terminal window behind it and
  takes the seeded session with it — which a session-row-count oracle reads as a workspace COLLAPSE rather
  than as a closed session, so the test fails for the wrong reason (or worse, passes for it).
  Target the window by a control that only that tab has:
  `app.windows.containing(.any, identifier: <a control on the tab>).firstMatch.buttons[XCUIIdentifierCloseWindow].click()`
  (see `SidebarUITests.testWorkspaceRowClickStopsTogglingAfterLiveSettingsFlip`).
- **Test cadence — ASK before a full UI run; don't default to it.**
  The host-free `cd rookCore && swift test` is fast (~0.2 s) — always run it.
  The XCUITest suite is SLOW (~75 s for one class, ~460 s for all 77) and re-runs unaffected tests,
  so a full UI run is NOT a default pre-commit gate.
  For an isolated change, run ONLY the affected target/case (`xcodebuild test … -only-testing:rookUITests/SplitUITests`,
  or a single method like `…/SidebarUITests/testRenameSession`).
  Before committing UI-affecting work, ASK which UI-test scope is wanted and RECOMMEND one:
  focused for self-contained changes; full only for foundational/cross-concern work (app launch,
  signing/bundle, the eager deck, window/scene wiring, shared chrome).
  Don't burn minutes re-running the whole suite when the change is self-contained.
- **After editing a TEST file, rebuild the test bundle with `build-for-testing` — `test-without-building`
  runs the STALE bundle.**
  `xcodebuild build` (or `make build`) builds only the APP target, NOT the `rookUITests` bundle.
  So `xcodebuild build` then `test-without-building` runs the OLD compiled test against the NEW app —
  the source edit is silently ignored.
  The symptom is confusing: the run reports `Executed 0 tests` with a crash/`Restarting after unexpected
  exit` line and the named test under "Failing tests", which looks like an app launch crash — but the
  xcresult `Failure Message` is an ordinary `XCTAssertTrue failed` from the OLD assertion (e.g. it still
  looks for a control the new UI renamed).
  Fix: run `xcodebuild build-for-testing …` (builds app + test bundle) before `test-without-building`, or
  just `xcodebuild test …` (builds then tests).
  Read the real reason from the xcresult (`xcrun xcresulttool get test-results tests --path <xcresult>`,
  find the `Failure Message` node) rather than trusting the "0 tests / crash" summary.
- **Driving a Picker in XCUITest depends on its style.**
  A `.segmented` Picker exposes each option as a hittable descendant by label — match
  `picker.descendants(matching: .any).matching(label == "X").firstMatch` and `.click()` it directly.
  A default/menu Picker (macOS Form dropdown, e.g. Font/Theme/Toolbar) does NOT — `picker.click()` to
  open the popup, then click `app.menuItems["X"]` (see `SettingsUITests.testNewSessionDirectoryPickerPersists`
  / `testToolbarModePickerPersists`).
  Changing a Picker's style therefore requires updating its test's interaction, not just the label.
- **A screen-occluding overlay app (HazeOver) makes `app.typeText`/`typeKey` fail with `Failed to synthesize event: Timed out while synthesizing event`**
  — a ~90 s hang that ends the test with NO `XCTAssert` failure (the keyboard event never reaches the
  covered window; the run log shows `Synthesize event` → `Failed: Timed out` ~64 s apart).
  It is ENVIRONMENTAL, not a test-logic or app bug: the SAME test passes in ~13 s once HazeOver is quit.
  Treat a `synthesize event` / `Unable to find hit point` timeout (as opposed to a real assertion failure)
  as an occlusion symptom — quit HazeOver and clear covered/minimized/Spaces windows,
  then re-run before suspecting the test or the fix.
  Distinct from FB11763863 (window never created → AX tree empty); here the window exists but is covered.
- **`XCUIApplication.terminate()` HARD-KILLS — it does NOT fire `applicationWillTerminate`.** A test
  that needs the app's graceful-quit path (anything in `applicationWillTerminate`:
  the restore-running-command capture, a quit-flush write) must quit with **⌘Q** (`app.typeKey("q", modifierFlags: .command)`
  then `app.wait(for: .notRunning, timeout:)`), NOT `terminate()`.
  The quit-confirm modal is auto-skipped under XCUITest (`ContentView.isUITestLaunch` → `.terminateNow`),
  so ⌘Q quits cleanly AND runs `applicationWillTerminate`.
  Verified by instrumenting the top of `applicationWillTerminate` to a `/tmp` file:
  empty under `terminate()`, written under ⌘Q.
  (`MultiWindowUITests` survives `terminate()` only because the open-set is also saved by in-session
  structural saves, NOT because the quit-flush ran.) This is the same write-to-a-temp-FILE diagnostic
  the project uses for launch-time values — `NSLog` doesn't reach the unified log from an `open -n`/XCUITest
  dev build.
- **`ghostty_surface_foreground_pid` returns the actual FOREGROUND process,
  not the session's shell.** Confirmed empirically (`tee <file>` → the captured pid/argv is `tee`,
  not `zsh`).
  The restore-running-command capture skips ONLY an IDLE shell-at-prompt (`CommandRestore.isIdleShell`:
  a known-shell argv0 with no payload argument, only `-flags`).
  A shell RUNNING something IS captured: a `#!/bin/sh` wrapper script (its foreground is `/bin/sh <script>`,
  the real-world `cld` claude-code bug) and a `sh -c '…'` BOTH carry a payload argument and are captured
  — only a bare `-zsh`/`/bin/zsh` prompt is dropped.
  `tee <file>` is still the cleanest e2e marker: it creates its output file on start and blocks reading
  the pty, so it's the live foreground at quit, and re-running it recreates the file (a delete-then-relaunch-then-exists
  cycle is the observable proof).
  `RestoreCommandUITests.testRestoreReRunsShellScriptWrapper` covers the shell-with-payload case via
  `sh -c 'tee …; true'` (a compound list keeps `sh` the foreground) — NOT an executable script file,
  since the runner writes its sandboxed temp dir and the app can't exec a script from there (a plain
  `tee` marker writes there fine, but exec is blocked).
- **Faking an AGENT foreground (for the resume-agent-conversations e2e): rename argv[0] in a SUBSHELL,
  `(exec -a claude tee <marker>)` — the parens are LOAD-BEARING.**
  `AgentKind.classify` keys on the argv[0] basename, and the sandboxed runner cannot drop a real
  executable named `claude` for the app to run, so renaming `tee`'s argv[0] is the way to fake an agent
  that is also a live, blocking foreground process.
  A BARE `exec -a claude tee …` (no parens) REPLACES the login shell, and libghostty then reports NO
  foreground pid at all (the pty's foreground process is its own direct child), so the quit capture comes
  back EMPTY and the whole restore path silently no-ops — the test fails with an empty
  `foregroundCommand`, not with a resume bug.
  Forking first (the subshell) keeps the shell as the parent and the fake agent as a genuine foreground
  child, which is what `ghostty_surface_foreground_pid` reports.
- **A UI test that types a shell command FAILS SILENTLY on a non-latin keyboard layout.**
  `app.typeText` synthesizes real keystrokes, so with a Cyrillic layout active the command reaches the
  shell as Cyrillic: the marker file is never created and the test fails on an unrelated-looking
  assertion (or hangs, or scatters the text into whatever app has focus).
  It is ENVIRONMENTAL, like the HazeOver occlusion above: switch the layout to latin and re-run before
  suspecting the test.
  The damage is not confined to typed TEXT: a `typeKey` chord is matched against the character the layout
  PRODUCES, so ⌘W, ⌘⇧D and Ctrl-C stop reaching their menu items too, and a run on Cyrillic returns a
  scattering of "the shortcut did nothing" failures across unrelated suites.
  The pre-flight at the top of this file is what keeps this from being discovered after the fact.

- **The `pick.open` picker reuses the command palette, so its accessibility ids are DIFFERENT ones on the
  same views.**
  `CommandPalette` swaps them on whether it was handed explicit items: the panel is `command-palette` for the
  built-in feeds and `pick-palette` for a control-driven picker, the click-catcher likewise `palette-scrim`
  vs `pick-scrim` (`Palette.swift`).
  Rows are `palette-item-<item.id>`, so a test drives a picker by the id the CALLER supplied — which is what
  makes a pick e2e readable, since the ids are the test's own strings rather than UUIDs it has to capture.
  A test that queries `command-palette` while a pick is up finds nothing and fails looking like a timing
  problem; it is the wrong identifier, not a slow mount.
- **`Failed to initialize for UI testing: "System authentication is running."` is ENVIRONMENTAL, not a broken
  suite.**
  The XCUITest runner cannot start at all while macOS has a system authentication prompt open — a Touch ID
  sheet, a keychain or admin password dialog, an App Store / System Settings confirmation — and the failure
  arrives as `com.apple.LocalAuthentication Code=-4` with `Authentication canceled`, before a single test
  runs.
  `xcodebuild` then reports the whole action as `** TEST FAILED **` with ZERO test cases executed, which
  reads exactly like a suite that blew up on launch.
  Tell them apart by the count: a real failure names a test case, this one names none.
  The fix is to dismiss the prompt on screen and re-run; nothing in the test bundle needs touching.
  Same family as the HazeOver occlusion and the non-latin layout above: check the machine before suspecting
  the code.
