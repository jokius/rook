---
paths:
  - "rookCore/Sources/rookCore/Keybind.swift"
  - "rookCore/Sources/rookCore/KeybindMatcher.swift"
  - "rookCore/Sources/rookCore/Keymap.swift"
  - "rookCore/Sources/rookCore/BuiltinAction.swift"
  - "rookCore/Sources/rookCore/CustomCommand.swift"
  - "rookCore/Sources/rookCore/ConfigPaths.swift"
  - "rook/Commands/CustomCommandRunner.swift"
  - "rook/AppDelegate+CloseChord.swift"
  - "rookUITests/KeymapUITests.swift"
---

## Keymap

- A user-editable, kitty-flavored keymap file (`<configDir>/keymap.conf`,
  default `~/.config/rook`) lets the user (1) **rebind built-in menu shortcuts** and (2) **define custom
  shell commands** bound to keys, the latter listed in the action palette marked `custom`.
  Like the Control API, the pure logic lives host-free in `rookCore` and the app target wires it.
  The feature is the keymap analogue of the toolbar/menu/control seam: the SAME parsed `Keymap` drives
  the menu shortcuts, the custom-command monitor, and the palette, so the three can't drift.
- **Two-section verb-based format (`parseKeymap`, host-free, never throws).**
  `map <chord> <action>` overrides a built-in's shortcut (single chord only — a leader is a diagnostic);
  `command "<name>" [chord] <shell...>` defines a custom command (quoted name with spaces;
  the post-name token is the chord IFF `parseKeybind` accepts it AND it carries a modifier — a bare modifier-less
  key is rejected with a diagnostic and the line falls back to palette-only,
  so a custom shortcut can't shadow a plain terminal key and a palette-only shell line starting with
  a single-char token isn't silently swallowed as a binding; else palette-only;
  the shell remainder keeps `{AGT_X}` tokens verbatim — an EMPTY shell line is a diagnostic,
  not a no-op binding).
  Both verbs tokenize on GENERAL whitespace (space OR tab).
  Blank lines and `#` comments are skipped (an inline `#` is a comment only when preceded by whitespace
  AND outside a double-quoted span).
  A malformed line becomes a `KeymapDiagnostic{line, message}` and is skipped — a bad line never discards
  the rest of the file.
  Pure types: `Modifier`/`Chord`/`Keybind`/`parseKeybind`/`keybindConflicts`/`reservedMonitorChords`
  (`Keybind.swift`), `KeybindMatcher` (leader state machine), `CustomCommand`/`CommandContext` (the `{AGT_X}`
  token table — single source of truth for both `{AGT_X}` expansion and the `$AGT_X` env),
  `BuiltinAction` (the 43 rebindable actions + `defaultChord`), `Keymap`/`parseKeymap` (`Keymap.swift`),
  `ConfigPaths` (the path resolver).
  All unit-tested under `rookCoreTests`.
- **MENU-driven built-in override vs MONITOR-driven custom commands — two different mechanisms.** Built-ins
  ride AppKit menu-key-equivalents: each built-in `Button` in `rookApp`'s `.commands` reads `settingsModel.keymap.equivalent(for: .action)`
  via the `shortcut(for:)` helper (`Chord` → SwiftUI `KeyboardShortcut?`,
  applied only when non-nil so a keyless action stays keyless until mapped).
  **`@Observable` does NOT make the menu live.**
  SwiftUI defers its menu rebuild to the next app ACTIVATION, so right after a `keymap reload` the live
  `NSMenuItem.keyEquivalent`s still carry the OLD chords until the app is deactivated and re-activated.
  For rook-vs-rook rebinds that lag is cosmetic — `resolveBuiltinOverrides` has already decided ownership
  and the next activation applies it — but ⌘W is not cosmetic: `close_session` is the only built-in default
  with a STOCK competitor (AppKit's File ▸ Close `performClose:`; `.saveItem` is the one command group
  `rookApp+Menus` does NOT replace), and SwiftUI's deferred rebuild resolves that key-equivalent collision
  by unbinding OUR item, never the stock one.
  So `map cmd+e close_session` + reload handed ⌘W to close-the-whole-window, and putting `close_session`
  back on ⌘W did not reclaim it until a relaunch.
