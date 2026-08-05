import Foundation

/// The window's custom titlebar row state: `normal` stacks the session name over the cwd subtitle,
/// `compact` is a single short row, `hidden` drops the row and the traffic lights for a full-bleed
/// terminal. Stored raw so an unknown future value decodes tolerantly (via `effectiveToolbarMode`)
/// rather than failing the whole decode.
///
/// Top-level (unlike the nested sibling mode enums) because the app target references it as a bare `ToolbarMode`.
public enum ToolbarMode: String, Codable, Sendable, CaseIterable {
    case normal
    case compact
    case hidden
}

/// How a delivered notification bounces the Dock icon (macOS `requestUserAttention`): `off` (no bounce),
/// `once` (a single `.informationalRequest`), or `untilFocused` (a `.criticalRequest` that bounces until
/// rook becomes active). Stored raw on `AppSettings` so an unknown future value decodes tolerantly (via
/// `effectiveDockBounce`). The default `off` case is named `off` (not `none`) to avoid the `Optional.none`
/// collision at the `effectiveDockBounce` call site, matching the `AutoFollowAttention.off` precedent.
public enum DockBounce: String, Codable, Sendable, CaseIterable {
    case off
    case once
    case untilFocused
}

/// User-facing appearance settings, persisted independently of the workspace tree.
///
/// Every field is optional: nil means "use the ghostty default", and a settings file written
/// before a field existed still decodes — that optionality IS the forward-compat mechanism, so
/// there is no version field (a version bump would only add a discard-on-mismatch path that wipes
/// the user's settings).
public struct AppSettings: Codable, Equatable, Sendable {
    /// Where a new (⌘T) session opens. Stored as the `newSessionDirectory` raw string so an unknown
    /// future value decodes tolerantly to `home` (the AppSettings forward-compat rule) instead of
    /// failing the whole decode. `home` is also the nil case (the default), so picking it clears the
    /// field and keeps `settings.json` minimal.
    public enum NewSessionDirectory: String, CaseIterable, Sendable {
        case home
        case currentSession
        case custom
    }

    /// The user-idle timeout after which the window's selection auto-follows to the oldest blocked
    /// session, stored as the `autoFollowAttention` raw string so an unknown future value decodes
    /// tolerantly to `off` (the AppSettings forward-compat rule) instead of failing the whole decode.
    /// `off` is also the nil case (the default), so picking it clears the field and keeps
    /// `settings.json` minimal. Each case's `timeout` is the idle grace in seconds (`off` = nil = the
    /// feature is disabled).
    public enum AutoFollowAttention: String, CaseIterable, Sendable {
        case off
        case s5
        case s10
        case s30
        case s60
        case m5

        /// Tolerant lookup shared by the Settings binding and the store fan-out: an unknown or nil raw
        /// value resolves to `off` (the AppSettings forward-compat default) instead of failing, so a
        /// future-written value never breaks the read.
        public init(tolerant raw: String?) {
            self = AutoFollowAttention(rawValue: raw ?? "") ?? .off
        }

        /// The idle grace in seconds before the auto-follow fires, or nil when `off` (disabled).
        public var timeout: TimeInterval? {
            switch self {
            case .off: return nil
            case .s5: return 5
            case .s10: return 10
            case .s30: return 30
            case .s60: return 60
            case .m5: return 300
            }
        }
    }

    /// The app's out-of-the-box theme — a bundled theme applied on a fresh install (no saved
    /// settings), seeded by `SettingsStore.load()`. Distinct from `theme == nil`, which means
    /// ghostty's built-in default (the "default ghostty" entry in the theme picker).
    public static let defaultTheme = "rook"

    /// The out-of-the-box inactive-split-pane mute strength on the 0...10 scale (0 = no mute, 10 =
    /// extreme), used when `inactivePaneMuteStrength` is nil. 5 maps to the historical 0.4 opacity.
    public static let defaultInactivePaneMuteStrength = 5

    /// The out-of-the-box sidebar background shift on the 0...10 scale, used when
    /// `sidebarBackgroundShift` is nil. 5 is the neutral center (sidebar matches the terminal
    /// background); below 5 lightens it, above 5 darkens it.
    public static let defaultSidebarBackgroundShift = 5

    /// The out-of-the-box sidebar row-text point size, used when `sidebarFontSize` is nil. Matches the
    /// macOS `.body` text style (13pt) the sidebar rows used before the size became configurable, so a
    /// fresh install renders exactly as it always did.
    public static let defaultSidebarFontSize: Double = 13

