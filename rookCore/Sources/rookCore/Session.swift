import Foundation
import Observation

/// Which pane a pane-scoped overlay covers. Two cases rather than `StatusPane` so a scratch overlay is
/// not representable and no call site needs a scratch guard.
public enum OverlayPane: String, CaseIterable, Codable, Sendable {
    case left
    case right

    /// Accepts the same pane spellings as `TerminalZoomSurface`, minus `scratch`: a pane overlay covers a
    /// split pane only. `primary`/`split` are accepted as aliases, so the rejection message naming only
    /// `left or right` is guidance, not the full accepted set.
    public init?(controlName: String) {
        switch controlName {
        case "left", "primary":
            self = .left
        case "right", "split":
            self = .right
        default:
            return nil
        }
    }

    /// The three `Session` slots this pane owns, plus its zoom surface — the ONE place the
    /// `left`↔`leftOverlay*` mapping is written. Every reader and writer goes through these key paths, so a
    /// transposed ternary can no longer drive the wrong pane from any of the call sites.
    @MainActor public var overlaySlot: ReferenceWritableKeyPath<Session, PaneOverlay?> {
        self == .left ? \.leftOverlay : \.rightOverlay
    }

    @MainActor public var surfaceSlot: ReferenceWritableKeyPath<Session, (any TerminalSurface)?> {
        self == .left ? \.leftOverlaySurface : \.rightOverlaySurface
    }

    @MainActor public var exitCodeSlot: ReferenceWritableKeyPath<Session, Int?> {
        self == .left ? \.leftOverlayExitCode : \.rightOverlayExitCode
    }

    /// The zoom surface addressing this pane's overlay (`surface:<id>:overlay-left|overlay-right`).
    public var zoomSurface: TerminalZoomSurface {
        self == .left ? .overlayLeft : .overlayRight
    }

    /// The pane itself as a zoom surface, the slot this overlay covers.
    public var paneZoomSurface: TerminalZoomSurface {
        self == .left ? .primary : .split
    }
}

/// One pane's ephemeral overlay — the session-scoped overlay's fields minus the size percent, which a
/// pane overlay never has (it is always full-pane). The surface lives beside this in
/// `leftOverlaySurface`/`rightOverlaySurface`, not inside, because `TerminalView` writes that slot back
/// during view update and an observed write there would loop.
public struct PaneOverlay: Equatable, Sendable {
    /// The command the overlay runs as its process, read by the overlay factory at creation.
    public var command: String
    /// The overlay's working directory, or nil to inherit `effectiveCwd`.
    public var cwd: String?
    /// The overlay's own solid background as `#rrggbb`, nil for the theme default. Per-surface, so two
    /// pane overlays open at once may carry different colors.
    public var backgroundColor: String?
    /// Whether the overlay holds its surface after the command exits (libghostty's "press any key to
    /// close"), instead of closing.
    public var wait: Bool

    public init(command: String, cwd: String? = nil, backgroundColor: String? = nil, wait: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.backgroundColor = backgroundColor
        self.wait = wait
    }
}

/// One shell, backed by a single libghostty surface.
///
/// `@MainActor` (so it's implicitly `Sendable` via isolation — never made an
/// `actor`). The `surface` slot is `@ObservationIgnored` so assigning the
/// lazily-created NSView never churns observation; `customName`/`currentCwd` are
/// observed, so the sidebar refreshes when a rename or PWD report lands.
@Observable
@MainActor
public final class Session: Identifiable {
    public let id: UUID
    public var customName: String?
    /// The live working directory from the latest OSC 7 / PWD report. Observed, so
    /// the sidebar row refreshes when it changes. It is captured by `snapshot()`
    /// and so persisted on quit and on structural mutations, but a bare `cd` does
    /// not trigger a save (OSC 7 fires constantly), so a crash loses only cwd
    /// changes since the last structural mutation.
    public var currentCwd: String?
    public let initialCwd: String

    /// The terminal title from the latest OSC 0/1/2 set-title report — set by a shell
    /// `PROMPT_COMMAND`, ghostty's shell integration, or a remote host over SSH. Observed, so the
    /// sidebar row refreshes when it changes. Ephemeral like `currentCwd`/`unseenCount`:
    /// `SessionSnapshot` doesn't capture it, and a bare prompt redraw doesn't trigger a save.
    public var oscTitle: String?

    /// The split (right) pane's live cwd and terminal title, reported by the split surface (the one
    /// flagged `isSplitPane`). Observed and ephemeral like `currentCwd`/`oscTitle`; nil when there is
    /// no split pane. While the split pane has focus, the sidebar row and title bar derive their
    /// name/cwd from these instead of the primary's, so the chrome tracks whichever pane you're in.
    public var splitCwd: String?
    public var splitTitle: String?

    /// Count of unseen terminal notifications fired by this session's panes while it wasn't focused.
    /// Observed, so the sidebar badge reacts. Ephemeral: `SessionSnapshot` doesn't capture it, so it
    /// never survives a relaunch.
    public var unseenCount: Int = 0

    /// The per-session agent status, driven over the control channel (`session.status`). Observed, so
    /// the sidebar row's status glyph reacts. Ephemeral like `unseenCount`: `SessionSnapshot` doesn't
    /// capture it, so it never survives a relaunch.
    public var agentIndicator = AgentIndicator()

    /// The coding agent currently running in this session's focused pane, or nil for none — OBSERVED from
    /// the pane's foreground process by the app-side `AgentMonitor`, not reported by the agent. Observed,
    /// so the sidebar row swaps the terminal glyph for the agent's logo. Ephemeral like `unseenCount`:
    /// `SessionSnapshot` doesn't capture it (the next launch re-detects it within a poll tick).
    public var agentKind: AgentKind?

    /// The most-recent time the agent status was set to a non-idle value — stamped by
    /// `AppStore.setAgentIndicator` on EVERY non-idle set (`Date()` for any non-idle status, nil on idle),
    /// not only on an idle→non-idle transition. Sort key only — the attention list orders same-status
    /// sessions newest-change-first. `@ObservationIgnored` (no view reacts to it; the list reads it as a
    /// sort key) and ephemeral: `SessionSnapshot` doesn't capture it, so it never survives a relaunch.
    @ObservationIgnored public var statusChangedAt: Date?

