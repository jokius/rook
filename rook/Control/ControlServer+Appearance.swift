import AppKit
import Foundation
import rookCore

/// `ControlServer` arms for the per-workspace appearance commands (`workspace.color` / `workspace.icon`).
/// Split out of `ControlServer+SessionActions` to keep that file under the swiftlint size limit.
///
/// The host-free half — classifying the raw icon argument, validating a `#rrggbb`, the `clear` idiom, the
/// error strings — lives in `ControlDispatcher`. What is left here is exactly what needs AppKit or the
/// filesystem: resolving the target workspace, checking that an SF Symbol name resolves, and copying an
/// image into the state dir.
extension ControlServer {
    /// Set (or clear, with a nil `hex`) a workspace's sidebar icon color. The GUI half is the workspace
    /// row's Color… context-menu item.
    func setWorkspaceColor(_ target: String?, window: String?, hex: String?) -> ControlResponse {
        resolver.resolveWorkspace(target, window: window) { store, id in
            store.setWorkspaceColor(id, hex: hex) // delta-guarded + debounced (idempotent)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    /// Set (or clear, with a nil `icon`) a workspace's sidebar icon. Two checks need the host:
    ///
    /// - `.symbol` — the name must RESOLVE, else the icon would silently fall back to the default glyph and
    ///   the command would report success. Same precedent as the `session.status --sound` name check.
    /// - `.image` — the file must exist, and is COPIED into the state dir so the icon survives the original
    ///   being moved or deleted. Re-installing a path that ALREADY lives there returns it unchanged, which
    ///   is what lets a script feed the `tree` read-back straight back in (record-then-restore).
    func setWorkspaceIcon(_ target: String?, window: String?, icon: WorkspaceIcon?) -> ControlResponse {
        if let icon, icon.kind == .symbol, NSImage(systemSymbolName: icon.value, accessibilityDescription: nil) == nil {
            return ControlResponse(ok: false, error: "unknown SF Symbol: \(icon.value)")
        }
        if let icon, icon.kind == .image, !FileManager.default.fileExists(atPath: icon.value) {
            return ControlResponse(ok: false, error: "no such image file: \(icon.value)")
        }
        return resolver.resolveWorkspace(target, window: window) { store, id in
            guard let icon else {
                store.setWorkspaceIcon(id, icon: nil)
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
            }
            var resolved = icon
            if icon.kind == .image {
                do {
                    resolved = try WorkspaceIconStorage.install(source: URL(fileURLWithPath: icon.value), workspaceID: id)
                } catch {
                    return ControlResponse(ok: false, error: "failed to install icon: \(error.localizedDescription)")
                }
            }
            store.setWorkspaceIcon(id, icon: resolved)
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }
}