- **⌘W is therefore asserted from AppKit, not left to SwiftUI (`AppDelegate+CloseChord.swift`).**
  In each submenu holding BOTH items, `applyCloseSessionChord` puts ⌘W on rook's Close Session item exactly
  while `close_session` resolves to it (and clears a STALE one, so the File menu never shows ⌘W twice), and
  arms the stock item only when `anyBuiltinOwns` is false.
  Ownership is decided by ANY built-in resolving to ⌘W, not `close_session` alone, because the parser
  rejects a chord only when TWO DISTINCT actions claim it — `map cmd+e close_session` + `map cmd+w new_session`
  is a legal keymap in which another action legitimately owns the chord.
  Re-applied at FOUR points — launch, `.rookKeymapChanged`, `didBecomeActive` (async, so it lands AFTER
  SwiftUI's rebuild), and menu tracking — the same "a one-shot does not stick" shape as
  `removeNativeFullScreenMenuItem`, and for the same reason: no SwiftUI API for either half.
  rook's item is a SwiftUI closure button with no selector, so it is matched by TITLE (`"Close Session"`)
  scoped to the submenu owning `performClose:` — renaming that menu item silently breaks the reconcile.
  Custom commands ride an app-wide `NSEvent` local `.keyDown` monitor in `CustomCommandRunner` (the same
  monitor pattern as the Ctrl-Tab switcher and Ctrl-1/2): it maps `NSEvent` → `Chord`,
  feeds a `KeybindMatcher` (firing simple chords + leader sequences like `ctrl+a>g`,
  1.5 s leader timeout, key-repeat ignored), and on `.fired` spawns a detached `/bin/sh -c` with the
  focused pane's `CommandContext` (cwd + selection + `$AGT_*` env); a non-zero exit posts a failure banner
  via `NotificationManager.notifyCommandFailure`.
  It fires from a focused `GhosttySurfaceView` OR from a rook terminal window whose focus is NOT on a text
  field — INCLUDING an emptied window (every session closed, e.g. an all-SSH window whose `session new
  --command "ssh …"` sessions exited on disconnect): a bound chord never eats keystrokes in a text field
  (rename/palette/Settings) or reaches a non-terminal window, but a launcher chord still works once the
  last session is gone (issue #249).
  With no focused surface it runs the active session if one exists, else `spawnSessionless` fires a
  session-free launcher context (frontmost window id + socket) — but ONLY for a command that does NOT
  reference a session/workspace/selection token (`CommandContext.referencesSessionScopedContext`, host-free
  + unit-tested), so a session-scoped body no-ops instead of running with silently-empty tokens (an empty
  `{AGT_SESSION_PWD}` would turn `rm -rf …/*` into a root glob).
  It rebuilds its matcher on `.rookKeymapChanged`.
  The runner also exposes a public `run(_:)` for the palette items, which resolve context from the active
  session (the same session-scoped no-op guard covers the palette).
  `CommandContext.pane` (the `{AGT_PANE}`/`$AGT_PANE` token, `left`|`right`|`scratch`)
  carries the fired-from pane: the keybind path derives it from the focused SURFACE's identity
  (`splitSurface === focusedSurface` = `right`; a SESSIONLESS focused surface that IS the active session's
  `scratchSurface` = `scratch`, via `runFromSessionlessSurface` — the quick terminal and overlays are NOT
  panes and keep the active-session fallback), the palette path from `session.splitFocused` —
  so a script can feed it back as `rookctl session type --pane "$AGT_PANE"` to type into the very
  pane the shortcut was pressed in.
  It reflects the pane's PHYSICAL surface slot: a promoted split survivor (the primary pane exited and the
  split pane took over) reports `left`, because `closePrimaryPane` MOVES that survivor into the main
  (`surface`) slot and nils `splitSurface` — which is exactly where `session.type --pane left` reaches it,
  so the round-trip stays honest.
  The palette path therefore gates on `splitFocused && splitSurface != nil` (the `onScreenSurface` idiom),
  not on the flag alone.
- **Built-in override resolution is ORDER-INDEPENDENT, decided against the FINAL state (`resolveBuiltinOverrides`).**
  Overrides are NOT folded incrementally against a partially-built map (that was order-sensitive — it
  would reject `map cmd+d new_session` when toggle_split still owned cmd+d "so far",
  even if a later line moved toggle_split off cmd+d).
  Instead: (1) fold all overrides last-wins into a candidate map; (2) compute each action's final resolved
  chord (override else `defaultChord`); (3) a chord that TWO DISTINCT actions resolve to is the only
  real conflict — an override colliding with another action's UNMOVED default loses (the default owner
  keeps the chord), two colliding OVERRIDES → the later-in-file one loses,
  each with a diagnostic naming the kept owner.
  So `map cmd+d new_session` + `map cmd+shift+d toggle_split` both succeed in EITHER order.
  The dropped-override diagnostics are emitted sorted by file line for deterministic order.