    /// Whether idle auto-follow has already pulled the user to THIS blocked episode. Set by
    /// `AppStore.autoFollowFire` when it jumps here, so a later idle fire won't yank the user back to a
    /// block they've already been shown and left. Reset to false by `AppStore.setAgentIndicator` when the
    /// session transitions INTO blocked from a non-blocked status (a new episode is eligible for one more
    /// pull) — keyed off the transition, not `statusChangedAt`, so a hook re-asserting `blocked` over
    /// `blocked` stays muted. `@ObservationIgnored` (no view reacts) and ephemeral (absent from `SessionSnapshot`).
    @ObservationIgnored public var autoFollowConsumed = false

    /// Whether this session is in the flagged working-set — a durable, user-set flag that surfaces the
    /// session in the sidebar's flat flagged view (across workspaces) and swaps its tree row to the
    /// filled icon variant. Observed, so the sidebar reacts to a toggle. Persisted via `SessionSnapshot.flagged`,
    /// so it survives a relaunch (and a workspace move — the flag travels with the session).
    public var flagged: Bool = false

    /// Whether this session's file-tree panel (a right-hand `NSOutlineView` browsing `fileTreeRoot`) is
    /// shown. Per-session and hidden by default: each session independently toggles its own panel. Observed,
    /// so the detail column shows/hides the panel when it flips. Persisted via `SessionSnapshot.fileTreeVisible`,
    /// so a shown panel survives a relaunch (the root re-derives from the restored cwd — see `fileTreeRoot`).
    public var fileTreeVisible: Bool = false

    /// The directory the file-tree panel is rooted at — captured from `effectiveCwd` when the panel is
    /// first shown and then held fixed, so it does NOT chase every `cd` (the panel is a stable browser, not
    /// a live cwd mirror; a re-root action snaps it back to the current cwd). Observed, so the panel rebuilds
    /// when it changes. In-memory only (NOT captured by `snapshot()`): a restored session with the panel
    /// VISIBLE re-pins it to the restored cwd (`AppStore.session(from:)`) so it stays fixed instead of
    /// chasing the live cwd; a hidden one leaves it nil and seeds on first show.
    public var fileTreeRoot: String?

    /// Bumped by `AppStore.rerootFileTree` to force the file-tree panel to re-read its current root from
    /// disk even when the root PATH is unchanged (a manual refresh — picks up files created/deleted since
    /// the panel opened, since there is no live FS watch yet). Observed so the panel reacts; in-memory only.
    public var fileTreeRefreshToken: Int = 0

    /// The Markdown file this session's preview panel is rendering, or nil when the panel is closed — the
    /// path IS the visibility, since a preview panel with no file is meaningless (unlike the file tree, whose
    /// root outlives a hide). Set by a `.preview` link click (`LinkPolicy`), the View menu, or
    /// `session.markdown`. Observed, so the detail column shows/hides the panel when it flips. Persisted via
    /// `SessionSnapshot.markdownPath` — an absolute path, so it restores as-is with no re-derivation.
    public var markdownPath: String?

    /// Bumped to force the preview panel to re-read its file from disk even when the PATH is unchanged: a
    /// manual refresh, and the re-open of an already-open file (clicking the same link twice should show what
    /// is on disk NOW, not the render from before the agent rewrote it). Observed; in-memory only.
    public var markdownRefreshToken: Int = 0

    /// Changes ONLY when one LIVE primary-slot surface is replaced by another. The SwiftUI terminal hosts
    /// fold this into their identity, so a split-survivor promotion (`closePrimaryPane`) remounts the host
    /// and SwiftUI drops the torn-down view — `updateNSView` cannot swap the AppKit view `makeNSView`
    /// returned, so session identity alone keeps hosting the dead pane and the user sees a blank terminal.
    ///
    /// The live→live guard is load-bearing, do NOT simplify it to an unconditional `didSet`: lazy creation
    /// (nil → first surface) and a re-assignment of the SAME instance must leave it at zero, or every host
    /// remounts right after `makeNSView` and re-parents the surface, which invalidates its Metal drawable.
    @ObservationIgnored public private(set) var primarySurfaceHostRevision = 0

    /// The app-side surface (a `GhosttySurfaceView`). Lazily created on first
    /// display and owned here so it survives sidebar/detail view churn.
    @ObservationIgnored public var surface: (any TerminalSurface)? {
        didSet {
            guard let oldValue, let surface, oldValue !== surface else { return }
            primarySurfaceHostRevision &+= 1
        }
    }

    /// Whether the session is shown as a one-level vertical split (two panes side by
    /// side). Observed, so the detail pane shows/hides the second pane when toggled.
    public var isSplit: Bool = false

    /// Whether the session HAS a split pane at all (shown side-by-side OR hidden/maximized to one
    /// pane), as opposed to `isSplit` which is only "currently shown". Stays true across a hide, and
    /// is cleared only when the split is closed (`closeSplit`). Observed, so the sidebar + title-bar
    /// split indicators persist while a split is merely hidden.
    public var hasSplit: Bool = false

    /// While split, whether the split (second) pane holds focus rather than the primary.
    /// Observed, so the detail pane can dim the inactive pane. Meaningless when not split.
    public var splitFocused: Bool = false

    /// The split divider's left-pane fraction, captured from the live `NSSplitView` so the side-by-side
    /// ratio survives a hide/show and a relaunch (persisted in `SessionSnapshot`). Within
    /// `AppStore.splitRatioMin...splitRatioMax` (~0.05...0.95) - the capture skips degenerate extremes and
    /// restore clamps. Seeded on restore, kept current by the split's introspection accessor;
    /// `@ObservationIgnored` because it is read/written imperatively, not by any SwiftUI view. nil = even.
    @ObservationIgnored public var splitRatio: Double?

    /// The second pane's surface, lazily created on first split. `@ObservationIgnored`
    /// like `surface`; it survives view churn, so hiding the split keeps the shell alive
    /// rather than destroying it. Freed only on `closeSplit`/`closeSession`.
    @ObservationIgnored public var splitSurface: (any TerminalSurface)?

    /// The directory the split (right) pane re-spawns in on restore, set from the persisted
    /// `SessionSnapshot.splitCwd` so each pane keeps its own cwd across relaunch. nil for a
    /// fresh (never-restored) split, which seeds from the session's `effectiveCwd` instead.
    /// `@ObservationIgnored`: read imperatively by the split factory, captured by `snapshot()`.
    @ObservationIgnored public var initialSplitCwd: String?

