---
paths:
  - "rook/Views/WorkspaceSidebar*.swift"
  - "rook/Views/SidebarRowViews.swift"
  - "rook/Ghostty/AgentMonitor.swift"
  - "rookCore/Sources/rookCore/AgentKind.swift"
  - "rook/Views/SidebarRenameController.swift"
  - "rookCore/Sources/rookCore/SidebarDrop.swift"
  - "rookCore/Sources/rookCore/SidebarMode.swift"
  - "rookCore/Sources/rookCore/AppStore+Focus.swift"
  - "rookCore/Sources/rookCore/Reorder.swift"
  - "rookUITests/SidebarUITests.swift"
  - "rookUITests/ReorderUITests.swift"
  - "rookUITests/FlaggedViewUITests.swift"
  - "rookUITests/FocusWorkspaceUITests.swift"
---

## Sidebar

- The sidebar is an AppKit `NSOutlineView` (`WorkspaceSidebar`, an `NSViewRepresentable`),
  not a SwiftUI `List` — chosen for native cross-workspace drag-and-drop.
  Its `@MainActor` `Coordinator` is the data source/delegate, backed by `AppStore`.
  Outline items are cached reference-type `SidebarNode`s, reused across reloads for stable identity (expansion/selection
  survive `reloadData`).
- **Drag reorder (sessions AND workspaces).**
  The Coordinator's `validateDrop`/`acceptDrop` now HONOR `proposedChildIndex` for sessions and feed the
  host-free `SidebarDrop` helpers so validate and accept agree exactly instead of force-retargeting every
  drop to `NSOutlineViewDropOnItemIndex` — enabling intra-workspace SESSION reorder (drop between rows for
  a precise slot) AND precise cross-workspace placement (a cross-workspace drag now lands at the drop
  position, no longer always-append).
  Workspace ROWS are draggable too: a second pasteboard type `com.rook.app.workspace` is added
  to `registerForDraggedTypes` (LOAD-BEARING — without it AppKit never delivers validate/accept for workspace
  drags) and `pasteboardWriterForItem` emits it (carrying the workspace UUID) for workspace nodes.
  **Workspace reorder is a TOP-LEVEL move, but it does NOT use AppKit's proposed `item`/`childIndex`.**
  With workspaces expanded their sessions fill the gaps between workspace rows,
  so `NSOutlineView` only ever proposes drops INTO a workspace's children (`proposedItem != nil`) — never
  the clean root between-rows slot — so the old `proposedItem == nil`-only gate rejected EVERY drop and
  made workspace drag impossible once any workspace held sessions (the real-world state).
  `resolveWorkspaceMove` therefore IGNORES the proposed item/index and derives the insert slot from the
  CURSOR Y against the workspace ROWS' midpoints (`info.draggingLocation` → `rect(ofRow:).midY`,
  sessions ignored): the slot is the count of workspace rows whose midpoint sits above the cursor,
  so the top half of a row drops before it and the bottom half after it — reachable everywhere.
  It still feeds that slot to the host-free `SidebarDrop.resolveWorkspace` for the post-removal/no-op
  math, and `validateDrop` highlights it via `setDropItem(nil, dropChildIndex:)`.
  **That slot counts RENDERED rows, which stop being `store.workspaces` indices the moment the focus filter
  hides rows in between**, so it is mapped into store space by `SidebarDrop.workspaceInsertIndex` BEFORE any
  reorder math runs and mapped BACK by `workspaceHighlightSlot` for the highlight (`setDropItem` also counts
  rendered children — without the return trip the insertion line is drawn a row off from where the drop
  lands).
  The outbound mapping lands a drop IMMEDIATELY ADJACENT to the visible row it was aimed at — the first
  rendered row's own index when the cursor is above everything, else just after the last rendered row above
  it — never at a raw array index the filter has no row for, which would jump the workspace across the
  hidden ones in between: invisible at drop time and only revealed once the filter is switched off.
  Both directions are the IDENTITY while every workspace is rendered, which is why a single-workspace mark
  never exposed this and the MULTI-member set did: a marked set of 2+ makes `visibleIndices` non-contiguous.
  Covered by `ReorderUITests.testReorderWorkspaceOntoSessionRow` (drag a workspace onto a session row
  — the case the `proposedItem == nil` gate broke).
  The session helper still HONORS `proposedChildIndex` (sessions are real same-level siblings,
  so the outline proposes precise between-rows slots). It supports single-row and multi-row drags:
  dragging from a selected session writes the full `sidebarSelectionIDs` block to the pasteboard in visual
  order; dragging an unselected session writes just that row.
  Both session and workspace drops feed `SidebarDrop`. For a single session, `resolveSession` applies the
  same-parent downward `childIndex - 1` post-removal adjustment (only when `sourceIndex < childIndex`).
  For a multi-selection, `resolveSessions` removes every dragged session first and inserts the whole block
  at the post-removal slot, preserving the selected visual order and handling same-workspace / cross-workspace
  mixes atomically. Workspace reorders use `resolveWorkspace` with the same remove-then-insert convention.
  The PURE index arithmetic (drop-on-row `sessionIndex + 1` redirect, source-removal adjustment,
  cross-workspace vs same-parent index spaces, batch block insertion, and no-op checks) lives host-free in
  `rookCore.SidebarDrop` (`resolveSession`/`resolveSessions`/`resolveWorkspace`), table-tested in
  `SidebarDropTests`; the Coordinator helpers only do the AppKit/store glue (read the pasteboard, resolve
  ids → indices via `AppStore.sessionLocation(ofSession:)`) and feed `SidebarDrop`, so the trickiest part
  is unit-covered without the fragile XCUITest drag.
- Add affordances live in a bottom bar in `WindowContentView`: a workspace button and a session menu (New Session
  / Open Directory…).
  The two session actions are also on each workspace row's right-click menu.
- **A single click anywhere on a workspace ROW toggles its expansion** (not just the disclosure triangle),
  so the whole row is the hit target.
  Wired via the outline's `action` (`Coordinator.handleSingleClick`) — which fires on a genuine click,
  NEVER during a drag, so workspace drag-reorder is untouched — and guarded against the disclosure-triangle
  region (`frameOfOutlineCell`) so a triangle click doesn't double-toggle.
  The toggle is DEFERRED by `NSEvent.doubleClickInterval` and CANCELED by `handleDoubleClick`,
  so a double-click (rename) doesn't flip the workspace open/closed on its way into edit mode
  (instant-toggle was tried and rejected: AppKit commits the first click of a double before it knows a
  second is coming, so instant forces a visible toggle-then-revert flicker on rename).
  This is pure click-routing over the existing per-workspace `expandItem`/`collapseItem` (an exempt case
  under the control keep-in-sync rule), so it adds NO control command — the ALL-workspaces
  `sidebar.expand`/`sidebar.collapse` stay the control surface.
  Covered by `SidebarUITests.testClickWorkspaceRowTogglesExpansion`.