- **Cross-section validation + ownership-by-disjoint-registration (why there is NO precedence fight).**
  `parseKeymap` runs a SINGLE final validation pass AFTER every line is parsed (NOT incremental — a custom
  line parsed before a later keyless-built-in `map` must still be checked against the override that `map`
  installs): it computes the active built-in chord set (`equivalent(for:)` over every `BuiltinAction`,
  overrides applied) and drops a custom keybind whose FIRST chord collides with a built-in OR whose ANY
  chord is a reserved monitor chord (the monitor consumes its chord wherever it lands in a leader,
  so a later reserved chord like `ctrl+a>ctrl+1` is just as dead as a leading one) — clearing the command's
  `shortcut` to `""`, keeping the palette entry, + a diagnostic — then drops both keybinds of any custom-vs-custom
  conflict via `keybindConflicts`.
  The reserved set is the PREDICATE `isReservedMonitorChord(_:)` (NOT a fixed list):
  control+tab with ANY modifiers (the Ctrl-Tab switcher consumes Tab whenever Control is held — `ctrl+tab`
  / `ctrl+shift+tab` / `ctrl+opt+tab` / `ctrl+cmd+tab`), plus control+1 / control+2 with Control as the
  SOLE modifier (the Ctrl-1/2 pane monitor) — so all of these are un-rebindable.
  The SAME predicate also rejects a built-in `map` line whose (single) chord is reserved (`parseMapLine`),
  so neither a built-in nor a custom command can steal a monitor chord.
  The reasoning: the NSEvent monitor only consumes chords registered in its matcher,
  and validation guarantees those registered chords are disjoint from the active built-in (menu) chords
  AND the reserved monitor chords.
  So every physical chord is owned by exactly one mechanism — the menu OR a monitor,
  never both — regardless of AppKit's menu-key-equivalent-vs-local-monitor dispatch order (the design
  does NOT rely on asserting that order).
  Caveat: validation covers rook's own built-ins + reserved monitor chords,
  NOT system/standard menu items (⌘Q/⌘C/⌘,); binding a custom command to one of those resolves by AppKit's
  own dispatch — documented, not validated.