    /// The terminal font size in points, or nil to use the ghostty config default. The app
    /// sets the surface's initial size from this on creation and writes it back when the
    /// user changes it (cmd +/-). `@ObservationIgnored`: nothing in SwiftUI reacts to it —
    /// it is read imperatively at surface creation and captured by `snapshot()`.
    @ObservationIgnored public var fontSize: Double?

    /// The session's background watermark (an image or rasterized text composited behind the terminal),
    /// or nil for none. The app target applies it to the session's surface(s) via a per-surface ghostty
    /// config overlay (see `WatermarkConfig`) at creation, on change, and after a global config reload.
    /// `@ObservationIgnored` like `fontSize`: nothing in SwiftUI reacts — it is read imperatively when a
    /// surface is (re)configured and captured by `snapshot()`, so it survives a relaunch (a `.text`
    /// watermark re-renders its PNG on restore).
    @ObservationIgnored public var backgroundWatermark: BackgroundWatermark?

    /// The shell this session's panes spawn (an absolute path), inherited from whoever asked for the
    /// session over the control channel (`session.new --shell`); nil means the app's own default shell.
    /// Spawn identity like `initialCommand`, not observable UI state, so `@ObservationIgnored`. Persisted
    /// via `SessionSnapshot.shell` so a fish session comes back fish after a relaunch — which is also why
    /// `SurfaceCommand.resolve` re-checks the path: this reaches a surface straight from disk, past the
    /// dispatcher that validated it on the way in.
    @ObservationIgnored public var shell: String?

    /// A command to run as the session's process instead of the login shell (like kitty's `launch
    /// <cmd>` / ghostty's `command`), set at creation via `session.new --command`. The surface factory
    /// reads it once; on the command exiting the session closes (the normal single-pane exit path).
    /// `@ObservationIgnored`. Persisted via `SessionSnapshot.initialCommand` so a command session — e.g.
    /// an `ssh …` shortcut, which exec-replaces the shell and so is invisible to the foreground-pid
    /// capture — re-runs its command on restore instead of coming back a plain shell. The restore re-run
    /// is gated by `restoreRunningCommand` (via `wasRestored`); a fresh session always runs it.
    @ObservationIgnored public var initialCommand: String?

    /// Whether a `--command` session HOLDS its surface after the command exits (showing libghostty's
    /// "press any key to close" prompt with the final output intact) instead of closing immediately, set
    /// at creation via `session.new --command … --wait`. The same libghostty `wait_after_command` the
    /// overlay's `overlayWait` uses, applied to the PRIMARY surface (`makeSurface` reads it). Meaningful
    /// only with `initialCommand`; a plain shell has nothing to hold. `@ObservationIgnored`. Persisted via
    /// `SessionSnapshot.commandWait` so a restored command session that re-runs its command holds again,
    /// keeping the held/closed behavior consistent across restart.
    @ObservationIgnored public var commandWait: Bool = false

    /// True when this session was rebuilt by `AppStore.restore(from:)` rather than freshly created. The
    /// surface factory reads it to gate the `initialCommand` re-run: a FRESH command session always runs
    /// its command, but a RESTORED one re-runs only when `restoreRunningCommand` is on (else a plain
    /// shell). `@ObservationIgnored`; transient, never persisted.
    @ObservationIgnored public var wasRestored = false

    /// The main pane's foreground command (full argv) captured at the last clean quit, for the
    /// restore-running-command feature. `@ObservationIgnored`: written imperatively by the quit-flush
    /// capture and read once by the surface factory on restore (then cleared, like `scratchCommand`).
    /// Persisted via `SessionSnapshot.foregroundCommand`; nil when the pane was at its prompt.
    @ObservationIgnored public var foregroundCommand: [String]?
    /// The split (right) pane's foreground command (full argv), the split analogue of `foregroundCommand`.
    @ObservationIgnored public var splitForegroundCommand: [String]?

    /// The main pane's PERSISTED restore-command override, set over the control channel
    /// (`session.restore`). Tri-state: nil = no override (the auto-capture behavior), `""` = pinned to
    /// nothing (a plain shell, suppressing both the capture and `initialCommand`), `"cmd"` = run that shell
    /// line VERBATIM. STICKY, unlike the capture: never cleared on read, so it fires again after every
    /// restart until something changes or clears it. It needs its OWN slot rather than sharing
    /// `foregroundCommand` because the quit-time capture would otherwise clobber it with the live process's
    /// argv, and because it is a shell LINE (a pipeline, a compound `&&`), not an argv to re-quote.
    /// `@ObservationIgnored`; persisted via `SessionSnapshot.restoreCommand`.
    @ObservationIgnored public var restoreCommand: String?
    /// The split (right) pane's persisted restore-command override, the split analogue of `restoreCommand`.
    @ObservationIgnored public var splitRestoreCommand: String?

    /// The main pane's TRANSIENT override payload for THIS launch, copied from the persisted
    /// `restoreCommand` by `armPendingRestoreOverrides()` — which only an app-bootstrap restore calls — and
    /// consumed by `takePendingRestoreOverride(pane:)`. NEVER persisted (absent from `sessionSnapshot`). A
    /// session that was not bootstrap-restored — freshly created, reopened from Recent Closed, duplicated,
    /// or rebuilt when a closed window was reloaded mid-process — starts nil, so nothing fires. This is the
    /// ONLY restore-override state a surface factory may read: it freezes what was eligible when the process
    /// started, so a command written over the socket during this run can never execute during this run.
    @ObservationIgnored public var pendingRestoreCommand: String?
    /// The split (right) pane's transient override payload, the split analogue of `pendingRestoreCommand`.
    /// Armed only when the restored snapshot's split was SHOWN (`isSplit`): a hidden split builds no right
    /// surface at bootstrap, so a payload left pending would fire on a later manual ⌘D instead.
    @ObservationIgnored public var pendingSplitRestoreCommand: String?