    /// The allowed sidebar row-text point-size range (the Settings stepper bounds). Kept modest so the
    /// fixed-size row icons and status glyphs stay visually balanced against the text at either end.
    public static let sidebarFontSizeRange: ClosedRange<Double> = 9 ... 20

    /// The out-of-the-box palette/switcher text point size, used when `interfaceFontSize` is nil. Matches
    /// the macOS `.body` style (13pt) those surfaces hardcoded before the size became configurable, so a
    /// fresh install renders exactly as it always did.
    public static let defaultInterfaceFontSize: Double = 13

    /// The allowed palette/switcher point-size range (the Settings stepper bounds). Same span as the
    /// sidebar's, for the same reason: the fixed-size status glyphs stay balanced against the text.
    public static let interfaceFontSizeRange: ClosedRange<Double> = 9 ... 20

    /// Terminal font family name (e.g. `SF Mono`), or nil for the ghostty default.
    public var fontFamily: String?
    /// Default terminal font size in points, or nil for the ghostty default.
    public var fontSize: Double?
    /// The ghostty `theme` value: a plain bundled name (e.g. `Adwaita Dark`), or nil for the ghostty
    /// default. When `followSystemAppearance` is on this is the LIGHT-appearance slot; otherwise it is
    /// the single theme, applied in both appearances.
    public var theme: String?
    /// The DARK-appearance theme, used only when `followSystemAppearance` is on. nil = unset. Together
    /// with `theme` it is emitted as ghostty's dual `theme = light:NAME,dark:NAME` conditional, which
    /// libghostty resolves at runtime on a color-scheme change (rook no longer picks the side).
    public var darkTheme: String?
    /// Whether the terminal follows the macOS Light/Dark appearance. nil/false = off (the default): a
    /// single `theme` is emitted. On: `theme`/`darkTheme` are emitted as the raw dual conditional.
    public var followSystemAppearance: Bool?
    /// Window background opacity in 0...1 (1 = fully opaque), or nil for opaque. Composited at the
    /// AppKit window level, NOT by the ghostty renderer: when < 1, `ghosttyConfigLines()` pins the
    /// renderer fully transparent so the window's tinted background is the single translucent layer
    /// (otherwise the surface and the window would stack two tints).
    public var backgroundOpacity: Double?
    /// Background blur radius (private CGS window blur, 0...100), or nil for no blur. Only has a
    /// visible effect when `backgroundOpacity` < 1. Applied in the app target, NOT a ghostty key.
    public var backgroundBlur: Int?
    /// Whether to post macOS notification banners for terminal desktop notifications. nil means the
    /// default (on). Only gates the OS banner — the sidebar unseen-count badge tracks notifications
    /// either way.
    public var notificationsEnabled: Bool?
    /// Whether the sidebar shows the red unseen-notification count badge (the count pill on session
    /// rows and the collapsed-workspace roll-up). nil means the default (on). Render-only: the
    /// unseen count keeps tracking, so turning it back on instantly shows the current counts.
    /// Distinct from `notificationsEnabled`, which gates the OS banner.
    public var notificationBadgeEnabled: Bool?
    /// The custom titlebar row state, stored as a `ToolbarMode` RAW STRING (`normal`/`compact`/`hidden`) so an
    /// unknown future value decodes tolerantly to the default (the AppSettings forward-compat rule) instead
    /// of failing the whole decode and discarding every other setting; nil means the default (compact).
    /// Resolved through `effectiveToolbarMode`, which also maps a legacy `compactToolbar`. Applied at the
    /// AppKit window level, NOT a ghostty key. Writing a mode nils `compactToolbar`, so the legacy key evaporates.
    public var toolbarMode: String?
    /// Legacy decode shim for the pre-`toolbarMode` two-state toggle: false = the normal bar, true/nil = the
    /// compact bar. Read only by `effectiveToolbarMode` when `toolbarMode` is unset; nilled on the next
    /// mode write. Applied at the AppKit window level, NOT a ghostty key.
    public var compactToolbar: Bool?
    /// Hex colors (`#RRGGBB`) for the agent-status glyph's three states; nil for each means the system
    /// default (active = blue, blocked = amber, completed = green). Applied at the AppKit level when the
    /// glyph is drawn, NOT ghostty keys, so they never appear in `ghosttyConfigLines()`.
    public var activeStatusColorHex: String?
    public var blockedStatusColorHex: String?
    public var completedStatusColorHex: String?
    /// `StatusShape` RAW VALUES (`circle`/`square`/…) for the agent-status glyph's three states — the
    /// SILHOUETTE axis beside the colors above; nil for each means that status keeps its own SEMANTIC
    /// default glyph (`AgentStatus.symbolName`), which is a real choice here and not just "unset": rook's
    /// defaults say what happened (working / waiting on you / finished), so the picker offers them as an
    /// explicit entry. Stored raw (like `toolbarMode`/`dockBounce`, and mirroring how the colors store hex
    /// strings) so an unknown or hand-edited value decodes tolerantly via `effectiveStatusShape(for:)`
    /// instead of failing the whole decode. The per-call `session.status --shape` override still wins over
    /// these. Applied at the AppKit level when the glyph is drawn, NOT ghostty keys, so they never appear in
    /// `ghosttyConfigLines()`.
    public var activeStatusShape: String?
    public var blockedStatusShape: String?
    public var completedStatusShape: String?
    /// Directory holding the user-editable keymap config (`keymap.conf`), or nil for the default
    /// (`~/.config/rook`). Resolved by `ConfigPaths.configDirectory(setting:stateDir:home:)`; an
    /// app-level path, never a ghostty key.
    public var configDirectory: String?
    /// Mouse scroll speed multiplier (ghostty `mouse-scroll-multiplier`), applied as a bare value to
    /// both the notched wheel and the trackpad. nil means rook's default of 3. UNLIKE the other
    /// fields, this key is ALWAYS emitted (nil emits `= 3`), so the default is effective rather than
    /// deferring to ghostty's per-device defaults (discrete 3 / precision 1) — a fresh install scrolls
    /// at 3, which speeds the trackpad up out of the box. Consequence: it overrides any
    /// `mouse-scroll-multiplier` set in the user's own `~/.config/ghostty/config`.
    public var mouseScrollMultiplier: Double?
    /// How strongly the inactive split pane's text is muted, on a 0...10 scale (0 = no mute, 10 =
    /// extreme); nil means the default (`defaultInactivePaneMuteStrength`). Applied as a SwiftUI
    /// overlay opacity in the app target (see `muteOpacity(strength:)`), NOT a ghostty key — it never
    /// appears in `ghosttyConfigLines()`.
    public var inactivePaneMuteStrength: Int?
    /// How much darker or lighter the sidebar background is than the terminal background, on a 0...10
    /// scale where 5 is neutral (identical to the terminal); below 5 lightens, above 5 darkens. nil
    /// means the default (`defaultSidebarBackgroundShift`, neutral). Applied in the app target as a
    /// SwiftUI wash behind the sidebar (see `sidebarShiftAmount`), NOT a ghostty key — it never appears
    /// in `ghosttyConfigLines()`.
    public var sidebarBackgroundShift: Int?
    /// Whether, on app restart, each pane re-runs the command it was running at the last clean quit: a
    /// captured foreground command (`SessionSnapshot.foregroundCommand`) and a `session.new --command`
    /// session's persisted `initialCommand`. nil means the default (off). An app-level behavior flag, NOT a
    /// ghostty key — it never appears in `ghosttyConfigLines()`.
    public var restoreRunningCommand: Bool?
    /// Whether a restored pane whose captured foreground command is a coding agent (`claude`/`codex`)
    /// RESUMES the conversation it was on (`claude --resume <id>`, from the id the agent's own hook
    /// reported over `session.agent`) instead of re-running the bare agent, which would open a blank one.
    /// nil means the default (off). Rides on `restoreRunningCommand`: with the re-run itself off there is
    /// nothing to type into the pane. An app-level behavior flag, NOT a ghostty key — it never appears in
    /// `ghosttyConfigLines()`.
    public var resumeAgentSessions: Bool?
    /// Whether rook also loads the user's GLOBAL ghostty config (`~/.config/ghostty/config`) on top of
    /// its bundled defaults. nil means the default (off): rook is self-contained, so a config written
    /// for the standalone Ghostty.app does NOT silently change rook. Opt in to share one config across
    /// both. The rook-scoped `~/.config/rook/ghostty.conf` is ALWAYS loaded regardless and is the
    /// place for rook overrides/customizations. An app-level flag read at config-load time (NOT a
    /// ghostty key, so it never appears in `ghosttyConfigLines()`), gating which files `loadConfig` reads.
    public var inheritGlobalGhosttyConfig: Bool?
    /// Whether the window title bar shows the attention bell icon (window-wide non-idle session status at
    /// a glance). nil means the default (off). An app-level chrome flag, NOT a ghostty key — it never
    /// appears in `ghosttyConfigLines()`; it only gates whether the titlebar builds the icon.
    public var attentionButtonEnabled: Bool?
    /// How a delivered notification bounces the Dock icon (`off`/`once`/`untilFocused`), stored as a
    /// `DockBounce` RAW STRING so an unknown future value decodes tolerantly to the default via
    /// `effectiveDockBounce` (the AppSettings forward-compat rule). nil means the default (`off`). An
    /// app-level attention setting, NOT a ghostty key — it never appears in `ghosttyConfigLines()`;
    /// `NotificationManager` reads its mirror and issues the matching `requestUserAttention`, a no-op while
    /// rook is the frontmost app.
    public var dockBounce: String?
    /// Name of the system sound attached to a delivered desktop notification (e.g. `Glass`), or
    /// nil/empty for no sound (the default). Delivered as `UNNotificationSound(named:)` on the banner's
    /// content (the `.aiff` suffix is added when the name has none), so it RIDES the banner: gated by
    /// `notificationsEnabled` and the macOS notification authorization, and silenced by Do Not Disturb —
    /// unlike the badge and the Dock bounce, which fire whether or not banners show (only the Settings
    /// picker's preview uses `NSSound`). An app-level value, NOT a ghostty key — it never appears in
    /// `ghosttyConfigLines()`.
    public var notificationSoundName: String?
    /// Name of the system sound played when a session enters the `blocked` status (e.g. `Glass`, resolved by
    /// `NSSound(named:)`), or nil/empty for no sound (the default). A per-call `session.status --sound`
    /// overrides this. An app-level value played at the AppKit level, NOT a ghostty key — it never appears
    /// in `ghosttyConfigLines()`.
    public var blockedStatusSoundName: String?
    /// Whether a right-click pastes the clipboard (ghostty `right-click-action`). nil means the default
    /// (on): rook forwards right-/middle-click to libghostty, so a right-click pastes out of the box.
    /// UNLIKE most flags this IS a ghostty key — `ghosttyConfigLines()` emits `right-click-action = paste`
    /// when on and `= ignore` when off, so the UI owns the key (the settings conf loads last and wins over
    /// a `right-click-action` in the user's own `ghostty.conf`). rook has no terminal context menu, so
    /// paste-or-off is the whole meaningful choice.
    public var rightClickPaste: Bool?
    /// Whether clicking anywhere on a sidebar workspace ROW expands or collapses it; nil means the default
    /// (on). The disclosure triangle toggles regardless — AppKit drives it natively — so turning this off
    /// narrows the hit target to the triangle rather than removing the affordance. A sidebar behavior flag
    /// read per click through `GhosttyApp`, NOT a ghostty key — it never appears in `ghosttyConfigLines()`.
    public var workspaceRowClickExpands: Bool?
    /// Which directory a new (⌘T) session opens in, as a `NewSessionDirectory` raw value; nil means the
    /// default (`home`). `currentSession` inherits the active session's focused-pane cwd, `custom` uses
    /// `newSessionCustomDirectory`. An app-level behavior value read by `AppActions.newSession()`, NOT a
    /// ghostty key — it never appears in `ghosttyConfigLines()`. Resolved by `resolveNewSessionCwd(...)`.
    public var newSessionDirectory: String?
    /// The fixed directory a new session opens in when `newSessionDirectory` is `custom`; nil/empty falls
    /// back to home. Ignored for the `home`/`currentSession` modes. Set by the Settings directory picker.
    public var newSessionCustomDirectory: String?
    /// Whether closing a session from the GUI (⌘W, the File/palette Close Session, the sidebar row's Close)
    /// first asks for confirmation. nil means the default (off — the session closes immediately). An
    /// app-level behavior flag read on demand by `AppActions`, NOT a ghostty key — it never appears in
    /// `ghosttyConfigLines()`; the control channel's `session.close` closes without a prompt.
    public var confirmCloseSession: Bool?
    /// Narrows `confirmCloseSession` to sessions actually RUNNING an agent (`Session.agentKind != nil`):
    /// nil/false means the default (confirm every close, when `confirmCloseSession` is on), true means an
    /// empty terminal closes silently and only an agent session prompts. Only meaningful under
    /// `confirmCloseSession`. An app-level behavior flag read on demand by `AppActions`, NOT a ghostty key.
    public var confirmCloseOnlyRunningAgent: Bool?
    /// Whether GUI closes keep a short undo grace period before final teardown. nil means the default
    /// (on). When off, GUI closes are immediate but still enter File > Open Recent.
    public var closeGraceUndoEnabled: Bool?
    /// The undo grace window in seconds a soft close keeps before final teardown; nil means the default
    /// (`effectiveCloseGraceSeconds`, 5). An app-level behavior value read on demand by `AppActions`, NOT a
    /// ghostty key — it never appears in `ghosttyConfigLines()`.
    public var closeGraceSeconds: Double?
    /// Whether the visual "Closed X / Reopen" undo toast is shown during the grace window. nil means the
    /// default (on); the undo MECHANISM (⌘Z / Reopen Closed Item) works either way. An app-level chrome
    /// flag, NOT a ghostty key — it never appears in `ghosttyConfigLines()`.
    public var showUndoToast: Bool?
    /// The user-idle timeout that auto-follows the window's selection to the oldest blocked session, as an
    /// `AutoFollowAttention` raw value; nil means the default (`off` — disabled). An app-level per-window
    /// behavior value driving `AppStore`'s idle controller, NOT a ghostty key — it never appears in
    /// `ghosttyConfigLines()`.
    public var autoFollowAttention: String?
    /// Whether the auto-follow stays put on a currently running (`active`) session instead of pulling to a
    /// blocked one. nil/false means the default (off — auto-follow always pulls to blocked). Only meaningful
    /// when `autoFollowAttention` is set. An app-level flag, NOT a ghostty key.
    public var autoFollowStayOnActive: Bool?
    /// The sidebar row-text point size, or nil for the default (`defaultSidebarFontSize`). The row height
    /// scales with it (`sidebarRowHeight(fontSize:)`); the row icons and status glyphs keep their fixed
    /// sizes. Applied at the AppKit level when the sidebar draws, NOT a ghostty key — it never appears in
    /// `ghosttyConfigLines()`. Independent of `interfaceFontSize`: neither falls back to the other.
    public var sidebarFontSize: Double?
    /// The command palette / session-switcher text point size, or nil for the default
    /// (`defaultInterfaceFontSize`). The panel geometry scales with it (see `InterfaceMetrics`). Applied at
    /// the SwiftUI level when those panels draw, NOT a ghostty key. Deliberately separate from
    /// `sidebarFontSize`: the sidebar is a density knob, the palette a readability one.
    public var interfaceFontSize: Double?
    /// The .app bundle path files from the tree open in (double-click / the Open menu); nil means the
    /// system default (`NSWorkspace.shared.open(url)`). An app-level path read on demand when opening a
    /// file, NOT a ghostty key — it never appears in `ghosttyConfigLines()`. A stale path (app deleted)
    /// falls back to the system default at open time.
    public var editorApp: String?
    /// Whether a session row whose agent `needsAttention` (`blocked`/`completed`) is washed in that
    /// status's color — the row background plus its name text, on top of the always-on status glyph. nil
    /// means the default (on). `active` is deliberately never washed: an agent at work is the steady
    /// state, so it would keep half the sidebar colored. Render-only, applied at the AppKit level when
    /// the sidebar draws, NOT a ghostty key — it never appears in `ghosttyConfigLines()`.
    public var statusRowHighlightEnabled: Bool?
    /// Raw names of title-bar / sidebar chrome elements the user has HIDDEN (see `InterfaceElement`).
    /// nil/empty means every element is shown (the default). Stored as raw strings so an unknown future
    /// element name decodes tolerantly (it is dropped by `resolvedHiddenInterfaceElements`) instead of
    /// failing the whole decode — the AppSettings forward-compat rule. A GUI-only chrome value applied at
    /// the AppKit/SwiftUI level, NOT a ghostty key — it never appears in `ghosttyConfigLines()`.
    public var hiddenInterfaceElements: [String]?