- **A session ROW click reveals a blocked session's pane-tagged pane.**
  `Coordinator.outlineViewSelectionDidChange` selects the clicked session (`selectSession`) then — async,
  after the selection + the sidebar's own focus-restore settle — calls `AppActions.revealActiveBlockedPane()`,
  so clicking a session whose agent blocked in its split (right) or scratch pane lands you on THAT pane,
  not the plain focused pane.
  It is a no-op (plain `focusActiveSession`) for an IDLE session (no status set),
  so ordinary clicks are unaffected — the reveal never dismisses a merely-shown scratch (a non-idle
  nil-tagged block is treated as `left`/main).
  This matches attention-nav, plain session nav, the command palettes, and idle auto-follow,
  which all route through the same helper (see the Menu/actions + Notifications rules).
  Covered by `PaneAwareStatusUITests.testSidebarClickRevealsBlockedSplitPane`.
- Accessibility identifiers `session-row`, `workspace-row`, `edit-field`,
  and `add-session` back the XCUITests.
- **Each WORKSPACE row carries a hover-revealed inline "+"** (`SidebarCellView.addButton`, accessibility id
  `workspace-add-session` — distinct from the bottom-bar `add-session`), the Finder/Xcode convention:
  `mouseEntered`/`mouseExited` on the cell toggle it via `setAddButtonVisible` (0↔width, so an idle row's
  name + roll-up badge keep their slots), and its click runs the SAME `addSession(toWorkspace:cwd:)` path as
  the right-click "New Session" (the `@objc addSessionButtonClicked` handler lives in
  `WorkspaceSidebar+ContextMenu.swift` beside that private helper; `handleSingleClick` guards the button's
  rect so clicking "+" doesn't also toggle the workspace's expansion).
  GUI-only, no control surface (session creation is already `session.new`).
  Note the rename field surfaces as a `TextField` for sessions and a `StaticText` for workspaces,
  so UI tests match `edit-field` by identifier across element types.
- **Sidebar multi-selection.**
  `AppStore.selectedSessionID` remains the durable active terminal. The broader sidebar selection is
  a private transient array in host-free `AppStore`, exposed through `sidebarSelectionIDs` normalized to
  the current visible session order so batch actions are deterministic in tree and flagged modes.
  AppKit Shift-click and Command-click update the outline selection; `outlineViewSelectionDidChange`
  mirrors it through `AppStore.setSidebarSelection(_:)`. `allowsEmptySelection` stays TRUE because an
  applied focus filter can intentionally hide the active session and `syncSelection` must be able to
  `deselectAll(nil)` in that state.
  Right-click follows standard Mac list behavior: inside the current multi-selection it keeps the whole
  selection for the context menu, outside it narrows to the clicked row. Context menu target resolution
  is `AppStore.sidebarSelectionTargets(forContextSession:)`, which filters through the visible projection.
  Batch row actions: move uses `AppStore.moveSessions`, close uses `AppActions.closeSessions(_:in:)` →
  `AppStore.softCloseSessions`, flag uses `AppActions.toggleFlags(_:in:)` → `setFlag(_:forSessions:)`,
  and clear-status loops `setAgentIndicator` once per selected session (loop-equivalent to `session status idle`).