    /// The agent conversation the main pane is running, reported by that agent's `SessionStart` hook over
    /// `session.agent`. Persisted via `SessionSnapshot.agentSession`; read on restore (with
    /// `resumeAgentSessions` on) so the pane comes back on the SAME conversation rather than a blank one.
    /// `@ObservationIgnored` — nothing renders it.
    ///
    /// Unlike `foregroundCommand` this is NOT consumed run-once: resuming keeps the agent's id, so the
    /// resumed agent's own hook simply reports the same ref again. It is only ever ACTED on when that pane
    /// also captured an agent as its foreground command, so a stale ref for a pane that has since moved on
    /// to something else is inert.
    @ObservationIgnored public var agentSession: AgentSessionRef?
    /// The split (right) pane's agent conversation, the split analogue of `agentSession`.
    @ObservationIgnored public var splitAgentSession: AgentSessionRef?

    /// Whether the session-wide overlay slot is OCCUPIED, by either of its two occupants: a caller's
    /// PROGRAM (`session.overlay.open`, an ephemeral terminal that covers the session and owns first
    /// responder) or a passive HUD message (`session.hud.open`, which covers nothing). RAW, so it answers
    /// only "occupied" — ask `programOverlayActive` or `hudActive` for WHICH, and never this, wherever the
    /// answer decides focus, coverage, or input. Observed, so the detail pane shows/hides the slot.
    /// Driven only by the control channel; NOT persisted (absent from `snapshot()`), so the slot never
    /// survives a relaunch.
    public var overlayActive: Bool = false

    /// The overlay's surface, created when the overlay opens and torn down when its program exits or
    /// the control channel closes it (unlike the split, which is kept alive when hidden). The shell
    /// runs `overlayCommand`; on its exit the surface's process-exit closes the overlay.
    @ObservationIgnored public var overlaySurface: (any TerminalSurface)?

    /// The command the overlay runs as its process (e.g. `revdiff`); read by the overlay surface
    /// factory at creation. `@ObservationIgnored`: read imperatively, not reactive.
    @ObservationIgnored public var overlayCommand: String?

    /// The overlay's working directory, or nil to inherit `effectiveCwd`. Read by the factory at
    /// creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayCwd: String?

    /// The overlay's own solid background color as `#rrggbb`, or nil for the default theme background.
    /// Independent of the session's `backgroundWatermark` — the overlay surface is not wired to the
    /// session, so it carries its own color, set via `session.overlay.open --background-color`. Read by
    /// the factory at creation; set at open, cleared on close. `@ObservationIgnored`, never persisted.
    @ObservationIgnored public var overlayBackgroundColor: String?

    /// Whether the overlay keeps its surface open after the command exits, showing libghostty's
    /// "press any key to close" prompt (useful to read a command's final output) instead of closing
    /// immediately. Read by the factory at creation. `@ObservationIgnored`.
    @ObservationIgnored public var overlayWait: Bool = false

    /// The overlay program's exit status, recorded on the surface's teardown from the wrapper's
    /// `echo $?` temp file (NOT libghostty's child-exited status, which reflects the login-shell
    /// wrapper and is always 0). Reset to nil when a new overlay opens; read by `session.overlay.result`.
    /// In-memory only (absent from `snapshot()`), so it never persists.
    @ObservationIgnored public var overlayExitCode: Int?

    /// For a *floating* overlay, the percent of the pane (both width and height) the panel occupies,
    /// 1...100; nil for the default full-pane overlay. A floating overlay renders as an opaque, framed
    /// panel centered in the pane with the session still VISIBLE behind it (the full overlay instead
    /// hides the session and draws translucent). Observed, so the detail pane picks the right layout.
    /// Set at open, cleared on close; never persisted.
    ///
    /// A HUD shares the field for its WIDTH only, bounded by `HudLayout.clampSizePercent` and placed by its
    /// own `HudSpec.position`; its height comes from `hudHeightPercent` instead.
    public var overlaySizePercent: Int?

    /// The percent of the pane's HEIGHT a HUD panel occupies, measured from its message rather than set by
    /// the caller (`HudLayout.heightPercent`); nil for an empty slot and for a program overlay, which takes
    /// `overlaySizePercent` on both axes. A HUD is two or three lines of text, so sharing one percent across
    /// both axes made every panel as tall as it was wide. Observed — the deck reads it to frame the panel.
    /// Cleared with the rest of the HUD state, never persisted.
    public var hudHeightPercent: Int?

    /// Bumped on every overlay-slot OPEN so the deck can key the panel's view identity on it. A HUD is
    /// REPLACED in place — `closeOverlay` then `openOverlay` inside one store call — so `overlayActive`
    /// never dips to false where SwiftUI can see it. Without a changing identity `makeNSView` is therefore
    /// never re-invoked and `updateNSView` runs against the torn-down view with `overlaySurface` nil.
    /// Observed (the deck reads it while building the panel), ephemeral, never persisted.
    public var overlaySlotGeneration: Int = 0

    /// The HUD occupying the overlay slot, nil when the slot is empty or runs a caller's program. Observed:
    /// the deck reads it to keep the session focusable and to place the panel. Ephemeral, never persisted —
    /// a HUD is a message about work in flight and means nothing after a relaunch.
    public var hudSpec: HudSpec?

    /// Path to the rendered-message file the HUD helper re-reads each tick (`ROOK_HUD_FILE`);
    /// `discardHudBody` deletes it. Per SESSION, so an update rewrites the path the running helper already
    /// opened. `@ObservationIgnored`: the surface factory, the HUD commands and `overlay close` read it, and
    /// none of them is a view that must re-render when it changes.
    @ObservationIgnored public var hudFile: String?

    /// Drops the HUD: deletes the body file and clears the state describing it. The single owner of that
    /// deletion, so it happens wherever a HUD is discarded — `closeOverlay` and every teardown that discards
    /// the whole session — and not only where a realized surface tears itself down. The file carries the
    /// panel's TEXT under a world-readable `/tmp` path, so a HUD closed before its surface existed must not
    /// leave it there. Deleting it also stops a helper still running against it.
    public func discardHudBody() {
        if let hudFile { try? FileManager.default.removeItem(atPath: hudFile) }
        hudSpec = nil
        hudFile = nil
        hudHeightPercent = nil
    }

    /// Whether the overlay slot holds a HUD rather than a caller's program. The one predicate separating the
    /// two occupants, so the deck's passivity exemptions and the program-overlay questions below cannot
    /// disagree about which is up.
    public var hudActive: Bool { overlayActive && hudSpec != nil }

