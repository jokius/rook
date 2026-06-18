import agtCore
import Foundation

/// The observable settings state for the Settings window. Loads `AppSettings` from `SettingsStore`
/// at init; each mutation persists AND applies live to the running terminals.
///
/// Applying writes the ghostty settings file, rebuilds + broadcasts the config to every live
/// surface, and clears per-session font-size overrides (the shared `update_config` resets all
/// surfaces to the new default, so the persisted overrides are cleared to match).
@Observable
@MainActor
final class SettingsModel {
    private let store: AppStore
    private let settingsStore: SettingsStore
    private(set) var settings: AppSettings

    init(store: AppStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
        self.settings = settingsStore.load()
    }

    func setFontFamily(_ value: String?) { settings.fontFamily = value; persistAndApply() }
    func setFontSize(_ value: Double?) { settings.fontSize = value; persistAndApply() }
    func setTheme(_ value: String?) { settings.theme = value; persistAndApply() }

    private func persistAndApply() {
        try? settingsStore.save(settings)
        writeGhosttyConfig()
        GhosttyApp.shared.reloadConfig(surfaces: liveSurfaces())
        store.resetSessionFontSizes()
        // refresh the app chrome (status bar + title bar + sidebar) with the new terminal color
        // immediately, rather than only when the window next re-keys.
        NotificationCenter.default.post(name: .agtAppearanceChanged, object: nil)
    }

    /// Write the `font-family`/`font-size`/`theme` lines to the file `GhosttyApp.loadConfig` reads.
    private func writeGhosttyConfig() {
        let url = GhosttyApp.settingsConfigURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = settings.ghosttyConfigLines().joined(separator: "\n")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// All live ghostty surfaces: each session's primary + split surface, plus the quick terminal.
    private func liveSurfaces() -> [GhosttySurfaceView] {
        var views = store.workspaces
            .flatMap(\.sessions)
            .flatMap { [$0.surface, $0.splitSurface] }
            .compactMap { $0 as? GhosttySurfaceView }
        if let quick = QuickTerminalController.shared.currentSurface() { views.append(quick) }
        return views
    }
}