- **Flagged working-set view (`AppStore.sidebarMode` `.tree`/`.flagged`).**
  `SidebarMode` (`rookCore/SidebarMode.swift`, `String`-backed `Codable`/`Sendable`) drives a per-window
  MODE toggle between the normal two-level tree and a FLAT list of just the flagged sessions.
  A session is flagged via the observed `Session.flagged: Bool`; the flat list is the PURE derived projection
  `AppStore.flaggedSessions` (`workspaces.flatMap(\.sessions).filter(\.flagged)`,
  already in tree order — workspace-then-session).
  No second container: a session always has exactly one home workspace, the flag dies with the session
  and survives a workspace move (the projection re-sorts).
  The ONE `NSOutlineView` renders either source — `numberOfChildrenOfItem`/`child`/`isItemExpandable`
  branch on `store.sidebarMode`; in `.flagged` the root's children are `flaggedSessions` as flat,
  non-expandable rows labeled `session : workspace` (the session `displayName`,
  then the owning workspace name) with the base leading icon — a plain terminal for a single session,
  the split-rectangle for a split one so a split stays distinguishable (the FILLED flag variant is suppressed;
  every row here is flagged) — plus the usual `StatusIconView` + `BadgeView`.
  A row click routes through the existing `selectSession`; the mode switch is VIEW-ONLY (never re-selects/refocuses).
  Drag-reorder is DISABLED in `.flagged` mode.
  An empty flagged set shows a centered, non-scrolling empty-state hint ("No flagged sessions. / Right-click
  a session → Flag.") overlaid in the scroll view, re-tinted on `.rookAppearanceChanged` and toggled
  by `updateEmptyStateHint` (visible only in `.flagged` with `flaggedSessions.isEmpty`).
  Mutators: `AppStore.setFlag(_:forSession:)` / `setFlag(_:forSessions:)` (clean no-op + no save on
  unknown ids or unchanged values, prune the transient selection when the current sidebar mode hides the
  changed rows), `clearFlags()` (single save + prune), `setSidebarMode(_:)` (save).
  GUI half: the bottom-bar `flagged-view-toggle` button (right of the trailing `Spacer()`,
  2-state flag/checkmark glyph, tinted `chromeText`, flips `sidebarMode` and animates via `WindowContentView`'s
  `.animation(value:)`), the row context-menu Flag/Unflag → `AppActions.toggleFlags(_:in:)`,
  the View-menu Show Flagged/Show All + Flag Session + Clear Flagged, the ⌃⇧P palette entries,
  and the two `BuiltinAction`s `toggleFlaggedView`/`toggleFlag` (expressible/keyless).
  **Clear Flagged** is a plain menu/palette item (NOT a `BuiltinAction`,
  mirroring Reload/Edit Keymap) → `AppActions.clearFlags()` with a light confirm alert when the set is
  non-empty (skipped under the XCUITest launch, like the quit-confirm).
- **Tree-mode flagged indicator (filled-icon variant).**
  In `.tree` mode a flagged session's row swaps its leading icon to the FILLED SF Symbol variant of its
  base glyph — `terminal.fill` for a single session, `rectangle.split.2x1.fill` for a split (the same
  filled split symbol the titlebar shows for a SHOWN split; outline = unflagged,
  filled = flagged) — via the cached `flaggedSessionIcon`/`flaggedSplitSessionIcon`
  template images, tinted with the chrome/theme color.
  It is a pure SF Symbol swap (`Self.rowIcon(...)`), NOT a composited corner badge — same-size,
  so it is inherently layout-shift-free.
  `flagged` is folded into the row's `RowContent` (Equatable), so a flag/unflag re-renders ONLY that
  row (per-row `reloadItem`).
  The filled variant is tree-mode only — the flat flagged view shows the unfilled base icon,
  so a split session still gets the split-rectangle to stay distinguishable;
  only the FILLED flag variant is suppressed there (every row is flagged).
- **The selected row's pill is BRAND chrome, not the terminal theme's selection color.**
  `SidebarRowView.drawBackground` fills the row pill with `NSColor.rookGreen` (`#7ece8f`) and
  `SidebarCellView.setColors` puts `NSColor.rookGraphite` (`#191c20`) on it — the selection pair of the
  bundled `rook` theme (`rook/Resources/custom-themes/rook`, pinned by `BundledRookThemeTests`), so the
  selection looks like rook under EVERY theme instead of inheriting whatever the active theme calls a
  selection.
  Both constants live in `NSColor+RookHex` (the app target; `rookCore` is CoreGraphics-free and can hold no
  color).
  The pill still dims to 0.55 alpha for a background (non-key) window via the `isEmphasized` override.
  This REPLACED the theme-following pill (`GhosttyApp.terminalSelectionBackgroundColor`, resolved by
  re-parsing the config sources + theme file); the sidebar was that resolver's only consumer,
  so it was deleted with it (see [[libghostty]]).
  An UNSELECTED row still follows the theme foreground — only the selection is brand.
- **Status row highlight (`blocked`/`completed` wash the whole row).**
  A session whose agent `needsAttention` (`blocked` or `completed` — NEVER `active`,
  which is the steady state and would keep half the sidebar colored) washes its ROW in that status's color:
  the row BACKGROUND plus the name TEXT, on top of the always-on status glyph.
  `GhosttyApp.statusRowHighlight(for:)` is the single gate both halves read (the Settings toggle +
  `needsAttention` + the per-call `session.status --color` override), so the background and the text can
  never disagree.
  **The two halves live in different views and are joined through the CELL.** The tint is stored on
  `SidebarCellView.statusTint` (set in the row builder, reset on cell reuse like `iconTint`/the badge) and
  the row background is drawn by `SidebarRowView.drawBackground`, which READS the tint back off its hosted
  cell — because the row view has no item of its own and a status change only re-runs the CELL builder
  (`reloadItem`), never `rowViewForItem`.
  Setting `statusTint` invalidates the row's background (`didSet` → the row view's `needsDisplay`), and
  `didAddSubview` repaints when a cell attaches.
  The wash is drawn FIRST, UNDER the selection pill: a selected row keeps the plain brand pill
  (its status is on screen anyway, and the glyph still reports it), and `setColors` gives the status color
  to the text only when UNSELECTED — a status-colored label over the pill would fight the graphite it must
  pair with.
  Gated by `AppSettings.statusRowHighlightEnabled` (nil = ON, mirrored into the non-observable
  `GhosttyApp.statusRowHighlightEnabled` by `SettingsModel.applyStatusRowHighlight`), so — like the status
  COLORS — a flip is GLOBAL, invisible to `reconcile`'s per-row `RowContent` diff, and rides
  `.rookAppearanceChanged` → the Coordinator's `reapplyStatusRows()` sweep (which re-applies the glyph,
  the tint, and the text color on every visible session row; it was `reapplyStatusGlyphs` before the wash).
  Settings ▸ Agent Status ▸ "Highlight blocked and completed rows"; `resetAgentStatus()` clears it back on.
- **Agent logo (`Session.agentKind`) — the row icon while a coding agent runs.**
  A session whose FOCUSED pane runs `claude` or `codex` swaps its leading icon to that agent's LOGO
  (`AgentClaude`/`AgentCodex` in `rook/Assets.xcassets` — the simple-icons marks, CC0, vector + template so
  `setColors` tints them exactly like the SF Symbols).
  The agent WINS over both the split-rectangle and the flagged `.fill` variants (`iconForSession(agent:split:flagged:)`):
  which agent is working is what you scan the sidebar for, and split/flag state is still readable from the
  title-bar split glyph, the row's context menu, and the flagged view — the alternative was an 8-way matrix
  of filled/split logo variants that don't exist as artwork.
  `agentKind` is folded into `RowContent` AND into `updateNSView`'s dependency touch (both are load-bearing:
  without the former no row reloads, without the latter the observation never fires).
  The icon is not accessibility-observable, so the row's image view carries `setAccessibilityValue(agentKind)`
  for the UI tests — the `StatusIconView` idiom.
  **It is DETECTED, not reported** — `AgentKind.classify` (host-free) keys on the argv[0] basename of the
  pane's foreground process, looking one argument past a launcher (`sh`/`node`/`npx`/`env`…) for the
  `#!/bin/sh` + `exec claude` shim case; it needs no hooks and no shell integration, so it is true even for
  an agent nobody wired up.
  Distinct from `AgentStatus` (the glyph on the RIGHT of the row), which is the agent's SELF-REPORTED turn
  state pushed by its hooks over `session.status` — a session can run `claude` while reporting no status at
  all, and the two render independently.
  The detection lives in `rook/Ghostty/AgentMonitor.swift`, whose 2 s sweep is **the app's only repeating
  timer** — a deliberate exception to the demand-driven rule, because libghostty exposes no child-SPAWN
  action to subscribe to (`GHOSTTY_ACTION_COMMAND_FINISHED` fires only when a command ENDS and carries no
  pid).
  It is made cheap rather than rare: a per-session pid cache means the steady state is one
  `ghostty_surface_foreground_pid` read per open session per tick, and the `sysctl(KERN_PROCARGS2)` runs only
  when a pane's foreground pid actually CHANGED (a shell forks a fresh pid per command, so an unchanged pid
  cannot have changed its argv).
  The `if session.agentKind != kind` write guard is MANDATORY, not a nicety: `@Observable` notifies on EVERY
  set, equal or not, so an unguarded write would re-run `updateNSView` + the full reconcile diff every 2 s
  forever.
  Related: the agent's own OSC-title marker (Claude Code's `✳ ` and its braille spinner) is stripped at
  ingest by `TerminalText.withoutAgentMarker` (`GhosttySurfaceView.applyTitle`), so the row NAME is the task
  and the ICON is the agent.
  Stripping at ingest (not at display) also collapses every spinner FRAME to the same title, so `applyTitle`'s
  equality guard now swallows the per-frame re-emits that used to churn the sidebar at spinner rate.