    /// Whether the overlay slot runs a CALLER'S PROGRAM, either coverage variant. The deck's "a session-wide
    /// cover is up" question: a program overlay owns first responder and mutes the panes under it, a HUD does
    /// neither, so every passivity exemption reads this rather than the raw slot state.
    public var programOverlayActive: Bool { overlayActive && !hudActive }

    /// Whether a FULL-coverage PROGRAM overlay is up: `overlayActive` with no size percent. A full overlay
    /// hides the session content beneath it — the pane(s) AND a shown scratch — so its translucent background
    /// reveals the window backing, never a covered surface (under window translucency every surface
    /// renders a fully transparent background, so anything left visible below would bleed through).
    /// A floating (sized) overlay is not a cover: it draws an opaque panel over still-visible content.
    /// `!hudActive` keeps it a question about a running program even if a HUD ever reaches the slot without
    /// a size percent; a HUD covers nothing and must never hide the session behind it.
    public var fullOverlayActive: Bool { overlayActive && !hudActive && overlaySizePercent == nil }

    /// The left pane's overlay, covering that pane only and leaving the sibling live; nil means none is up,
    /// so the slot itself IS the "active" signal. Observed, ephemeral, control-channel only.
    public var leftOverlay: PaneOverlay?

    /// The left pane overlay's surface, created on open and torn down when its command exits or the slot is
    /// closed. `@ObservationIgnored` because `TerminalView` assigns it during view update.
    @ObservationIgnored public var leftOverlaySurface: (any TerminalSurface)?

    /// The left pane overlay program's exit status, kept OUTSIDE `PaneOverlay` so `session.overlay.result`
    /// can still read it after the slot goes nil. Reset on the next open; in-memory only.
    @ObservationIgnored public var leftOverlayExitCode: Int?

    /// The right pane's overlay, the split-pane analogue of `leftOverlay`.
    public var rightOverlay: PaneOverlay?

    /// The right pane overlay's surface (see `leftOverlaySurface`).
    @ObservationIgnored public var rightOverlaySurface: (any TerminalSurface)?

    /// The right pane overlay program's exit status (see `leftOverlayExitCode`).
    @ObservationIgnored public var rightOverlayExitCode: Int?

    /// Whether the scratch terminal is shown on top of this session (full single-pane size, hiding
    /// the single/split content underneath, like a full overlay). The scratch is a third per-session
    /// shell that — unlike the ephemeral overlay — behaves like the split: hiding it keeps the shell
    /// alive (`scratchSurface` retained), so a re-show reuses it. Observed, so the detail pane shows/
    /// hides the scratch. NOT persisted (absent from `snapshot()`), so it never survives a relaunch.
    public var scratchActive: Bool = false

    /// The scratch terminal's surface: a login shell (or `scratchCommand` when set), lazily created on
    /// first show and kept alive across hides (`scratchSurface != nil` is "alive but hidden"). Freed only
    /// on `closeScratch` (an explicit close, the shell's own `exit`, or session/workspace/window
    /// teardown) — after which the next show spawns a fresh shell. `@ObservationIgnored` like `surface`.
    @ObservationIgnored public var scratchSurface: (any TerminalSurface)?

    /// A command to run as the scratch's process instead of a login shell (set via `session.scratch
    /// --command`), the scratch analogue of `initialCommand`. RUN-ONCE: the scratch surface factory reads
    /// it once when it spawns and clears it, so after the command exits the next show is a plain shell.
    /// `@ObservationIgnored` + absent from `snapshot()`: transient like the scratch itself, never persisted.
    @ObservationIgnored public var scratchCommand: String?

    /// Whether the in-terminal search bar is shown over this session's focused pane (⌘F). Observed,
    /// so the detail pane shows/hides the bar. Written directly (from the surface factory's search
    /// callbacks + `AppActions`). NOT persisted (absent from `snapshot()`), so it never survives a relaunch.
    public var searchActive: Bool = false

    /// The current search query, mirrored from the bar's text field and the control channel. Observed
    /// + written directly like `searchActive`. Ephemeral, never persisted.
    public var searchNeedle: String = ""

    /// The number of matches for `searchNeedle`, from libghostty's `SEARCH_TOTAL` action; nil before a
    /// query runs. Observed + written directly. Ephemeral, never persisted.
    public var searchTotal: Int?

    /// The 1-based index of the currently selected match, from libghostty's `SEARCH_SELECTED` action;
    /// nil when none is selected. Observed + written directly. Ephemeral, never persisted.
    public var searchSelected: Int?

    /// The surface that owns the open search bar — the focused searchable pane at the time search opened.
    /// Pinned here so the bar's needle/navigate/close drive the SAME surface that opened search even if
    /// split focus moves afterwards (otherwise re-resolving `activeSurface` would strand the original pane
    /// in libghostty search mode). Set on open by the surface factory's START callback, cleared on close.
    /// `@ObservationIgnored` + weak (the session strongly owns its panes); ephemeral, never persisted.
    @ObservationIgnored public weak var searchSurface: (any TerminalSurface)?

    public init(id: UUID = UUID(), initialCwd: String, customName: String? = nil) {
        self.id = id
        self.initialCwd = initialCwd
        self.customName = customName
    }

    /// The sidebar label: a non-blank `customName` (a manual rename) wins; otherwise a non-blank
    /// terminal title of the focused pane (`focusedOscTitle` — the split pane's while it's focused in
    /// a split, else the primary's); otherwise the basename of the focused pane's cwd (`focusedCwd`,
    /// falling back to `initialCwd`).
    ///
    /// `customName` and the title are both trimmed before use, so a whitespace-only value falls
    /// through to the next source — matching `AppStore.renameSession`, which clears a blank name to
    /// nil. (A whitespace-only `customName` can only reach here via a hand-edited snapshot;
    /// `renameSession` never stores one.)
    ///
    /// Basename pins: root `/` → `/` (`lastPathComponent` already returns this);
    /// a trailing slash is ignored (`/a/b/` → `b`); an empty path → `~` (no
    /// sensible component exists, so we show the home shorthand).
    public var displayName: String {
        if let trimmed = customName?.trimmedOrNil { return trimmed }
        if let title = focusedOscTitle?.trimmedOrNil { return title }
        let path = focusedCwd
        if path.isEmpty { return "~" }
        return (path as NSString).lastPathComponent
    }