- **`BuiltinAction.defaultChord` is the single source of truth for the built-in shortcuts (keep-in-sync
  surface), with NO exceptions left.** Task 9 collapsed the old `BuiltinAction` ↔ menu keep-in-sync
  convention, and the arrow port finished the job: ALL 43 built-in menu items now read `equivalent(for:)`
  (override else `defaultChord`) with NO hardcoded `.keyboardShortcut` literal, so adding or changing a
  default chord happens in `defaultChord` alone.
  30 of the 43 ship with a key; the other 13 (`rename_*`/`delete_*`/`duplicate_session`/`clear_status`/
  `first_session`/`last_session`/`select_theme`/`toggle_flagged_view`/`focus_workspace`/
  `toggle_workspace_filter`) return nil and stay keyless until the user `map`s one.
  `toggle_workspace_filter` (applies or lifts the sidebar's workspace focus filter, keeping the marked set)
  ships keyless because the filter already has a mouse affordance — the bottom-bar `focus-filter-toggle` —
  and rook does not spend a default chord on an action that has one; its View ▸ Toggle Workspace Filter
  item's `keyboardShortcut(shortcut(for:))` is the ONLY dispatch path, so a `map` line reaches it through
  the menu like every other built-in.
- **Arrows are ordinary bindable keys — `map cmd+shift+left previous_session` works (upstream `30581c1c`).**
  `bindableNamedKeys` is `tab`/`space`/`return`/`delete` UNION `bindableArrowKeys`
  (`left`/`right`/`up`/`down`), so `parseKeybind` spells an arrow like any other named key.
  The six arrow-bound actions therefore return their REAL `defaultChord` — `focus_left_pane` ⌥⌘←,
  `focus_right_pane` ⌥⌘→, `previous_session` ⌥⌘↑, `next_session` ⌥⌘↓, `previous_attention_session` ⌃⌥↑,
  `next_attention_session` ⌃⌥↓ — instead of nil.
  **Both workarounds are DELETED**: `arrowShortcut(for:)` in the menu builder and
  `BuiltinAction.arrowGlyphFallback`, along with `glyphHint`'s `?? arrowGlyphFallback` term.
  Every keyed built-in now resolves through exactly ONE path (`equivalent(for:)` → `Chord`), which is what
  makes `keymap.list`'s model-vs-menu diff meaningful, and the starter `keymap.conf` prints these six their
  real chords instead of `(no default)`.
  `Chord.glyphString` renders the four arrows as ←/→/↑/↓.
  **A modifier-less arrow in a `map` line is REJECTED** — `bare arrow chord '<chord>' needs a modifier;
  map skipped` — because a menu key equivalent is always-on and has NO text-field pass-through (unlike the
  custom-command monitor, which skips text fields): a bare arrow would swallow the key in the inline rename
  field, the palette search field, the dashboard grid, and every Settings field at once.
  This is the same rule `command` lines already enforce for every chord, which is why a palette-only
  `command "X" up <shell…>` now gets the familiar
  `command 'X' shortcut 'up' must include a modifier; treating the line as palette-only` diagnostic that
  `tab`/`space` already produced.
  **Both conflict checks now SEE the six arrow defaults** — they were invisible while `defaultChord` was
  nil, so an arrow chord could be claimed twice with no diagnostic.
  Built-in vs built-in: `resolveBuiltinOverrides` computes each action's final resolved chord, so
  `map cmd+opt+up new_session` now collides with `previous_session`'s default and is DIAGNOSED — the
  unmoved default owner keeps the chord and the override is dropped — instead of silently double-binding.
  Custom vs built-in: `validateCommands` builds the active built-in chord set from `equivalent(for:)` over
  every action, and the arrow defaults are now IN that set, so a custom command can no longer shadow one
  (its shortcut is cleared to `""`, the palette entry survives, and a diagnostic says so).
  **The keyCode→name table is one host-free `namedKey(forKeyCode:)` in `Keybind.swift`**, shared by
  `CustomCommandRunner` and `UndoCloseShortcut`, which each carried a private copy — the copies are exactly
  how a name can parse in the file yet never fire at runtime.
  Its character counterpart `namedKey(forKeyEquivalent:)` (AppKit spells arrows with the 0xF700–0xF703
  private-use scalars) is what lets `keymap.list` project a live `NSMenuItem` back into keymap syntax; a
  test pins both against `bindableNamedKeys` as SET EQUALITY, guarding the parses-but-never-fires failure
  from both directions.
  **Adding a name to `bindableNamedKeys` means updating four sites** (documented on the constant): the two
  inbound `NSEvent` resolvers via `namedKey(forKeyCode:)`, `Chord.glyphString` (cosmetic — it degrades to
  the raw name), and `rookApp.toShortcut`, whose `default` arm builds a `KeyEquivalent` from a single
  `Character` and TRAPS on a multi-character key — a crash on the first menu render, not a degradation, so
  it is the site to fix FIRST.
- **Shifted symbols bind as `shift+<base>` — the runner normalizes to the UNSHIFTED base key.**
  `charactersIgnoringModifiers` KEEPS shift (shift+/ → "?", shift+= → "+"), and the old
  `.lowercased()` only undid that for letters (shift+u → "u"), so punctuation landed on the shifted glyph
  and never matched a `shift+/`-style binding.
  `CustomCommandRunner.chord(from:)` now derives the base key via `characters(byApplyingModifiers: [])`
  (the same call `GhosttySurfaceView` uses for unmodified key input), so the runtime chord for shift+/ is
  `(shift, "/")` and matches the parser's `shift+/`.
  So every shifted symbol is written `shift+<base>` (`shift+/` = `?`, `shift+=` = `+`, `shift+5` = `%`,
  `shift+.` = `>`).
  This is verified END-TO-END by `KeymapUITests.testCustomCommandShiftedSymbolFires` (a real synthesized
  Shift+/ keypress fires a `shift+/`-bound command) — the host-free tests structurally can't reach
  `chord(from:)`, which is exactly why the earlier parser-only version shipped a runtime that never fired.
- **A chord resolves per LAYOUT, not per key — this is what makes `keymap.conf` work on a Cyrillic keyboard.**
  The `NSEvent`-monitor seams (`CustomCommandRunner`, `UndoCloseShortcut`) used to match the character the
  active layout PRODUCES, so on a Russian layout the physical O yields `щ` and a Latin-spelled `cmd+o` could
  never match — every custom command and ⌘Z Reopen Closed Item were dead there.
  Built-in `map` shortcuts were unaffected: they ride AppKit menu key equivalents, a different mechanism.
  The policy is the host-free `chordKey(forKeyCode:produced:layoutIsASCIICapable:)`
  (`rookCore/Sources/rookCore/AnsiKeyLayout.swift`); the single bit it needs comes from app-side
  `KeyboardLayout.isASCIICapable` (`rook/Ghostty/KeyboardLayout.swift`), read FRESH on every key press —
  no cache, no layout-change observer to get wrong.
  A layout that can type ASCII (US, Dvorak, Colemak, US-International, French, German) binds the character
  it produces, exactly as before, so no existing binding changes; one that cannot (every Russian variant,
  Greek, Hebrew, Arabic, Thai) binds every key by physical position through the ANSI table.
  Note this reads a DIFFERENT input source than the sibling `KeyboardLayout.asciiCodepoint`:
  `TISCopyCurrentKeyboardLayoutInputSource` (what you are typing on) vs the ASCII-capable FALLBACK layout
  that one resolves.
  **Do NOT "optimize" this into a per-KEY ASCII test** (keep any produced character that happens to be ASCII).
  Measured on real layout data, it breaks three ways: Greek types `;` on the physical Q and Hebrew types `/`
  there, so letter chords stay dead on two of the three layouts this targets; two physical keys collapse onto
  one chord (Hebrew 39/43 → `,`, Russian-PC 44/47 → `.`), firing a binding from a key the user never pressed
  and swallowing the keystroke; and the ISO section key (keyCode 10) collides with the ANSI backslash key,
  which is why it is DROPPED on a position-resolved layout (Ukrainian-PC types `\` there, Hebrew-PC `;`).
  `AnsiKeyLayout.latinKey` and `Keybind.namedKey(forKeyCode:)` claim non-overlapping keyCodes (pinned by a
  test), because the monitors resolve a named key first.
  This is a SEPARATE rule from `InterruptKeystroke.isInterrupt`, which looks at the character rather than the
  layout — do not merge them.
  It also SPLITS a known limit rather than removing it: `map shift+/ undo_close` stays dead on a Latin layout
  (that monitor keeps Shift in its base key, so the character is `?`) and now FIRES on a position-resolved
  one; `undo_close` is the only built-in delivered by a monitor instead of a menu key equivalent.
  A non-ASCII layout can only bind by POSITION, so it cannot bind the Cyrillic character it prints.
  **`keybind` in `ghostty.conf` does NOT get this treatment** — that is libghostty's own matcher, where a bare
  letter is a unicode trigger matched against the produced character and `key_g` is a physical trigger.
  The answer there is the `key_` form (the bundled defaults already ship `super+key_c`/`key_v`/`key_a` for
  exactly this reason), not an app-side change.
- **v1 scope cut (confirmed).**
  Built-in rebinds are single-chord only (leaders only for custom commands).
  The literal `+`/`>` still can't be a bare key TOKEN (they are the chord-joiner / leader separator), but
  those keys ARE bindable as `shift+=`/`shift+.` (see the shift-symbol note above).
  `increase_font_size`'s default ⌘+ still renders `(not expressible)` in the STARTER file: its stored
  `Chord(key:"+")` can't round-trip through `displayString` (which emits the `+` glyph, `chordSyntax`
  verifies the round-trip) — a display-side detail, separate from key MATCHING.
  The Ctrl-Tab MRU switcher and Ctrl-1/Ctrl-2 pane focus are NOT rebindable (they are monitor-driven,
  not menu items — folding them in would reintroduce a monitor-vs-monitor precedence question;
  a custom command bound to one is dropped via `reservedMonitorChords`).
  The palette shows a custom command's chord as raw kitty syntax (`cmd+shift+e`),
  not the ⌘⇧E glyphs built-ins use.
- **The spawned command's `PATH` is WIDENED (`CommandPath.widened`, host-free + unit-tested).**
  A launchd-started app (Dock, Spotlight, `open`) inherits `/usr/bin:/bin:/usr/sbin:/sbin`,
  and the runner's `/bin/sh -c` is neither a login nor an interactive shell, so it never reaches
  `path_helper` — a bare `rookctl` or Homebrew binary in a keymap line just exited 127,
  with the shell's own diagnostic discarded by the `/dev/null` stdio.
  `CustomCommandRunner.spawn` therefore rewrites `PATH` on the merged environment: the bundled CLI's
  directory (`CLIInstaller.bundledTool` → `Contents/MacOS`) FIRST, the inherited PATH next,
  then `CLIInstall.installDirectory` + `/opt/homebrew/bin` LAST, de-duplicated so an entry already
  present keeps its own position.
  The bundled binary goes first because it is there even when nothing is installed; which binary runs does
  not decide which INSTANCE it drives — `--socket`, then `ROOK_STATE_DIR`, then Application Support resolve
  that identically either way.
  The widening covers ONLY the runner: the program an OVERLAY runs is spawned by the terminal through
  libghostty's own `sh -c` wrapper and still gets the app's unwidened PATH (hence the shipped
  `'zsh -lc lazygit'` example), while a SCRATCH `--command` is wrapped in the session's shell as a login
  shell by `SurfaceCommand.resolve` and needs no wrapper.
- **`{AGT_X}` tokens are substituted RAW into the `/bin/sh -c` line (`CommandContext.expand`).** This
  is the intended raw interpolation (convenient), NOT shell-quoted — so dynamic content like `{AGT_SELECTION}`
  can inject shell syntax.
  `{AGT_SESSION_NAME}` and `{AGT_SESSION_PWD}` are equally unsafe, and worse than `{AGT_SELECTION}`
  because they need no local interaction: a remote host sets the session title (OSC 0/1/2) and the
  working directory (OSC 7), so either can carry attacker content silently.
  OSC-reported title and pwd are stripped of control characters at ingestion (`TerminalText.sanitized`
  in `GhosttySurfaceView.applyTitle`/`applyPwd`), so a newline can no longer split the `sh -c` line,
  but visible metacharacters (`;`, `$()`, backticks) still pass through raw.
  The safe alternative is already provided: the same values are exported as `$AGT_X` env vars (`CommandContext.environment()`),
  naturally shell-quoted as `"$AGT_SELECTION"`.
  The starter `keymap.conf` comments + README recommend `$AGT_X` (quoted) for untrusted content.
  Do NOT add quoting to the `{AGT_X}` expansion — by design.
- **Reload + control.**
  `AppActions.reloadKeymap()` → `SettingsModel.reloadKeymap()` (re-read + re-parse + post `.rookKeymapChanged`)
  is exposed as File ▸ Reload Keymap, an action-palette entry, AND the `keymap.reload` control command
  — all ONE path.
  See the Control API catalog for the `keymap.reload` four-point audit.
- **`keymap.list` is the diagnostic half — and its point is the DIFF, not the listing.**
  `keymap.reload` only ever answered with a diagnostic COUNT, so nothing could read what a keymap actually
  resolved to.
  `rookctl keymap list` returns two halves that are meant to be COMPARED: the MODEL half (the config path,
  every `BuiltinAction` with its resolved chord + an `overridden` flag, the custom commands, the
  diagnostics as `{line, message}`) — a host-free `ControlKeymap.project` over the same parsed `Keymap` the
  menu and the monitor read — and the MENU half, an app-side walk of `NSApp.mainMenu` reporting the LIVE
  key equivalents in the SAME kitty syntax.
  The two disagree exactly where this rule's ⌘W note says they can: SwiftUI defers its menu rebuild to the
  next app ACTIVATION, so right after a `keymap reload` a chord can be correct in the model while the live
  `NSMenuItem` still carries the old one, or while a stock AppKit item has taken it (the `selector` field
  reads `menuAction:` for rook's own items and `performClose:`/`closeAll:`/… for an AppKit-supplied
  competitor), or while the item is DISABLED and its chord therefore inert — most File/View/Navigate items
  carry a `modalActive` gate, so with the dashboard open the menu holds every chord and fires none.
  That is the same failure class `AppDelegate+CloseChord.swift` reconciles by hand for ⌘W; `keymap.list` is
  how you SEE it for any other action instead of discovering it by pressing keys.
  `overridden` compares CHORDS, not the presence of a `map` line, so a redundant `map cmd+w close_session`
  is correctly reported as un-overridden.
  Reach for it first when a binding "doesn't work": if the action's chord is right but the `menu` row is
  missing, different, or `(disabled)`, the keymap parsed fine and the problem is menu resolution — activate
  another app and come back, or look for the competing item — whereas a wrong chord or a `diagnostics` row
  means the file itself.
  See the Control API rule for the payload/CLI details and the four-point audit.
- **Edit Keymap (GUI-only).**
  `AppActions.editKeymap()` (File ▸ Edit Keymap… + the ⌃⇧P palette) opens `keymap.conf` in the user's
  editor inside a 95% FLOATING overlay over the active session via `AppStore.openOverlay(…, sizePercent: 95)`.
  The command is the host-free, unit-tested `ConfigPaths.editorCommand(forPath:)` → `${SHELL:-/bin/zsh} -ilc 'exec /bin/sh -c '\''${VISUAL:-${EDITOR:-vi}} "$1"'\'' rook-config-edit '<single-quoted path>''`
  (the path comes from `SettingsModel.keymapPath`).
  The user's INTERACTIVE login shell (`$SHELL -ilc`) runs first so it sources its rc and EXPORTS `$EDITOR`/`$VISUAL`,
  then `exec`s a POSIX `/bin/sh` that does the actual `${VISUAL:-${EDITOR:-vi}} "$1"` resolution + launch
  (the path is the inner `/bin/sh`'s positional `$1`, embedded single-quoted so spaces/quotes survive
  — NOT passed positionally to `$SHELL`, which fish has no `$1` for).
  TWO LOAD-BEARING reasons for the shape: (1) the `-ilc` sourcing — the overlay's own process is a bare
  non-interactive `/bin/sh` (libghostty runs `config.command` via `sh -c`,
  NOT the user's interactive shell) that sources none of the user's shell config,
  so a direct `${EDITOR:-vi}` there always fell back to `vi`; (2) the inner-`/bin/sh` hop — `$SHELL`
  may NOT be a POSIX shell (fish), which can't parse POSIX `${VAR:-default}` and died with `fish: ${ is not a valid variable`
  (exit 127, overlay just flashed) when the resolution ran directly under `$SHELL` — the POSIX text now
  rides inside single quotes that fish (and POSIX shells) pass through verbatim to `/bin/sh`.
  Two known limits: it assumes `$SHELL` accepts `-ilc` and passes single-quoted text verbatim (true for
  sh/bash/zsh/fish, NOT csh/tcsh, which reject `-ilc`); and it resolves `$EDITOR`/`$VISUAL` only when
  EXPORTED (their entire convention) — a non-exported, shell-local value does not survive the `exec`
  and falls to `vi`.
  Cross-shell behavior is unit-tested (`ConfigPathsTests` runs the built command under zsh + fish-when-present
  with a fake recorder editor, plus VISUAL-precedence and rc-sourcing cases).
  On the editor exiting the keymap reloads automatically: `editKeymap` records the target in `AppActions.keymapEditOverlaySession`
  and `WindowContentView`'s overlay-close `onChange` calls `reloadKeymap()` for it (then clears it).
  NO control command — a script can already `rookctl session overlay open "$EDITOR <path>" --size-percent 95`
  (keep-in-sync exempt, like `reveal`, since it composes the controllable `session.overlay.open`).