- **Per-workspace icon color (`Workspace.colorHex`).**
  A workspace can carry its own `#rrggbb` tint for its sidebar ICON (never the row text — one choke point,
  no layout risk), set from the row's context menu (Color… → the system `NSColorPanel`,
  which previews live because it is CONTINUOUS; Reset Color, shown only when a color is set) or over the
  socket with `workspace.color` (see the Control API rule).
  **The tint MUST be applied inside `SidebarCellView.setColors(selected:)`** (via the cell's `iconTint`
  override), because that is the single point all four tint paths re-assert through — the cell build,
  `SidebarRowView.didAddSubview`, `retintCellViews` on a selection flip, and the theme-change re-run.
  A tint written straight onto `cell.imageView` from the row builder is silently clobbered by the very
  next re-assert.
  `iconTint` is reset on cell REUSE alongside the badge/status glyph, and the icon is a TEMPLATE image,
  so `contentTintColor` recolors it.
  A custom color wins in BOTH the selected and unselected states, at full alpha — it is a deliberate
  signal, not chrome.
  `colorHex` is folded into `RowContent` (the Equatable per-row diff) so a color change re-renders ONLY
  that row, and it is read in `updateNSView`'s dependency touch so the observation actually fires.
  Persisted per workspace (`WorkspaceSnapshot.colorHex`, Optional → no `Snapshot` version bump) and
  threaded through all FIVE `Workspace` construction sites — including `rebuiltWorkspaceShell`
  (`AppStore+PendingClose.swift`), or a workspace reopened from Open Recent comes back gray.
  The store mutator (`AppStore+Appearance.setWorkspaceColor`) persists through `scheduleSave()`, NOT
  `save()`: the color panel drags continuously, and each `save()` re-encodes the whole snapshot.
- **Per-workspace custom icon (`Workspace.icon`, a host-free `WorkspaceIcon`).**
  A workspace can replace the default `square.grid.2x2` glyph with an SF Symbol name, a single emoji, or an
  image file (svg/png/jpeg), set from the row's context menu (Icon… → an `NSOpenPanel`; Reset Appearance
  clears icon + color) or with `workspace.icon` (see the Control API rule).
  **The COLOR applies only to a TEMPLATE icon, and the PIXELS decide — not the file format.**
  AppKit template rendering keeps only the ALPHA and repaints every visible pixel in `contentTintColor`,
  so it preserves the picture only when the picture is ONE color.
  An image is therefore made a template exactly when `WorkspaceIcon.isMonochrome(rgba:)` (host-free, over
  the raster `WorkspaceIconImage` produces) says every visible pixel shares one color; the row's `iconTint`
  is then read straight off `NSImage.isTemplate`, so the icon itself is the single source of truth.
  A colored image and a color emoji keep their own colors — `iconTint` is left nil, since tinting would
  paint over the picture.
  This REPLACED an "an SVG is a monochrome vector, so tint it" assumption that was simply false: an SVG
  whose background is an opaque full-bleed `<rect>` (the norm for a downloaded logo) masked to a SOLID
  BLOCK of the tint — the sidebar drew an empty rectangle instead of the icon — and a multi-color SVG
  flattened to a silhouette.
  A monochrome PNG is now tinted too, which is the same rule read forward (and it is what keeps a black
  glyph visible on a dark sidebar).
  `WorkspaceIconImage` (app target) resolves a spec to an `NSImage`, memoized by spec: a symbol through the
  existing `rowIcon` factory, a file through `NSImage(contentsOf:)` (an `.svg` loads as an `_NSSVGImageRep`
  that scales vectorially and honors `isTemplate`), an emoji rasterized via `NSAttributedString.draw`.
  Anything that fails to resolve — an unknown symbol, a missing file — degrades to the default glyph, never
  an empty row.
  An image is COPIED into `<stateDir>/workspace-icons/` so it survives the original being moved, with a
  FRESH filename per install: a name derived from the workspace id alone would make a swapped file produce
  an IDENTICAL spec, which the store's delta guard, the `RowContent` diff, and the image memo would each
  swallow (the row would keep the old picture until relaunch).
  There is NO SF Symbol picker in the GUI on purpose — no public API enumerates SF Symbols, so it would mean
  hand-curating a list; symbols and emoji are the agent/CLI surface.