    /// The cwd of the pane currently in focus: the split (right) pane's while it has focus (whether
    /// the split is shown side-by-side OR hidden and maximized), otherwise the primary's; falls back
    /// to the primary cwd then `initialCwd`. The sidebar and title bar use this so they track whichever
    /// pane has focus, while `effectiveCwd` (below) stays the primary's for seeding new panes and the
    /// `ROOK_SESSION_PWD` token. Guarded on `splitFocused && splitSurface != nil` — the same idiom as
    /// `activeSurface`: the split fields describe the split pane only while it exists, so a promoted
    /// survivor that momentarily re-raised `splitFocused` after moving into the main slot can't mask the
    /// migrated main-pane cwd/title.
    public var focusedCwd: String {
        if splitFocused, splitSurface != nil, let cwd = splitCwd { return cwd }
        return currentCwd ?? initialCwd
    }

    /// The terminal title of the focused pane: the split pane's while it has focus AND exists, else the
    /// primary's (see `focusedCwd` for why the split-existence guard).
    private var focusedOscTitle: String? { splitFocused && splitSurface != nil ? splitTitle : oscTitle }

    /// The detail shown after the workspace name on the second line of the session palette, the Ctrl-Tab
    /// switcher, and the title bar: the focused pane's terminal title when it isn't already the
    /// `displayName` (so it ADDS context rather than repeating line 1), otherwise the focused cwd.
    ///
    /// A remote (SSH) host sets the OSC title to its own `user@host:dir` while the local OSC 7 cwd report
    /// stops once the shell hops out, so `currentCwd` freezes at the stale local path. Preferring the
    /// title surfaces the remote location instead of that misleading local path. For an UNNAMED session
    /// the title is already line 1 (`displayName` prefers it over the cwd), so this falls through to the
    /// cwd — no duplication. For a plain local session the title is nil (local auto-title is suppressed),
    /// so this is just the cwd, unchanged.
    public var subtitleDetail: String {
        if let title = focusedOscTitle?.trimmedOrNil, title != displayName { return title }
        return focusedCwd
    }

    /// The session's effective working directory: the live `currentCwd` once a PWD report has
    /// arrived, otherwise `initialCwd`. Always the PRIMARY pane's (NOT focus-aware) — it seeds a new
    /// split/overlay/quick-terminal and backs the `ROOK_SESSION_PWD` token, which should be stable
    /// regardless of which pane is focused. The focus-aware variant is `focusedCwd`.
    public var effectiveCwd: String { currentCwd ?? initialCwd }

    /// The surface of the pane currently in focus: the split (right) pane while it has focus and
    /// exists, otherwise the primary. When the split is hidden the detail pane shows this one
    /// maximized, and the focus helpers target it, so focus/typing always reaches the visible pane.
    public var activeSurface: (any TerminalSurface)? {
        splitFocused && splitSurface != nil ? splitSurface : surface
    }

    /// The session's one addressable pane for the control arms that act on "the session" rather than on a
    /// named `--pane`: `session.copy`, `session.paste`, `session.selectall`, and `font.*`. Normally the main
    /// pane, and IDENTICAL to `surface` for every ordinary or split session — including a promoted split
    /// survivor, which `closePrimaryPane` moves INTO the main slot (`surface`) and whose `splitSurface` it
    /// nils. The `?? splitSurface` term is a defensive fallback only: it keeps the arms answering (instead
    /// of `session not realized`) should `surface` ever be nil while a split shell is still alive.
    /// Deliberately NOT focus-aware (unlike `activeSurface`): a shown split keeps
    /// addressing the main pane, which is what keeps `session.selectall` and its `session.copy` read-back
    /// pointed at the same surface.
    public var addressableSurface: (any TerminalSurface)? { surface ?? splitSurface }

    /// The pane's overlay, nil when that pane has none.
    public func paneOverlay(_ pane: OverlayPane) -> PaneOverlay? { self[keyPath: pane.overlaySlot] }

    /// The pane overlay's surface, nil before the factory realizes it or after teardown.
    public func paneOverlaySurface(_ pane: OverlayPane) -> (any TerminalSurface)? {
        self[keyPath: pane.surfaceSlot]
    }

    /// The pane overlay program's exit status, surviving the overlay's close so
    /// `session.overlay.result --pane` can report it; nil until one exits or after the next open on that pane.
    public func paneOverlayExitCode(_ pane: OverlayPane) -> Int? { self[keyPath: pane.exitCodeSlot] }

    /// The panes with an overlay up, ordered left then right — the `paneOverlays` tree read-back source.
    public var openPaneOverlays: [OverlayPane] {
        OverlayPane.allCases.filter { paneOverlay($0) != nil }
    }

    /// Which pane owns keyboard focus RIGHT NOW — the single predicate every pane-scoped cover, zoom and
    /// focus decision derives from, so none of them can disagree about which pane the user is looking at.
    /// `.right` needs `splitFocused` AND a right pane that exists: shown side-by-side (`isSplit`, whose
    /// surface may still be unrealized) or hidden-maximized with a live `splitSurface`. Without the second
    /// term a promoted survivor that momentarily re-raised `splitFocused` would resolve `.right` (the
    /// `activeSurface` idiom); without `isSplit` a freshly shown split whose lazy surface has not realized
    /// yet would resolve `.left` while the user's caret sits in the right pane.
    public var focusedPane: OverlayPane {
        splitFocused && (isSplit || splitSurface != nil) ? .right : .left
    }

    /// The focused pane's overlay pane, nil when that pane's slot is empty.
    public var focusedOverlayPane: OverlayPane? {
        let pane = focusedPane
        return paneOverlay(pane) == nil ? nil : pane
    }

    /// Whether the detail pane LAYS THIS PANE OUT at all — the precondition for realizing a surface in it,
    /// since surfaces defer creation until they get a nonzero backing size. Not `deckHostsSurface`, which
    /// also yields a placeholder while zoom or the dashboard owns the slot.
    public func rendersPane(_ pane: OverlayPane) -> Bool {
        isSplit || pane == focusedPane
    }

    /// The panes the detail pane lays out RIGHT NOW, ordered left then right. Derived from the observed
    /// `isSplit`/`splitFocused`, so the deck can watch it for the moment a pane stops being laid out.
    public var renderedPanes: [OverlayPane] {
        OverlayPane.allCases.filter(rendersPane)
    }

