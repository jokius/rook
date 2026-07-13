// adapted from thdxg/macterm (MIT)

import rookCore
import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.rook.app", category: "GhosttyApp")

/// Manages the libghostty application lifecycle: init, config, tick loop.
@MainActor
final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    /// The number of config diagnostics (parse errors / invalid keys) from the most recent `loadConfig`,
    /// counted across ALL loaded sources (bundled defaults, `~/.config/ghostty/config`, the rook-scoped
    /// `ghostty.conf`, and the UI settings conf). libghostty diagnostics carry no source-file attribution,
    /// so this is NOT specific to `ghostty.conf`. Surfaced by `reloadConfig` so File ▸ Reload Config (and
    /// `config.reload`) can warn the user when the resolved config has problems; the Console log shows the
    /// offending line. Reset on each `loadConfig`.
    private(set) var lastConfigDiagnosticsCount = 0
    /// The terminal background color parsed from the resolved config. Used to tint the
    /// window so the title bar blends with the terminal instead of drawing the default
    /// titlebar material. Nil if the color couldn't be read.
    private(set) var terminalBackgroundColor: NSColor?
    /// The terminal foreground (text) color parsed from the resolved config. The chrome (sidebar row
    /// text + icons, title bar text + buttons) uses it so non-terminal text tracks the theme instead
    /// of the system label color. Nil if the color couldn't be read.
    private(set) var terminalForegroundColor: NSColor?
    /// Whether the active terminal theme reads as dark, by the perceived luminance of the sidebar
    /// background the disclosure triangle sits on — the theme background with the sidebar-tint wash
    /// applied. Pins AppKit-drawn chrome (the sidebar disclosure triangle) to the theme instead of the
    /// macOS system appearance, so a light theme under macOS dark mode still draws dark, visible chrome.
    /// Classifying the washed color (not the raw background) keeps it correct when a strong sidebar tint
    /// pushes a near-threshold theme across the midpoint. Defaults to dark when the background couldn't
    /// be read (the app's default chrome).
    var terminalThemeIsDark: Bool {
        guard let bg = terminalBackgroundColor?.usingColorSpace(.sRGB) else { return true }
        let shiftAmount = AppSettings.sidebarShiftAmount(strength: sidebarBackgroundShift)
        return ThemeBrightness.isDark(red: Double(bg.redComponent), green: Double(bg.greenComponent),
                                      blue: Double(bg.blueComponent), shiftAmount: shiftAmount)
    }
    /// Window translucency the chrome composites at the AppKit level — the background opacity
    /// (0...1) and CGS blur radius the Settings window last applied. NOT ghostty-resolved:
    /// `WindowAppearance.sync` reads these, `SettingsModel` writes them. Defaults are opaque.
    private(set) var windowOpacity: Double = 1
    private(set) var windowBlurRadius: Int = 0
    /// The custom title bar row state (normal/compact/hidden): normal stacks the cwd subtitle, compact is a
    /// single short row, hidden drops the row and the traffic lights for a full-bleed terminal. NOT
    /// ghostty-resolved: `WindowContentView`/`WindowAppearance.sync` read it, `SettingsModel` writes it.
    /// Defaults to compact (the app default; `settings.toolbarMode == nil` resolves to `.compact`).
    private(set) var toolbarMode: ToolbarMode = .compact
    /// Whether the sidebar draws the red unseen-notification count badge. NOT ghostty-resolved: the
    /// sidebar Coordinator reads it (gating the count to 0 when off), `SettingsModel` writes it. The
    /// re-render rides the `.rookAppearanceChanged` notification, like `toolbarMode`.
    private(set) var notificationBadgeEnabled: Bool = true
    /// Whether a restored pane re-runs the command it had in the foreground at the last clean quit
    /// (`AppSettings.restoreRunningCommand`). The surface factories read it to decide whether to feed the
    /// captured command as `initial_input`; `SettingsModel` writes it. Not ghostty-resolved, and it only
    /// affects the next restore, so no live re-render notification.
    private(set) var restoreRunningCommand: Bool = false
    /// Whether the window title bar shows the attention bell icon. NOT ghostty-resolved: the title bar
    /// reads it (via `WindowContentView`'s mirrored chrome state), `SettingsModel` writes it. The
    /// re-render rides the `.rookAppearanceChanged` notification, like `toolbarMode`. Defaults off.
    private(set) var attentionButtonEnabled: Bool = false
    /// Program basenames NOT to re-run on restore — the parsed user-editable `restore-denylist.conf`
    /// (seeded with the terminal multiplexers). The surface factories read it via
    /// `CommandRestore.shouldRestore`; `SettingsModel` parses the file and writes it. Read at launch only.
    private(set) var restoreDenylist: Set<String> = []
    /// Inactive-split-pane text mute strength on the 0...10 scale. NOT ghostty-resolved: the detail
    /// pane's `paneDim` overlay reads it (via `AppSettings.muteOpacity`), `SettingsModel` writes it. The
    /// re-render rides the `.rookAppearanceChanged` notification, like `toolbarMode`.
    private(set) var inactivePaneMuteStrength: Int = AppSettings.defaultInactivePaneMuteStrength
    /// How much darker/lighter the sidebar background is than the terminal (0...10, 5 = neutral). NOT
    /// ghostty-resolved: `ContentView` mirrors it into view state and renders the sidebar wash (via
    /// `AppSettings.sidebarShiftAmount`), `SettingsModel` writes it. The re-render rides the
    /// `.rookAppearanceChanged` notification, like `toolbarMode`.
    private(set) var sidebarBackgroundShift: Int = AppSettings.defaultSidebarBackgroundShift
    /// The sidebar row-text point size. NOT ghostty-resolved: the sidebar Coordinator reads it when
    /// building each row's font and deriving the row height (via `AppSettings.sidebarRowHeight`),
    /// `SettingsModel` writes it. The re-render rides the `.rookAppearanceChanged` notification, like
    /// `toolbarMode`.
    private(set) var sidebarFontSize: CGFloat = CGFloat(AppSettings.defaultSidebarFontSize)
    /// The agent-status glyph colors (active/blocked/completed). NOT ghostty-resolved: `StatusIconView`
    /// reads them when building the glyph, `SettingsModel` writes them (resolved from the user's hex or
    /// the default). The sidebar re-render rides the `.rookAppearanceChanged` notification. The active
    /// default is a muted lavender-grey (`#DBD9E6`); blocked/completed default to system orange/green.
    static let defaultActiveStatusColor: NSColor = NSColor(rookHex: "#DBD9E6") ?? .systemBlue
    private(set) var activeStatusColor: NSColor = GhosttyApp.defaultActiveStatusColor
    private(set) var blockedStatusColor: NSColor = .systemOrange
    private(set) var completedStatusColor: NSColor = .systemGreen
    /// Whether a `blocked`/`completed` session row is washed in its status color. NOT ghostty-resolved:
    /// the sidebar Coordinator reads it through `statusRowHighlight(for:)`, `SettingsModel` writes it. The
    /// re-render rides the `.rookAppearanceChanged` notification, like `notificationBadgeEnabled`.
    private(set) var statusRowHighlightEnabled: Bool = true
    let callbacks = GhosttyCallbacks()
    private var resourcesDir: String?

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        let configInputs = Self.resolveConfigInputs()
        guard let cfg = loadConfig(configInputs) else {
            logger.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.shared.callbacks.readClipboard(ud: ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, request in
            GhosttyApp.shared.callbacks.confirmReadClipboard(ud: ud, content: content, state: state, request: request)
        }
        rt.write_clipboard_cb = { ud, _, content, len, confirm in
            GhosttyApp.shared.callbacks.writeClipboard(ud: ud, content: content, len: UInt(len), confirm: confirm)
        }
        rt.close_surface_cb = { ud, _ in GhosttyApp.shared.callbacks.closeSurface(ud: ud) }

        guard let createdApp = ghostty_app_new(&rt, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = createdApp
        config = cfg
        resolveThemeColors(from: cfg)
        // demand-driven: no poll timer. ticks come from libghostty wakeups (coalesced in
        // GhosttyCallbacks.wakeup) and surfaces draw on GHOSTTY_ACTION_RENDER, matching Ghostty.app/conterm
        // — an idle terminal does no work, where a 120Hz poll ticked continuously.
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Set the window translucency the chrome applies. Called by `SettingsModel` at launch and on
    /// every change; the actual window re-sync rides the `.rookAppearanceChanged` notification.
    func setWindowTranslucency(opacity: Double, blurRadius: Int) {
        windowOpacity = opacity
        windowBlurRadius = blurRadius
    }

    /// Set the custom title bar row state (normal/compact/hidden). Called by `SettingsModel` at launch
    /// and on every change; the window re-sync rides the `.rookAppearanceChanged` notification.
    func setToolbarMode(_ mode: ToolbarMode) {
        toolbarMode = mode
    }

    /// Set whether the sidebar draws the notification count badge. Called by `SettingsModel` at launch
    /// and on every change; the sidebar re-reconcile rides the `.rookAppearanceChanged` notification.
    func setNotificationBadgeEnabled(_ enabled: Bool) {
        notificationBadgeEnabled = enabled
    }

    /// Set whether restored panes re-run their captured foreground command. Called by `SettingsModel` at
    /// launch and on every change; read by the surface factories at restore time.
    func setRestoreRunningCommand(_ enabled: Bool) {
        restoreRunningCommand = enabled
    }

    /// Set whether the title bar shows the attention bell icon. Called by `SettingsModel` at launch and on
    /// every change; the title-bar re-render rides the `.rookAppearanceChanged` notification.
    func setAttentionButtonEnabled(_ enabled: Bool) {
        attentionButtonEnabled = enabled
    }

    /// Set the parsed restore denylist (program basenames not to re-run). Called by `SettingsModel` at
    /// launch from `restore-denylist.conf`; read by the surface factories at restore time.
    func setRestoreDenylist(_ denylist: Set<String>) {
        restoreDenylist = denylist
    }

    /// Set the inactive-split-pane mute strength (0...10). Called by `SettingsModel` at launch and on
    /// every change; the detail-pane re-render rides the `.rookAppearanceChanged` notification.
    func setInactivePaneMuteStrength(_ strength: Int) {
        inactivePaneMuteStrength = strength
    }

    /// Set the sidebar background shift (0...10, 5 = neutral). Called by `SettingsModel` at launch and on
    /// every change; the window re-sync rides the `.rookAppearanceChanged` notification.
    func setSidebarBackgroundShift(_ strength: Int) {
        sidebarBackgroundShift = strength
    }

    /// Set the sidebar row-text point size. Called by `SettingsModel` at launch and on every change; the
    /// sidebar re-render (fonts + row height) rides the `.rookAppearanceChanged` notification.
    func setSidebarFontSize(_ size: Double) {
        // clamp here so both readers (the row font AND the row height) see an in-range value. the Settings
        // stepper already bounds 9...20, but a hand-edited or future-range settings.json must not render a
        // giant font inside the clamped row (sidebarRowHeight clamps its own copy for the height).
        sidebarFontSize = CGFloat(AppSettings.clampSidebarFontSize(size))
    }

    /// Set the agent-status glyph colors from the user's hex settings (nil/malformed → the system
    /// default). Called by `SettingsModel` at launch and on every change; the sidebar re-renders the
    /// glyphs on the `.rookAppearanceChanged` notification.
    func setAgentStatusColors(activeHex: String?, blockedHex: String?, completedHex: String?) {
        activeStatusColor = NSColor(rookHex: activeHex) ?? GhosttyApp.defaultActiveStatusColor
        blockedStatusColor = NSColor(rookHex: blockedHex) ?? .systemOrange
        completedStatusColor = NSColor(rookHex: completedHex) ?? .systemGreen
    }

    /// The configured tint for a status glyph, shared by the AppKit sidebar `StatusIconView` and the
    /// SwiftUI `StatusGlyph` so the two can't drift. `idle` never renders a glyph (it is filtered out
    /// before any glyph is built), so its color is unused — it returns `.clear` as a benign default.
    func statusColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .active: return activeStatusColor
        case .blocked: return blockedStatusColor
        case .completed: return completedStatusColor
        case .idle: return .clear
        }
    }

    /// The tint for a status glyph, honoring an optional per-call `#rrggbb` OVERRIDE from
    /// `session.status --color` (set on the ephemeral `AgentIndicator`). A valid override wins; nil or
    /// malformed falls back to the Settings-configured `statusColor(for:)`. Shared by the AppKit sidebar
    /// `StatusIconView` and the SwiftUI `StatusGlyph` so the two can't drift.
    func statusColor(for status: AgentStatus, override hex: String?) -> NSColor {
        NSColor(rookHex: hex) ?? statusColor(for: status)
    }

    /// The color a session ROW is washed in for `indicator`, or nil for no wash — the single gate both
    /// halves of the highlight (the row background in `SidebarRowView` and the name text in
    /// `SidebarCellView.setColors`) read, so they can't disagree. Only the attention states
    /// (`blocked`/`completed`) wash: an `active` agent is the steady state and would keep half the sidebar
    /// colored, so it stays glyph-only. The per-call `session.status --color` override rides along, like
    /// the glyph's.
    func statusRowHighlight(for indicator: AgentIndicator) -> NSColor? {
        guard statusRowHighlightEnabled, indicator.status.needsAttention else { return nil }
        return statusColor(for: indicator.status, override: indicator.color)
    }

    /// Set whether a `blocked`/`completed` row is washed in its status color. Called by `SettingsModel` at
    /// launch and on every change; the sidebar re-renders the rows on `.rookAppearanceChanged`.
    func setStatusRowHighlightEnabled(_ enabled: Bool) {
        statusRowHighlightEnabled = enabled
    }

    // MARK: - Config

    /// Path to rook's generated ghostty config (font/size/theme from the Settings window), in the
    /// same state directory as the workspace snapshot (honors `ROOK_STATE_DIR` for tests).
    static var settingsConfigURL: URL {
        let dir = ProcessInfo.processInfo.environment["ROOK_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PersistenceStore.defaultDirectory
        return dir.appendingPathComponent("ghostty-settings.conf")
    }

    /// The config inputs resolved from `settings.json` in ONE read: the rook-scoped `ghostty.conf` URL
    /// (`<configDir>/ghostty.conf`, co-located with `keymap.conf`) and whether to inherit the user's GLOBAL
    /// `~/.config/ghostty/config` (`inheritGlobalGhosttyConfig`, default off). Callers resolve this ONCE per
    /// config build and thread it to `loadConfig`, so a single reload reads
    /// `settings.json` at most once. Resolved self-contained because `loadConfig` runs before any
    /// `SettingsModel` exists (its first touch of `GhosttyApp.shared` is inside `SettingsModel.init`): it
    /// reads the persisted `configDirectory` + flag from a `SettingsStore` rooted the SAME way
    /// `rookApp.init` builds it (via `settingsStore()`), applying the keymap's precedence
    /// (explicit setting → `ROOK_STATE_DIR/config` → `~/.config/rook`).
    struct ConfigInputs {
        let scopedURL: URL
        let inheritGlobalConfig: Bool
    }

    static func resolveConfigInputs() -> ConfigInputs {
        let settings = settingsStore().load()
        let configDir = ConfigPaths.configDirectory(
            setting: settings.configDirectory,
            stateDir: ProcessInfo.processInfo.environment["ROOK_STATE_DIR"],
            home: FileManager.default.homeDirectoryForCurrentUser)
        return ConfigInputs(scopedURL: ConfigPaths.ghosttyConfigPath(configDirectory: configDir),
                            inheritGlobalConfig: settings.inheritGlobalGhosttyConfig ?? false)
    }

    /// The persisted settings store, rooted the SAME way `rookApp.init` builds it: `ROOK_STATE_DIR`
    /// when set (test isolation), else the default Application Support directory. `ghosttyConfigURL`
    /// reads `configDirectory` through this so it resolves the SAME `settings.json` the active
    /// `SettingsModel` does. A bare `SettingsStore()` would read the default app-support file even under
    /// `ROOK_STATE_DIR` isolation, so an explicit `configDirectory` in the state-dir settings would be
    /// ignored (and a production one could leak into an isolated run), pointing GhosttyApp and
    /// SettingsModel at different `ghostty.conf` files.
    private static func settingsStore() -> SettingsStore {
        ProcessInfo.processInfo.environment["ROOK_STATE_DIR"]
            .map { SettingsStore(directory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? SettingsStore()
    }

    /// Rebuilds the config (re-reading the rook settings file) and broadcasts it to the app and the
    /// given live surfaces — a live appearance change. Keeps the new config as `self.config`; the
    /// previous config is intentionally NOT freed: settings changes are rare and `update_config`
    /// has no documented ownership contract, so this matches the existing never-free pattern over
    /// risking a use-after-free. Returns the rebuilt config's diagnostic count (0 = clean) so a
    /// Reload Config can warn the user about a malformed `ghostty.conf`.
    @discardableResult
    func reloadConfig(surfaces: [GhosttySurfaceView], isDark: Bool) -> Int {
        // no app (called before `ghostty_app_new` succeeded) or `ghostty_config_new` allocation failure:
        // nothing was re-read, so report the last known count. The property name is "from the most recent
        // loadConfig", and both paths are effectively unreachable in practice (the app is always booted
        // before a reload is reachable, and config allocation only fails under OOM).
        guard let app else { return lastConfigDiagnosticsCount }
        let inputs = Self.resolveConfigInputs()
        guard let newConfig = loadConfig(inputs) else { return lastConfigDiagnosticsCount }
        // Re-assert the app + each surface's light/dark scheme from the authoritative `isDark` (the
        // KVO-delivered side, else `currentIsDark()`) BEFORE feeding the config: libghostty re-resolves a
        // dual `theme = light:,dark:` to the side matching the recorded conditional state, so a stale side
        // would re-derive the wrong theme. Setting the APP scheme here (not only per surface) makes a
        // ZERO-surface reload chrome-correct — the CONFIG_CHANGE clone below resolves to `isDark` even with
        // no surfaces, so a dark launch re-sides the sidebar/titlebar before any surface exists. Cheap
        // (each set no-ops when unchanged); the config re-feed below is what actually re-renders.
        ghostty_app_set_color_scheme(app, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        for surface in surfaces { surface.syncColorScheme(isDark: isDark) }
        ghostty_app_update_config(app, newConfig)
        // ghostty replies to update_config with a synchronous app-target CONFIG_CHANGE carrying the
        // config it APPLIED — the dual `theme = light:,dark:` resolved to the current appearance side.
        // Read the chrome colors from THAT clone below: newConfig itself is always finalized with the
        // default (light) conditional state, so reading it directly while following in dark mode would
        // tint the sidebar/titlebar with the LIGHT slot while the terminal renders the dark one. Falls
        // back to newConfig when nothing was stashed (no conditional in play).
        let derivedConfig = callbacks.takeDerivedAppConfig()
        for surface in surfaces { surface.applyConfig(newConfig) }
        config = newConfig
        // refresh the chrome colors from the NEW config BEFORE the watermark re-assert below: a default-tinted
        // `.text` watermark re-renders its PNG reading `terminalForegroundColor`, so the foreground must already
        // reflect the new theme — otherwise the text watermark's color lags one reload behind a theme change.
        resolveThemeColors(from: derivedConfig ?? newConfig)
        if let derivedConfig { ghostty_config_free(derivedConfig) }
        // the broadcast above pushes the shared config (no background image, default font size) to every
        // surface, wiping any per-surface watermark and zoom — so re-assert each affected surface's
        // overlay afterwards. No-op for the surfaces without either; on the zoom-clearing reload paths
        // the per-session fontSize was already nil'd, so only watermarks re-apply there.
        for surface in surfaces { surface.reapplySessionConfigIfNeeded() }
        return lastConfigDiagnosticsCount
    }

    /// Re-read the chrome colors (background, foreground) from a resolved config. Called at init and on
    /// every settings reload. The selection colors are NOT read from the theme: the selected sidebar row
    /// draws rook's own brand pill (`NSColor.rookGreen`/`.rookGraphite`), so nothing needs the theme's
    /// optional `selection-*` keys — which `ghostty_config_get` cannot return anyway.
    private func resolveThemeColors(from config: ghostty_config_t) {
        terminalBackgroundColor = Self.color(from: config, key: "background")
        terminalForegroundColor = Self.color(from: config, key: "foreground")
    }

    /// Whether the app is currently in the dark appearance. `NSApp` is an implicitly-unwrapped global
    /// that is still nil during the very early `GhosttyApp.shared` init (it boots from `SettingsModel.init`
    /// before AppKit finishes wiring `NSApp`), so chain through it safely; that early window no longer
    /// resolves a theme (the config emits the raw dual value and ghostty picks the side from the color
    /// scheme set at surface creation), so a light default there is harmless.
    static func currentIsDark() -> Bool {
        guard let appearance = NSApp?.effectiveAppearance else { return false }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Build a per-surface config = the SAME base files as `loadConfig` plus a small overlay (a session's
    /// `background-image*` + font-size lines, from `WatermarkConfig.overlayText`). The overlay is written
    /// to a temp file, loaded LAST (so it wins over the settings conf), then deleted (`load_file` reads
    /// synchronously). The caller (`GhosttySurfaceView`) owns the returned config and frees it on surface
    /// teardown. An empty overlay yields the plain base config (used to CLEAR a watermark). The app-wide
    /// `lastConfigDiagnosticsCount` is preserved (a per-surface build must not clobber what `config.reload`
    /// reports). Returns nil on allocation failure.
    func configWithOverlay(_ overlayText: String) -> ghostty_config_t? {
        var overlayPath: String?
        if !overlayText.isEmpty {
            let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("rook-wm-\(UUID().uuidString).conf")
            do {
                try overlayText.write(toFile: tmp, atomically: true, encoding: .utf8)
                overlayPath = tmp
            } catch {
                logger.warning("watermark overlay write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let savedCount = lastConfigDiagnosticsCount
        let cfg = loadConfig(Self.resolveConfigInputs(), extraOverlayPath: overlayPath)
        lastConfigDiagnosticsCount = savedCount
        if let overlayPath { try? FileManager.default.removeItem(atPath: overlayPath) }
        return cfg
    }

    private func loadConfig(_ inputs: ConfigInputs, extraOverlayPath: String? = nil) -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }

        // app's built-in defaults (terminal padding, etc.), loaded first so the
        // rook-scoped ghostty.conf (and the global config, when opted in) still overrides them.
        if let defaults = Bundle.main.url(forResource: "ghostty-defaults", withExtension: "conf") {
            defaults.path.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // the user's GLOBAL ~/.config/ghostty/config is OFF by default (rook is self-contained): a
        // config written for the standalone Ghostty.app must not silently change rook. It is loaded
        // only when `inheritGlobalGhosttyConfig` is opted in. libghostty does NOT read the XDG config on
        // its own, so we load it explicitly when present; `config-file` includes resolve below.
        if inputs.inheritGlobalConfig {
            let userPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
            if FileManager.default.fileExists(atPath: userPath) {
                userPath.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                logger.info("inherit on, but no user ghostty config at \(userPath, privacy: .public)")
            }
        }

        // rook-scoped ghostty config (`<configDir>/ghostty.conf`, co-located with keymap.conf) — the
        // place for rook overrides/customizations. ALWAYS loaded (regardless of the inherit toggle),
        // after the optional global config so it overrides the bundled defaults + the user's global
        // config for any key, but BEFORE rook's UI settings so the Settings picker still wins for what
        // it manages. Skipped when absent (the starter is comment-only, so a fresh install is a no-op).
        let scopedPath = inputs.scopedURL.path
        if FileManager.default.fileExists(atPath: scopedPath) {
            scopedPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // rook's own appearance settings (Settings window: font / size / theme), loaded last so
        // they win over the user's ghostty config for the keys the UI manages.
        let settingsConf = Self.settingsConfigURL.path
        if FileManager.default.fileExists(atPath: settingsConf) {
            settingsConf.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // a per-surface overlay (a session's background-image / font-size lines), loaded LAST so it wins
        // over everything above. Only `configWithOverlay` passes this; the app/global build leaves it nil.
        if let extraOverlayPath, FileManager.default.fileExists(atPath: extraOverlayPath) {
            extraOverlayPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        let diagCount = ghostty_config_diagnostics_count(cfg)
        lastConfigDiagnosticsCount = Int(diagCount)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                logger.warning("config: \(String(cString: msg), privacy: .public)")
            }
        }
        return cfg
    }

    /// Reads a named color key (e.g. `background`, `foreground`) from the resolved config as an
    /// opaque `NSColor`, or nil if the key isn't set.
    private static func color(from config: ghostty_config_t, key: String) -> NSColor? {
        var color = ghostty_config_color_s()
        let got = key.withCString { ghostty_config_get(config, &color, $0, UInt(key.utf8.count)) }
        guard got else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255.0,
                       green: CGFloat(color.g) / 255.0,
                       blue: CGFloat(color.b) / 255.0,
                       alpha: 1)
    }

    // MARK: - Resources

    /// Candidate ghostty resource dirs, highest priority first. rook ships the
    /// ghostty resources in its own bundle (downloaded by setup.sh) under
    /// `Contents/Resources/ghostty`, mirroring a real Ghostty.app, with the
    /// compiled terminfo DB at the sibling `Contents/Resources/terminfo`. The
    /// installed Ghostty.app dirs remain as fallbacks for an unprepared dev
    /// checkout.
    private static let resourcePaths: [String] = {
        var paths: [String] = []
        if let resources = Bundle.main.resourceURL?.path {
            paths.append(resources + "/ghostty")
        }
        paths.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
        paths.append(NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty")
        return paths
    }()

    private func resolveResources() {
        // Always resolve from our own candidates (bundle first), ignoring any
        // inherited GHOSTTY_RESOURCES_DIR. A stale value would otherwise shadow
        // our complete bundle and leave libghostty deriving a broken TERMINFO.
        //
        // We only set GHOSTTY_RESOURCES_DIR. TERMINFO is NOT set here on
        // purpose: libghostty unconditionally overwrites it at shell spawn with
        // dirname(GHOSTTY_RESOURCES_DIR)/terminfo, so any setenv here would be
        // clobbered. Because our resources dir is .../Resources/ghostty, that
        // derivation lands on .../Resources/terminfo — the sibling dir we ship.
        let resolver = GhosttyResourceResolver(
            candidates: Self.resourcePaths,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        guard let dir = resolver.resolve() else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
            return
        }
        resourcesDir = dir
        setenv("GHOSTTY_RESOURCES_DIR", dir, 1)
    }
}

extension Notification.Name {
    /// Posted after the ghostty config is reloaded from a settings change, so the SwiftUI chrome
    /// (the quick terminal backing) and the AppKit window appearance (title bar + window background →
    /// sidebar) re-read the new `GhosttyApp.terminalBackgroundColor` immediately instead of waiting
    /// for the window to re-key.
    static let rookAppearanceChanged = Notification.Name("rook.appearanceChanged")

    /// Posted by `SystemAppearanceObserver` (an app-level KVO observer on `NSApplication.effectiveAppearance`)
    /// when the macOS light/dark appearance changes, and once at launch, carrying the resolved `isDark` in
    /// userInfo. `SettingsModel` re-resolves the active side of a `theme = light:,dark:` pair and
    /// rewrites+reloads the config — this pinned libghostty doesn't switch the dual conditional at runtime,
    /// so rook drives the swap itself. KVO delivers the settled value across sleep/wake, unlike the old
    /// per-view `viewDidChangeEffectiveAppearance` hook that wedged. Also posted by the `debug.appearance`
    /// UI-test seam. Distinct from `rookAppearanceChanged` (the settings→chrome direction); this is the
    /// system→settings direction.
    static let rookSystemAppearanceChanged = Notification.Name("rook.systemAppearanceChanged")

    /// Posted when a window becomes frontmost (the active-window change is async, via the window's
    /// didBecomeKey), so the control server can refresh its cached `window.list` — whose `active` flag
    /// would otherwise stay stale until the next dispatched command.
    static let rookWindowFrontmostChanged = Notification.Name("rook.windowFrontmostChanged")

    /// Posted after `keymap.conf` is (re)loaded and reparsed, so the custom-command runner rebuilds its
    /// matcher and the action palette re-reads the custom commands. The data-driven menu shortcuts
    /// re-render on their own because they read the `@Observable` keymap directly.
    static let rookKeymapChanged = Notification.Name("rook.keymapChanged")
}