- **Focus filter — a marked SET plus a separate flag (`AppStore+Focus.swift`).**
  `focusedWorkspaceIDs: Set<UUID>` is WHICH workspaces are marked; `focusEnabled: Bool` is WHETHER that set
  filters the tree.
  `visibleWorkspaces` is the marked set while the flag is on, else ALL workspaces — the source of truth the
  tree filters on (the data source maps `store.visibleWorkspaces` in `.tree`).
  Both fields are `public internal(set)`, so no app-target line can write them and the invariants below can
  only be broken from inside `rookCore`.
  Focus is ORTHOGONAL to flagged: the flat flagged view ignores it (it always shows the full cross-workspace
  set).
  A SET rather than one optional id because rook has many ways to jump across the tree that the USER did not
  ask for — idle auto-follow to a blocked session, attention navigation, a notification reveal, the
  dashboard, the recent-sessions popover — and each of those drops only the FLAG (the safety-net bullet
  below), so a hand-curated working set survives an unattended jump and one toggle brings it back.
  Peeking at the whole tree costs one toggle for the same reason, instead of losing the set.
  **Four mutators, and only four.**
  `setFocusedWorkspace(_:)` REPLACES the set with one workspace and ENABLES (the zoom-to-one that the row
  menu's Focus, the View menu, and `workspace.focus on` all drive);
  `setFocusMembership(_:member:)` adds or removes ONE member, leaving the others alone;
  `setFocusEnabled(_:)` flips the flag without touching the set;
  `clearFocus()` empties both.
  `toggleFocusedWorkspace(_:)` is THE definition of "toggle" — clear when the target is the SOLE applied
  member, else replace-and-enable — and the row menu, the `focus_workspace` keybind and `workspace.focus
  toggle` all route through that one function, so a toggle can never mean two things.
  `applyFocusMode(_:to:)` maps the wire's `on|off|toggle|add` onto them host-free, which is what keeps the
  GUI's replace-toggle and the wire's `toggle` from drifting; `off` is the REMOVE mode, which is why there
  is deliberately no separate `remove` token and no membership-toggle mode (the row's membership item
  computes its own direction from what it just read).
  **All four write through ONE private `commitFocus(ids:enabled:)`**, which owns the clamp, the delta guard
  (no write, no prune, no save when nothing changes — that is what makes every mutator idempotent for the
  delta-computed control/menu callers), the sidebar-selection prune, and the `save()`.
  Those four legs live THERE and nowhere else, so no future mutator can forget one.
  Marking is REFUSED for an id that names no workspace: a phantom member would persist a member no tree can
  render and make the `marked` read-back lie until the next restore pruned it.
  UN-marking is never gated on existence, so a stale id already in the set stays removable.
  **The workspace row's context menu carries the two as a GROUPED PAIR**, because they are two different
  gestures: "Focus"/"Unfocus" (`isSoleFocus(node.id)` picks the label) REPLACES the whole set with this
  workspace and applies the filter — the zoom-to-one — while "Add to Focus"/"Remove from Focus"
  (`focusedWorkspaceIDs.contains(node.id)` picks the label) edits membership only.
  The membership item computes its own direction from what it just read, which is why the mode vocabulary
  needs no membership-toggle; the View-menu/palette twins target `currentWorkspaceID` instead, having no
  clicked row (see [[menu-actions]]).
- **`focusEnabled` with an EMPTY set is UNREPRESENTABLE.**
  That is what makes the filter-ON half of the row-visibility contract exact: an applied filter always has at
  least one visible member, so "filtering" can never mean "showing nothing".
  `commitFocus` clamps `enabled` to false on an empty set, and four paths keep it clamped:
  `setFocusEnabled(true)` is a clean no-op on an empty set (matching the bottom-bar toggle, which is
  disabled in exactly that state), `setFocusMembership` disables as the set empties, `dropFocusMember(_:)`
  does the same for the paths that remove a workspace OUTRIGHT (`removeWorkspace`, `softRemoveWorkspace` —
  it exists so the remove-then-disable pair lives in ONE place and a third removal path added later gets the
  invariant for free; it deliberately does NOT save or prune, since its callers do both as part of the
  larger removal), and `restoreFocus(from:)` prunes ids absent from the restored tree before deciding the
  flag.
  `visibleWorkspaces`'s empty-result fallback to the full tree therefore guards an INVARIANT VIOLATION and
  nothing else — reachable only by writing the two fields directly from inside the module — and it renders
  everything because an empty sidebar strands the user with no rows at all.
- **Marking ONLY marks — an `add` NEVER switches the filter on.**
  A working set is built row by row with the whole tree still on screen and applied ONCE at the end.
  An add that enabled would collapse the tree onto the first member and hide the very rows the next add
  needs, so every add past the first would cost an extra toggle just to get the remaining rows back on
  screen — building a three-member set by hand instead of in one pass.
  `setFocusedWorkspace` (the REPLACING "Focus") is the one that enables immediately; `markFocusMember(_:)`
  (the undo legs) is insert-only for the same reason.
  `revealNewFocusMember(_:)` is the one insert conditional the other way: a freshly created workspace joins
  the set only while the filter is ON (the auto-reveal contract of `addWorkspace`/`ensureWorkspace`, which
  would otherwise render the existing members and silently hide the new one) — with the filter off the whole
  tree is already on screen, so there is nothing to reveal and the set must not widen behind the user's back.
  `session.new --no-select` passes `revealNewWorkspace: false` so a background create never widens the view.
- **`soleFocusedWorkspaceID` — the ONE workspace the tree is ZOOMED to**: the sole marked workspace while the
  filter APPLIES, else nil.
  The `focusEnabled` term is load-bearing — with a workspace marked but the filter OFF the whole tree is on
  screen, so the mark names nothing to zoom to — and two or more members give no unambiguous answer either.
  Three consumers read it: `isSoleFocus(_:)` (what makes the row menu's "Focus" read "Unfocus" and what a
  `toggle` clears; `isCurrentWorkspaceSoleFocus` is the same fact for the View menu's row-less item), the
  sidebar's force-expand in `rebuildAndReload`, and the empty-space Finder-folder-drop fallback
  (`SidebarDrop.resolveDirectoryWorkspace`'s `fallbackWorkspaceID`, so a folder dropped below the rows lands
  where the user is looking instead of adding a session outside the filtered view; with nothing marked, the
  filter off, or 2+ members the caller passes nil and the drop falls through to `currentWorkspaceID`).
  The force-expand deliberately stops at ONE member: a filtered tree of 2+ is a LIST, not a zoom, and
  re-expanding every member on each rebuild would undo the user's collapse of a member over and over while
  `tree` still reported it `collapsed`.
- **The control read-back keeps THREE fields — and this is where rook deliberately DIVERGES from upstream.**
  Per workspace, `tree` reports `focused` = the EFFECTIVE focus (`focusEnabled && focusedWorkspaceIDs.contains(id)`)
  and `marked` = MEMBERSHIP alone; the top level reports `workspaceFilter` = `focusEnabled`.
  INVARIANT: `focused == marked && workspaceFilter`.
  Upstream redefined `focused` to MEAN membership and has no `marked` at all; rook refused that, because
  folding the two together silently breaks every record-then-restore script already in the wild — a script
  that recorded `focused` would restore only the members that happened to be filtering at capture time.
  The row-visibility contract, to be written in FULL wherever it appears:
  **a workspace ROW is visible iff `sidebarVisible && sidebarMode == "tree" && (!workspaceFilter || marked)`.**
  Neither shorter form is safe: `focused && workspaceFilter` claims nothing is visible whenever the filter is
  off (and a script correcting for that reaches for `workspace.focus on`, which REPLACES the set), while a
  bare `!workspaceFilter || marked` claims rows are visible in flagged mode and behind a hidden sidebar.
  `visibleWorkspaces` spells only the `(!workspaceFilter || marked)` TERM in code — the mode and the
  visibility gate the tree ABOVE it (`.flagged` renders a flat session list and never calls in), so it is
  not the whole predicate a script evaluates.
  See the Control API rule for `workspace.focus`/`workspace.filter` themselves and their window-scoped
  addressing.
- **A MARKED workspace row draws its icon at `.heavy` WEIGHT — never a `.fill` variant.**
  Fill already means a flagged SESSION (the tree-mode flagged-indicator bullet above), so heavy is what means
  a marked WORKSPACE, and the two markers stay distinguishable at a glance.
  `workspaceRowIcon(for:member:)` keys it on MEMBERSHIP alone, independent of `focusEnabled` — a marked row
  reads heavy while the filter is still OFF, which is exactly what makes a set legible while it is being
  built.
  `focusMember` is its own field on the row's `RowContent` (separate from the session-only `flagged`), so a
  mark/unmark with the filter off re-renders just that row via `reloadItem`; with the filter on the tree
  SHAPE changes too and the rebuild branch takes over.
  Like the flagged fill it is a symbol swap, not a composited corner badge: the heavy variant renders 1pt
  larger (16x15 vs 15x14), but the row's icon view is pinned to a fixed 16x16 box with
  `scaleProportionallyUpOrDown`, so neither swap moves anything.
  **CEILING — rook's own, and it comes from rook's per-workspace custom icons (the bullet above).**
  Weight is a symbol CONFIGURATION, not a different symbol, so the marker reaches TEMPLATE SYMBOL icons
  only: the default `square.grid.2x2` glyph (cached as `focusedWorkspaceIcon`) and a custom SF-symbol icon,
  re-rendered at `.heavy` here rather than taken from `WorkspaceIconImage`, whose memo holds the regular
  weight.
  A custom EMOJI or IMAGE-FILE icon has no weight axis, so it renders unchanged and carries NO membership
  marker; for those workspaces membership stays readable from the row's context menu, the bottom-bar toggle,
  and `tree`'s `marked`.
- **The bottom-bar `focus-filter-toggle` REPLACED the focus pill.**
  A 2-state grid glyph (`square.grid.2x2`, filled while filtering) right of the trailing `Spacer()`, beside
  the flagged toggle, driving `AppActions.toggleFocusFilter()` → `setFocusEnabled(!focusEnabled)`.
  It is both the indicator AND the control, and the only affordance that still works while the filter is OFF
  — which is why the pill had to go: the pill rendered the EFFECTIVE focus and vanished with it, so an
  involuntary jump that dropped the flag took the way back with it.
  Disabled on an empty marked set (there is nothing to filter to), the same state the store refuses to enable
  in, so the two agree by construction; the explicit `chromeText` foregroundStyle defeats SwiftUI's default
  disabled dimming, so it is hand-muted to 0.35 opacity — the same rule as the flagged toggle.
  **Its `accessibilityValue` ("on"/"off") is now the ONLY accessibility-observable read of whether the filter
  applies**: an SF Symbol is not accessibility-observable, and the pill that used to report the state is
  gone, so a UI test has nothing else to assert against.
  Gated by the `focusFilter` Interface element ("Workspace filter") like the other bottom-bar buttons — see
  [[settings]].
- **Scoped session navigation (the VISIBLE/FILTERED set).**
  Session navigation operates over `AppStore.navigableSessions`, NOT the whole tree:
  `sidebarMode == .flagged ? flaggedSessions : visibleWorkspaces.flatMap(\.sessions)` — i.e. the flagged
  set in `.flagged` mode, EVERY marked workspace's sessions while the filter applies (tree mode, walked in
  TREE order, so a multi-member set steps workspace-by-workspace exactly as the sidebar renders it),
  else ALL sessions.
  Computed LIVE (`visibleWorkspaces` already collapses to the marked set or the full tree), so clearing the
  flag/filter naturally restores the full set.
  `navigateSession(_:)` flattens `navigableSessions` for EVERY direction — next/prev/first/last AND attention-nav
  (next-attention/prev-attention scope to the filtered set too) — keeping the same "no/invalid selection
  → first of the filtered list", "next/prev WRAP within the filtered set (like attention-nav)" semantics
  over the filtered list.
  This is shared by `session.go` (control, no ControlServer change — it already routes through `navigateSession`),
  the ⌥⌘↑/↓ + ⌃⌥↑/↓ menu/palette nav, the Ctrl-Tab MRU switcher (`SessionSwitcher.begin()` scopes its
  candidate set to `store.navigableSessions.map(\.id)`; the MRU ORDER still comes from `sessionRecency`),
  AND the ⌃P fuzzy session palette (`AppActions.paletteSessions()` lists `store.navigableSessions`,
  so the searchable set matches the visible sidebar — under an applied filter ⌃P shows only the marked
  workspaces' sessions, in flagged mode only the flagged ones).
  This SUPERSEDES the earlier "global nav reveals its target" behavior.
- **Cross-set safety net (`disableFocusIfSelectionOutsideSet`) — the FLAG drops, the SET SURVIVES.**
  Because nav is scoped, its targets are ALWAYS in-set and never trip this.
  `selectSession` stops FILTERING when the newly selected session lives OUTSIDE the marked set, which now
  only happens on an EXPLICIT cross-set select: `session.select <id>` of a hidden session, a notification
  reveal, idle auto-follow, or a move/close that reselects elsewhere.
  The active session is then always inside the visible set, which also keeps `currentWorkspaceID`
  (new-session placement) consistent with NO special case.
  **Only the flag drops.**
  None of its callers is the user saying they are done with the focus — most fire while nobody is at the
  keyboard — so forgetting what was marked (what the pre-split single-id version did, nilling the focus
  outright) could kill a working set unattended with nothing left to go back to.
  Now one toggle returns to it: the bottom-bar button, View ▸ Toggle Workspace Filter, or
  `rookctl workspace filter on`.
  Clean no-op when the filter is off, when nothing is selected, or when the selection sits in a member
  workspace; persistence rides the caller's `selectSession` save.
  The contract is ONE-DIRECTIONAL by design: an explicit cross-set select suspends the filter (reveal),
  but marking a workspace that does NOT contain the active session deliberately does NOT reselect or
  switch the active terminal — focus is a pure view filter, never a terminal switch,
  so the active session's terminal keeps rendering while the sidebar shows no selection until the next
  select (the bottom-bar toggle signals the state, and it self-heals on the next
  `selectSession`/`addSession`).
  This stranded-selection state is intentional, not a bug.
- **Both undo legs re-MARK; NEITHER restores the flag.**
  The pending-close undo (`PendingWorkspaceClose.focusMember`) and Reopen Closed Item
  (`RecentClosedWorkspace.focusMember`) each record whether the closed workspace was a set member and put it
  back through `markFocusMember(_:)` — insert-only, so it can never enable and `enabled + empty` stays out
  of reach.
  The flag is left exactly as the window has it, for two INDEPENDENT reasons.
  (1) The undo's record is only ~3 s old, but the user can suspend the filter INSIDE that grace with one
  click on the bottom-bar toggle, and a flag-restoring undo would beat their most recent explicit action
  (the capture was one-directional too — only ever set true).
  (2) ONE `RecentClosedStore` is shared by every window and its entries survive indefinitely, so a stored
  flag would let a record written in window A switch window B's filter on.
  Membership belongs to the closed workspace; the FLAG is current-window state.
  Both legs re-mark BEFORE their reselect, so a restored member is inside the set when
  `disableFocusIfSelectionOutsideSet` runs — and the undo does it ahead of its empty-workspace early return,
  whose row would otherwise stay filtered out and make the undo look like a no-op.
  `RecentClosedWorkspace.focusMember` is OPTIONAL because that struct is persisted in `recent-closed.json`
  and `RecentClosedStore.load()` turns a decode failure into an EMPTY list (a required key would wipe the
  user's whole recent list on the first launch after the upgrade); `PendingWorkspaceClose.focusMember` is
  NOT Optional, being in-memory only and dying with the grace window.
  **The fold carries membership into an ABSORBED record.**
  When a second close of the same workspace supersedes a pending one, `foldingPendingCloses` ORs the
  absorbed record's `focusMember` into the new one, and `softRemoveWorkspace` ORs that into its own live
  read: the rebuilt workspace shell carries no membership (the superseded record's own close already dropped
  it, and a session undo that rebuilt the shell does not re-mark), so the absorbed flag is the only surviving
  copy — and both records key ONE Open Recent entry (deduped on the workspace id), so losing it would kill
  BOTH recovery routes.
- **Mode/focus-aware reconcile signal.**
  The reconcile `TreeShape` is computed from the MODE-selected/filtered roots:
  in `.tree` it is `visibleWorkspaces` → `(workspaceID, sessionIDs)` (so a focus flip re-shapes),
  in `.flagged` it is a SINGLE flat group keyed on a stable pseudo-id (`flaggedShapeID`,
  so within flagged mode only a change to the flagged list — not a fresh per-call id — rebuilds).
  A `lastMode` flip swaps the whole data source and forces a `rebuildAndReload` regardless of the shape
  diff; `sidebarMode`, BOTH focus fields, and each session's `flagged` are folded into the `updateNSView`
  dependency read so a mode/focus/flag change is seen.
  **Both focus fields, and both are load-bearing** — `@Observable` only notifies for what was actually read,
  so reading one leaves the other's change invisible and the sidebar simply never redraws for it:
  `focusedWorkspaceIDs` drives the per-row membership marker (a mark/unmark with the filter off leaves the
  tree shape alone, so only row CONTENT changes), while `focusEnabled` restricts the tree to the marked roots
  through `visibleWorkspaces` (a rebuild).
  **Task 9 expansion-restore fix:** `NSOutlineView` discards the expansion state of items DROPPED from
  the data source during a flagged-mode reload, so expanded workspace ids are tracked independently in
  `expandedWorkspaceIDs` via the `outlineViewItemDidExpand`/`outlineViewItemDidCollapse` delegate callbacks
  (and `expandAll`) and re-applied in `rebuildAndReload` (`expandItem` for each tracked id),
  surviving the round-trip through flagged mode.
- **Expand / collapse all workspaces (per-window).**
  Two sidebar tree operations: **Expand Workspaces** (`AppActions.expandAllWorkspaces(in:)` → the Coordinator's
  existing `expandAll`, every workspace open) and **Collapse Workspaces** (`collapseOtherWorkspaces(in:)`
  → the Coordinator's `collapseOthers`, every workspace collapsed EXCEPT the active session's `currentWorkspaceID`,
  kept expanded + `scrollRowToVisible`'d).
  Both keep `expandedWorkspaceIDs` in sync (so the state survives a flagged-mode round-trip).
  Per-window scoping rides a notification (`.rookExpandWorkspaces`/`.rookCollapseWorkspaces`) posted
  with the TARGET window's `AppStore` as the object; each Coordinator registers its observer with `object: store`,
  so only the matching window's sidebar acts.
  The two rename notifications scope IDENTICALLY (`object: store` on both the post and the observer);
  they used to be `object: nil` on the claim that the selected-session guard scoped them,
  which it never did — every open window has a selection, so a rename opened an editor in all of them.
  This object-scoping is what lets the control path target ANY open window.
  Graceful no-op in `flagged` mode (no workspace rows).
  GUI surfaces (frontmost window): View ▸ Expand/Collapse Workspaces (plain keyless items,
  disabled with no store or in flagged mode) + the ⌃⇧P palette (tree-mode only).
  Control: `sidebar.expand`/`sidebar.collapse` resolve the target store via `resolvePlacementStore(window)`
  (frontmost by default, the global `--window` selector for any open window) and call the `(in:)` variants
  — so unlike the frontmost-only `sidebar`/`sidebar.mode`, these can drive a background window's tree
  (see the Control API catalog).
- **Collapse / expand ONE workspace (control-native).**
  `workspace.collapse` / `workspace.expand` address a SINGLE workspace, honoring the global `--window`
  selector like the other `workspace.*` commands, and `workspace.new --collapsed` seeds a workspace
  already closed so a script can fill it with `session.new --no-select` without it popping open.
  CLI: `rookctl workspace collapse|expand [--target <id>]` — the target is an OPTION (the shared
  `TargetOptions`, defaulting to `active`), NOT a positional, unlike `rookctl window minimize [id]`;
  and `rookctl workspace new [name] --collapsed`, where the name IS positional.
  The read-back is `collapsed` on the `tree` workspace node — `true` when collapsed, OMITTED when expanded
  (expanded is the default, matching the persisted `WorkspaceSnapshot.collapsed`), so it reports the
  persisted model state (`!isExpanded`) and is unaffected by a transient focus force-reveal.
  There is deliberately no `AppActions` hop: unlike the all-workspace pair this has no GUI caller (a row
  click drives the outline directly), so the control arm in
  `rook/Control/ControlServer+WorkspaceCommands.swift` is its only entry point.
  **The arm writes the STORE first and posts the notification only for the live outline — that order is
  load-bearing.**
  `setWorkspaceExpanded` (delta-guarded, so the commands are idempotent) is the source of truth for the
  read-back, and `WorkspaceSidebar` is mounted ONLY while that window's sidebar is VISIBLE — so a
  notification-only write would silently drop with the sidebar hidden, leaving the command ok-but-inert.
  The poke is `.rookSetWorkspaceExpanded`, store-scoped (`object: store`) like the all-workspace pokes,
  with the workspace id + desired state in `userInfo`; the Coordinator's `setWorkspaceExpandedNotified`
  only keeps `expandedWorkspaceIDs` in step and drives the on-screen row, with `suppressExpansionPersist`
  set so the expand/collapse callback does not re-persist what the store already holds.
  **The window-wide `sidebar.expand`/`sidebar.collapse` do NOT have this property**: they only POST, so
  with the target window's sidebar hidden they change nothing readable — `collapsed` is NOT a reliable
  read-back for them.
  Reach for the per-workspace pair when a script needs to read back what it set.
- **Persistence (per-window, no version bump).**
  `Session.flagged` persists via `SessionSnapshot.flagged: Bool?` (decode → `false`),
  `sidebarMode` via `Snapshot.sidebarMode: SidebarMode?` (→ `.tree`), the focus filter via
  `Snapshot.focusedWorkspaceIDs: [UUID]?` + `Snapshot.focusEnabled: Bool?` (both → nothing marked, not
  filtering), and each workspace's expand/collapse state via `WorkspaceSnapshot.collapsed: Bool?`
  (decode → `false` → expanded).
  All five Optional fields, so legacy JSON with none of the keys decodes to the unflagged / `.tree`
  / unmarked / expanded defaults without throwing (the load-fresh-on-decode-failure contract) — no `Snapshot`
  version bump.
  `collapsed` is stored as the INVERSE of `Workspace.isExpanded` and only WRITTEN when collapsed (`true`);
  an expanded workspace omits it, so an all-expanded tree serializes byte-identically to a legacy snapshot,
  and "lack of the field = expanded" holds.
  The sidebar Coordinator seeds `expandedWorkspaceIDs` from `Workspace.isExpanded` in `makeNSView`
  (`seedExpansionFromModel`, replacing the old unconditional `expandAll`) so a collapsed workspace restores
  collapsed.
  **Only a GENUINE user toggle persists.**
  The `outlineViewItemDidExpand`/`DidCollapse` callbacks write back via `AppStore.setWorkspaceExpanded(_:expanded:)`
  (a PER-workspace mutator, so toggling one row never rewrites another's saved state), and `expandAll`/`collapseOthers`
  persist the whole tree once via `setWorkspacesExpanded(_:)`.
  A `suppressExpansionPersist` flag is set around every PROGRAMMATIC `expandItem`/`collapseItem` — the launch/`rebuildAndReload`
  re-apply, the `syncSelection` reveal, and the `soleFocusedWorkspaceID` force-expand — so those update the VISUAL
  `expandedWorkspaceIDs` (needed for the flagged-mode round-trip) WITHOUT touching the persisted `isExpanded`.
  This is what makes a deliberate collapse durable: revealing a session inside a collapsed workspace (nav,
  notification click, or the launch-time active-session reveal) or focusing it shows the row but does NOT
  un-collapse it on disk — the collapse survives until the user expands the row themselves.
  The active session is still force-revealed on launch (`syncSelection`), so it is never hidden inside a
  collapsed workspace; the row just re-collapses on the next launch (its persisted state is untouched).
  Round-trips + legacy-decode (incl. explicit `collapsed:false`) covered in `PersistenceTests`,
  per-workspace + whole-tree mutators / no-op-no-write in `AppStoreOrganizationTests`, and the
  collapse-survives-relaunch + reveal-does-not-repersist end-to-end cases in `SidebarUITests`.
- **The focus snapshot is an ARRAY plus a flag, and `Snapshot.init(from:)` migrates THREE generations onto
  it.**
  `focusedWorkspaceIDs` is `[UUID]?` in TREE order rather than a `Set` so the on-disk list is deterministic
  instead of following the Set's hash order, and `focusEnabled` is stored APART from it so an OFF filter
  keeps its members across a relaunch — the state an involuntary jump leaves behind is precisely the state
  the split exists to protect, and persisting only the effective focus is what made the old single mark die
  at quit.
  The two legacy keys live in their own private `LegacyCodingKeys` with NO stored properties, read only by
  `init(from:)`: re-encoding a migrated snapshot then DROPS them instead of writing the legacy keys back on
  every load-mutate-save, and extra cases in `CodingKeys` would have blocked the synthesized `encode(to:)`
  outright.
  The three generations, in the order they shipped:
  - **Ancient — `focusedWorkspaceID` alone.**
    That field meant "the tree is collapsed to this workspace", so its presence IMPLIED the filter was on →
    a one-member ENABLED set.
  - **`focusedWorkspaceID` + `markedWorkspaceID` — the two-bit split, and what real files hold TODAY.**
    This generation exists in OUR migration and not upstream's: rook shipped the mark as its own persisted
    key in 62097fb, after the split turned out to store only the effective focus and lose the mark at quit.
    There the MARK is the set and the effective id is only the FLAG, so the set is
    `markedWorkspaceID ?? focusedWorkspaceID` and the flag is `focusedWorkspaceID != nil`.
    Reading the effective id as the set (upstream's migration) would DROP the mark and restore an EMPTY set
    for exactly the state an involuntary jump leaves behind — the one the split was built to persist.
  - **The new keys present — passed through verbatim.**
    They WIN outright: the legacy container is opened only when BOTH `focusedWorkspaceIDs` and
    `focusEnabled` are absent, so a legacy key left in a hand-edited file can never override what the
    current build wrote.
  `restoreFocus(from:)` then intersects the decoded ids with the rebuilt tree and clears the flag if that
  leaves the set empty (an all-stale set — its workspaces deleted by another window, or a hand-edited file —
  would otherwise restore as an enabled-but-invisible filter and make the row-visibility contract lie; a
  partially stale set keeps its survivors and stays enabled).
  It runs AFTER the tree is rebuilt and writes the two fields DIRECTLY rather than through the mutators,
  which would `save()` what was just read.