    /// Whether ANY host is claiming this pane's overlay slot: the deck lays the pane out, or terminal zoom
    /// targets that overlay surface. The deck is not the only host — while zoom owns a slot `deckHostsSurface`
    /// deliberately returns false for it and the zoom layer mounts the surface instead — and the zoom target
    /// is a claim from the moment it is set, before SwiftUI mounts that layer. `overlay-left`/`overlay-right`
    /// are advertised zoomable as soon as the slot exists (`TerminalZoomSurface.isAvailable`), so a selected
    /// zoom target with a pending host must count.
    public func paneOverlayHosted(_ pane: OverlayPane) -> Bool {
        rendersPane(pane) || TerminalZoomRegistry.shared.targets(sessionID: id, surface: pane.zoomSurface)
    }

    /// Drops a pane overlay that can never come to life: NO host claims its slot AND its terminal was never
    /// realized, so no program was ever started and nothing would ever close the slot —
    /// `session.overlay.result --pane` would answer "overlay still running" forever and `--block` would hang
    /// on it. `openPaneOverlay` only proves the pane renders at REQUEST time; the surface is realized later
    /// by whichever host mounts it, and the pane can stop rendering in between. A REALIZED overlay is left
    /// alone: unmounting its surface keeps the program running and a re-show remounts it. Called wherever
    /// `renderedPanes` or the zoom target can change, so the bad state is torn down instead of described.
    ///
    /// The test is `TerminalSurface.isRealized`, NOT an occupied surface slot: the deck parks the view in the
    /// slot before its terminal is created, and creation defers until the view is sized, so a slot filled in
    /// that gap holds a view with no libghostty surface and no process. `teardownPaneOverlay` frees that
    /// stillborn view too, since a later open on the pane would otherwise reuse it — it is baked with the
    /// RETIRED overlay's command, cwd, and colors.
    public func dropUnrealizedPaneOverlays() {
        for pane in OverlayPane.allCases
        where paneOverlay(pane) != nil && paneOverlaySurface(pane)?.isRealized != true && !paneOverlayHosted(pane) {
            teardownPaneOverlay(pane)
        }
    }

    /// The pane whose overlay slot CURRENTLY holds `surface`, nil when neither does. Derived LIVE from slot
    /// occupancy, like `paneRole(forToken:)`: `promotePaneOverlay` moves the right pane's overlay surface
    /// into the LEFT slot without rebuilding it, so its own exit/status/focus callbacks must ask which slot
    /// they now sit in rather than trust the pane captured when the factory built them — a captured `.right`
    /// would close nothing, record the status on a dead slot, and leave the promoted pane covered forever.
    public func paneOverlayRole(of surface: any TerminalSurface) -> OverlayPane? {
        OverlayPane.allCases.first { paneOverlaySurface($0) === surface }
    }

    /// Frees the pane's overlay outright: tears the surface down and clears the slot, the surface, AND the
    /// exit code. Used where the PANE ITSELF goes away, unlike `AppStore.closePaneOverlay`, which keeps the
    /// exit code readable by `session.overlay.result`; here no pane survives to be asked. `teardown()` nils
    /// the surface's store-capturing callbacks, breaking the store/session/surface/closure cycle.
    public func teardownPaneOverlay(_ pane: OverlayPane) {
        paneOverlaySurface(pane)?.teardown()
        setPaneOverlay(nil, pane: pane)
        setPaneOverlaySurface(nil, pane: pane)
        setPaneOverlayExitCode(nil, pane: pane)
    }

    /// The pane-slot writers, paired with the `paneOverlay*` readers through `OverlayPane`'s key paths.
    public func setPaneOverlay(_ overlay: PaneOverlay?, pane: OverlayPane) {
        self[keyPath: pane.overlaySlot] = overlay
    }

    public func setPaneOverlaySurface(_ surface: (any TerminalSurface)?, pane: OverlayPane) {
        self[keyPath: pane.surfaceSlot] = surface
    }

    public func setPaneOverlayExitCode(_ code: Int?, pane: OverlayPane) {
        self[keyPath: pane.exitCodeSlot] = code
    }

    /// Frees BOTH pane overlays; the whole-session form of `teardownPaneOverlay(_:)`, called wherever the
    /// session is discarded alongside the `overlaySurface?.teardown()` for the session-wide overlay.
    public func teardownPaneOverlays() {
        OverlayPane.allCases.forEach { teardownPaneOverlay($0) }
    }

    /// Moves the right pane's overlay — slot, surface, and exit code together — into the left slot, following
    /// the split survivor `closePrimaryPane` promotes into the primary pane, so the overlay keeps covering the
    /// same shell. The left slot must already be freed. The surface MOVES rather than being rebuilt, so its
    /// callbacks re-resolve their pane through `paneOverlayRole(of:)` instead of a captured one.
    public func promotePaneOverlay() {
        setPaneOverlay(rightOverlay, pane: .left)
        setPaneOverlaySurface(rightOverlaySurface, pane: .left)
        setPaneOverlayExitCode(rightOverlayExitCode, pane: .left)
        setPaneOverlay(nil, pane: .right)
        setPaneOverlaySurface(nil, pane: .right)
        setPaneOverlayExitCode(nil, pane: .right)
    }

    /// Resolves a surface's stable spawn token (`TerminalSurface.paneToken`, baked as `ROOK_PANE_ID` and
    /// forwarded by the agent-status hook as `session.status --pane-id`) to the pane role of the slot it
    /// CURRENTLY occupies — `.left` for the main slot, `.right` for the split, `.scratch` for the scratch.
    /// Because the role is derived LIVE from slot occupancy, a promoted split survivor (moved into `surface`
    /// by `closePrimaryPane`) resolves `.left` and a fresh re-split helper (in `splitSurface`) resolves
    /// `.right`, even though BOTH shells were baked with the same stale `right` role. Returns nil for an
    /// empty or unknown token (a torn-down surface, or a shell spawned before the token existed), so the
    /// caller falls back to the baked `--pane` value. This mirrors the live-role read the pane-scoped
    /// keystroke-clear already does via `GhosttySurfaceView.isSplitPane` (see the Notifications rule).
    public func paneRole(forToken token: String) -> StatusPane? {
        guard !token.isEmpty else { return nil }
        if surface?.paneToken == token { return .left }
        if splitSurface?.paneToken == token { return .right }
        if scratchSurface?.paneToken == token { return .scratch }
        return nil
    }