    public init(fontFamily: String? = nil, fontSize: Double? = nil, theme: String? = nil,
                darkTheme: String? = nil, followSystemAppearance: Bool? = nil,
                backgroundOpacity: Double? = nil, backgroundBlur: Int? = nil, notificationsEnabled: Bool? = nil,
                toolbarMode: String? = nil, compactToolbar: Bool? = nil, notificationBadgeEnabled: Bool? = nil,
                activeStatusColorHex: String? = nil, blockedStatusColorHex: String? = nil,
                completedStatusColorHex: String? = nil,
                activeStatusShape: String? = nil, blockedStatusShape: String? = nil,
                completedStatusShape: String? = nil, configDirectory: String? = nil,
                mouseScrollMultiplier: Double? = nil, inactivePaneMuteStrength: Int? = nil,
                sidebarBackgroundShift: Int? = nil, restoreRunningCommand: Bool? = nil,
                resumeAgentSessions: Bool? = nil,
                inheritGlobalGhosttyConfig: Bool? = nil, attentionButtonEnabled: Bool? = nil,
                dockBounce: String? = nil, notificationSoundName: String? = nil,
                blockedStatusSoundName: String? = nil, rightClickPaste: Bool? = nil,
                workspaceRowClickExpands: Bool? = nil,
                newSessionDirectory: String? = nil, newSessionCustomDirectory: String? = nil,
                confirmCloseSession: Bool? = nil, confirmCloseOnlyRunningAgent: Bool? = nil,
                closeGraceUndoEnabled: Bool? = nil,
                closeGraceSeconds: Double? = nil, showUndoToast: Bool? = nil,
                autoFollowAttention: String? = nil,
                autoFollowStayOnActive: Bool? = nil, sidebarFontSize: Double? = nil,
                interfaceFontSize: Double? = nil,
                editorApp: String? = nil, statusRowHighlightEnabled: Bool? = nil,
                hiddenInterfaceElements: [String]? = nil) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.darkTheme = darkTheme
        self.followSystemAppearance = followSystemAppearance
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.notificationsEnabled = notificationsEnabled
        self.toolbarMode = toolbarMode
        self.compactToolbar = compactToolbar
        self.notificationBadgeEnabled = notificationBadgeEnabled
        self.activeStatusColorHex = activeStatusColorHex
        self.blockedStatusColorHex = blockedStatusColorHex
        self.completedStatusColorHex = completedStatusColorHex
        self.activeStatusShape = activeStatusShape
        self.blockedStatusShape = blockedStatusShape
        self.completedStatusShape = completedStatusShape
        self.configDirectory = configDirectory
        self.mouseScrollMultiplier = mouseScrollMultiplier
        self.inactivePaneMuteStrength = inactivePaneMuteStrength
        self.sidebarBackgroundShift = sidebarBackgroundShift
        self.restoreRunningCommand = restoreRunningCommand
        self.resumeAgentSessions = resumeAgentSessions
        self.inheritGlobalGhosttyConfig = inheritGlobalGhosttyConfig
        self.attentionButtonEnabled = attentionButtonEnabled
        self.dockBounce = dockBounce
        self.notificationSoundName = notificationSoundName
        self.blockedStatusSoundName = blockedStatusSoundName
        self.rightClickPaste = rightClickPaste
        self.workspaceRowClickExpands = workspaceRowClickExpands
        self.newSessionDirectory = newSessionDirectory
        self.newSessionCustomDirectory = newSessionCustomDirectory
        self.confirmCloseSession = confirmCloseSession
        self.confirmCloseOnlyRunningAgent = confirmCloseOnlyRunningAgent
        self.closeGraceUndoEnabled = closeGraceUndoEnabled
        self.closeGraceSeconds = closeGraceSeconds
        self.showUndoToast = showUndoToast
        self.autoFollowAttention = autoFollowAttention
        self.autoFollowStayOnActive = autoFollowStayOnActive
        self.sidebarFontSize = sidebarFontSize
        self.interfaceFontSize = interfaceFontSize
        self.editorApp = editorApp
        self.statusRowHighlightEnabled = statusRowHighlightEnabled
        self.hiddenInterfaceElements = hiddenInterfaceElements
    }

    /// The resolved set of hidden chrome elements: the known raw names from `hiddenInterfaceElements`,
    /// with any unknown (future-written) names dropped. The single read point the app target and the
    /// Settings UI use, so callers never touch the raw string list.
    public var resolvedHiddenInterfaceElements: Set<InterfaceElement> {
        Set((hiddenInterfaceElements ?? []).compactMap(InterfaceElement.init(rawValue:)))
    }

    /// Whether a given chrome element is hidden. Everything is shown by default, so an element absent from
    /// the persisted list reads as visible.
    public func isInterfaceElementHidden(_ element: InterfaceElement) -> Bool {
        resolvedHiddenInterfaceElements.contains(element)
    }

    /// The resolved titlebar row state: the explicit `toolbarMode` when set to a KNOWN raw value, else the
    /// legacy `compactToolbar` mapping (`false` = `.normal`, `true`/nil = `.compact`). An unknown/nil raw value
    /// falls through to that default the same way, so a future-written mode never fails the read. The single
    /// read point the app target uses, so callers never touch the raw shim.
    public var effectiveToolbarMode: ToolbarMode {
        toolbarMode.flatMap(ToolbarMode.init(rawValue:)) ?? (compactToolbar == false ? .normal : .compact)
    }

    /// The resolved Dock-bounce mode: the explicit `dockBounce` when set to a KNOWN raw value, else `off`.
    /// An unknown/nil raw value falls through to `off` the same way, so a future-written mode never fails
    /// the read. The single read point the app target uses, so callers never touch the raw string.
    public var effectiveDockBounce: DockBounce {
        dockBounce.flatMap(DockBounce.init(rawValue:)) ?? .off
    }

    /// The configured silhouette for a status glyph, or nil to keep that status' own semantic default
    /// glyph. nil for `.idle` (it renders no glyph at all, so a shape has nothing to draw), for an unset
    /// value, and for an UNPARSEABLE one — a hand-edited `settings.json` must degrade to the semantic
    /// default rather than crash or wipe the file (the AppSettings forward-compat rule). The single read
    /// point the app target uses, so callers never touch the raw strings.
    public func effectiveStatusShape(for status: AgentStatus) -> StatusShape? {
        switch status {
        case .active: return activeStatusShape.flatMap(StatusShape.init(rawValue:))
        case .blocked: return blockedStatusShape.flatMap(StatusShape.init(rawValue:))
        case .completed: return completedStatusShape.flatMap(StatusShape.init(rawValue:))
        case .idle: return nil
        }
    }

    /// The undo grace window in seconds a soft close keeps before final teardown; `closeGraceSeconds`
    /// when set, else the default of 5 (the fork's longer-than-upstream window). The single read point the
    /// app target uses.
    public var effectiveCloseGraceSeconds: TimeInterval { closeGraceSeconds ?? 5 }

    /// The working directory a new session should open in. A non-blank `workspaceRoot` is a HARD override
    /// (the target workspace's own root directory wins over the global mode); otherwise it resolves the
    /// `newSessionDirectory` mode against the active session's focused-pane cwd and the home directory. An
    /// unknown/nil mode, a nil/blank `currentSessionCwd`, or a nil/blank custom path all fall back to
    /// `home`: `home` → home; `currentSession` → `currentSessionCwd` (else home); `custom` →
    /// `newSessionCustomDirectory` (else home). Host-free so `AppActions.newSession()` and the tests share
    /// one resolution.
    public func resolveNewSessionCwd(workspaceRoot: String?, currentSessionCwd: String?, home: String) -> String {
        if let root = workspaceRoot, !root.isEmpty { return root }
        switch NewSessionDirectory(rawValue: newSessionDirectory ?? "") ?? .home {
        case .home:
            return home
        case .currentSession:
            guard let cwd = currentSessionCwd, !cwd.isEmpty else { return home }
            return cwd
        case .custom:
            guard let dir = newSessionCustomDirectory, !dir.isEmpty else { return home }
            return dir
        }
    }

    /// The SwiftUI overlay opacity for a given inactive-pane mute strength: the strength is clamped to
    /// 0...10 and scaled by 0.08, so 0 → 0 (no mute), 5 → 0.4 (the historical default), 10 → 0.8
    /// (extreme). The overlay is the terminal background color, so a higher opacity blends the pane's
    /// text further toward the background (less bright) while leaving background pixels unchanged.
    public static func muteOpacity(strength: Int) -> Double {
        Double(min(10, max(0, strength))) * 0.08
    }

    /// The signed sidebar background shift for a given strength: the strength is clamped to 0...10 and
    /// measured from the neutral center (5), so 5 → 0 (no shift), 0 → -0.30 (full lighten), 10 → +0.30
    /// (full darken). A positive amount darkens (a black wash over the sidebar), a negative one lightens
    /// (a white wash); the magnitude is the wash opacity. Compositing that wash over the window
    /// background is what the app target's sidebar tint does (`WindowContentView.sidebarTintWash`).
    public static func sidebarShiftAmount(strength: Int) -> Double {
        Double(min(10, max(0, strength)) - 5) * 0.06
    }

    /// The clamped sidebar row-text point size for a raw value: bounded to `sidebarFontSizeRange` so a
    /// stray persisted or out-of-range value can't produce a degenerate row.
    public static func clampSidebarFontSize(_ size: Double) -> Double {
        min(sidebarFontSizeRange.upperBound, max(sidebarFontSizeRange.lowerBound, size))
    }

    /// The clamped palette/switcher point size for a raw value: bounded to `interfaceFontSizeRange`, the
    /// twin of `clampSidebarFontSize` for the other size knob.
    public static func clampInterfaceFontSize(_ size: Double) -> Double {
        min(interfaceFontSizeRange.upperBound, max(interfaceFontSizeRange.lowerBound, size))
    }

    /// The resolved sidebar row-text size — the single read point, so no caller re-spells the nil default.
    public var effectiveSidebarFontSize: Double {
        Self.clampSidebarFontSize(sidebarFontSize ?? Self.defaultSidebarFontSize)
    }

    /// The resolved palette/switcher text size — the single read point, the twin of the sidebar's above.
    public var effectiveInterfaceFontSize: Double {
        Self.clampInterfaceFontSize(interfaceFontSize ?? Self.defaultInterfaceFontSize)
    }

    /// The outline row height for a given sidebar font size: the clamped point size plus a fixed 15pt of
    /// vertical padding, so the default 13pt maps to the historical 28pt row and larger text gets a
    /// proportionally taller row. The row icon and status glyph keep their fixed sizes.
    public static func sidebarRowHeight(fontSize: Double) -> Double {
        clampSidebarFontSize(fontSize).rounded() + 15
    }

    /// The theme name that renders for the given appearance: when following, the dark slot in dark mode
    /// (falling back to `theme`) and `theme` in light mode; otherwise the plain `theme`. Used only by the
    /// theme-palette badge/selection (emission composes the raw dual and lets ghostty pick the side).
    public func activeTheme(isDark: Bool) -> String? {
        guard followSystemAppearance == true else { return theme }
        return isDark ? (darkTheme ?? theme) : theme
    }

    /// The ghostty config lines for the set fields, one `key = value` per line, suitable for a
    /// file loaded via `ghostty_config_load_file`. Unset (or blank) fields are omitted. Values are
    /// written raw — ghostty takes the whole line remainder as the value, so names with spaces
    /// (`3024 Night`, `SF Mono`) are NOT quoted (quoting would become part of the value).
    public func ghosttyConfigLines() -> [String] {
        var lines: [String] = []
        if let fontFamily, !fontFamily.isEmpty { lines.append("font-family = \(fontFamily)") }
        if let fontSize { lines.append("font-size = \(Self.format(fontSize))") }
        // theme: when following the macOS appearance, emit ghostty's dual conditional RAW and let
        // libghostty resolve the active side on a color-scheme change (it records the new state and asks
        // the host to re-feed the config, which the reload path does). Otherwise emit the single theme.
        // No appearance input here — ghostty owns the switch.
        let light = theme.flatMap { $0.isEmpty ? nil : $0 }
        let dark = darkTheme.flatMap { $0.isEmpty ? nil : $0 }
        if followSystemAppearance == true, let light, let dark {
            lines.append("theme = light:\(light),dark:\(dark)")
        } else if let single = light ?? dark {
            lines.append("theme = \(single)")
        }
        // a translucent window composites its tint at the AppKit level, so the renderer must draw a
        // fully transparent terminal — else the surface and the window stack two tints. At full
        // opacity (or unset) ghostty paints its own background as usual and these are omitted.
        if let backgroundOpacity, backgroundOpacity < 1 {
            lines.append("background-opacity = 0")
            lines.append("background-blur = 0")
        }
        // always emitted (nil = rook's default of 3), so the default speed is effective rather than
        // ghostty's per-device defaults. a bare value sets both the wheel and the trackpad.
        lines.append("mouse-scroll-multiplier = \(Self.format(mouseScrollMultiplier ?? 3))")
        // always emitted (nil = on): rook forwards right-/middle-click to libghostty, so a right-click
        // pastes by default. off emits `ignore` so the toggle hard-disables it (the settings conf loads
        // last, so the UI owns the key over any `right-click-action` in the user's own ghostty.conf).
        lines.append("right-click-action = \((rightClickPaste ?? true) ? "paste" : "ignore")")
        return lines
    }

    /// Integer sizes render without a trailing `.0` (`14`, not `14.0`); fractional sizes keep it.
    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