    /// Copies the PERSISTED restore-command overrides into the transient pending slots, arming them for
    /// THIS launch. The single gate on a pin ever executing: only `AppStore.restore(from:launchRestore: true)`
    /// — an app-bootstrap load — calls it, so a mid-process window reload, Reopen Closed Item, or a write
    /// that lands over the socket during this run arms nothing. The split's payload is armed only when the
    /// split was SHOWN, since a hidden split builds no right surface at bootstrap and the payload would
    /// otherwise fire on a later manual ⌘D.
    public func armPendingRestoreOverrides() {
        pendingRestoreCommand = restoreCommand
        // a split that was hidden at the last quit builds no right surface, so its pin names a pane that no
        // longer exists: DROP it rather than leave it waiting to fire on some later manual split — the same
        // rule `closeSplit` applies when the pane goes away.
        if !isSplit { splitRestoreCommand = nil }
        pendingSplitRestoreCommand = splitRestoreCommand
    }

    /// Takes the pane's PENDING restore-command override, clearing it so a second surface for the same pane
    /// this launch gets a plain shell — the split factory runs again when a split shell exits and the user
    /// opens a fresh ⌘D split, and a payload left in place would fire a second time mid-session. The
    /// PERSISTED `restoreCommand`/`splitRestoreCommand` are neither read nor written here: the override is
    /// sticky and must fire again after the next restart. `.scratch` always returns nil — the scratch
    /// terminal is never restored.
    public func takePendingRestoreOverride(pane: StatusPane) -> String? {
        switch pane {
        case .left:
            defer { pendingRestoreCommand = nil }
            return pendingRestoreCommand
        case .right:
            defer { pendingSplitRestoreCommand = nil }
            return pendingSplitRestoreCommand
        case .scratch:
            return nil
        }
    }

    /// Drops both unconsumed override payloads, leaving the persisted fields alone. Called where a live
    /// `Session` object leaves the tree but may come back as the SAME object (the soft-close grace window):
    /// a payload armed at bootstrap and never consumed would otherwise survive the round trip and fire when
    /// the reinserted session's surface is finally built.
    public func clearPendingRestoreOverrides() {
        pendingRestoreCommand = nil
        pendingSplitRestoreCommand = nil
    }

    /// The surface currently on top and owning keyboard focus: an active overlay (full OR floating), else
    /// the scratch, else the focused pane's OWN overlay, else the active pane. The overlay renders above the
    /// scratch, and a full overlay or the scratch hides the pane(s) beneath it (INCLUDING their pane
    /// overlays) — so the session-focus helpers route through this to keep first responder on the top
    /// surface and never on a covered pane/scratch. (`TerminalView.focusIfNeeded` is the exception: it
    /// targets its own deck slot, which a cover already gates off via `isActive`.) nil while a pane
    /// overlay's slot is open but its surface has not realized yet; the bounded focus retries re-resolve a
    /// beat later.
    ///
    /// A HUD in the slot is SKIPPED, which is what keeps it passive: every app focus-routing site reads this
    /// (sidebar click, session selection, overlay-close refocus), and handing any of them the HUD helper
    /// would take first responder off the session the message is about — the deck's exemptions one layer down.
    public var topmostSurface: (any TerminalSurface)? {
        if programOverlayActive { return overlaySurface }
        if scratchActive { return scratchSurface }
        if let pane = focusedOverlayPane { return paneOverlaySurface(pane) }
        return activeSurface
    }

    /// Where pane-focus moves first responder when asked for `wantSplit`: under a session-wide cover the
    /// requested pane is hidden, so stay on `topmostSurface`; else the pane's OWN overlay when one covers it,
    /// so `session.focus right` cannot make a covered pane first responder; else the pane itself. Returns nil
    /// for a covering pane overlay whose surface has not realized yet, leaving the retry to re-resolve.
    /// A HUD is no cover, so the requested pane stays reachable while one is up.
    public func focusTarget(wantSplit: Bool) -> (any TerminalSurface)? {
        if programOverlayActive || scratchActive { return topmostSurface }
        let pane: OverlayPane = wantSplit ? .right : .left
        if paneOverlay(pane) != nil { return paneOverlaySurface(pane) }
        return wantSplit ? splitSurface : surface
    }

    /// The pane-or-scratch surface that is actually ON SCREEN: the scratch terminal when it covers the
    /// panes (and no overlay is up), else the focused pane. The control arms that act on "what's visible"
    /// — `session.text` with no `--pane` and `session.search` — resolve through this so they hit the
    /// scratch rather than a pane hidden beneath it (an active overlay routes to its own surface via
    /// `topmostSurface`; this stays the pane-vs-scratch choice those arms share, matching `searchTarget`).
    /// A HUD leaves the scratch on screen underneath it, so it is not one of those covers.
    public var onScreenSurface: (any TerminalSurface)? {
        scratchActive && !programOverlayActive ? topmostSurface : activeSurface
    }

    /// The match counter shown in the search bar and returned by `session.search`: empty before a
    /// query runs (`searchTotal` nil), `"no matches"` at zero, `"N matches"` while none is selected,
    /// and `"S of N"` once a match is selected. `selected` is clamped to `total` so a stale selected
    /// index (the count shrank under it before the next SEARCH_SELECTED lands) never reads "3 of 2".
    public var searchDisplayText: String {
        guard let total = searchTotal else { return "" }
        guard total > 0 else { return "no matches" }
        guard let selected = searchSelected else { return "\(total) matches" }
        return "\(min(selected, total)) of \(total)"
    }

    /// Resets all search state to its defaults: hides the bar, clears the needle/count/index, and nils
    /// the pinned owner. Called from the pane-teardown/promote paths (`closeSplit`, `closePrimaryPane`,
    /// `closeSplitPane`) so a session whose searched pane was destroyed or promoted doesn't keep a stuck,
    /// no-op bar (the weak `searchSurface` zeroes but `searchActive` would otherwise stay true).
    public func clearSearch() {
        searchActive = false
        searchNeedle = ""
        searchTotal = nil
        searchSelected = nil
        searchSurface = nil
    }
}

extension String {
    /// The string trimmed of leading/trailing whitespace and newlines, or nil if
    /// the result is empty. The single normalizer for the rename/displayName
    /// "blank after trim" rule.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
