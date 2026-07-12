import Foundation

/// Pure builders for the `ROOK_*` environment values injected into spawned shells.
/// The platform surface owns shell creation; this keeps the variable set testable.
public enum SurfaceEnvironment {
    /// Environment for a session-owned surface: main pane, split pane, overlay, or scratch.
    /// `pane`, when non-nil, adds `ROOK_PANE` so the hook wrapper can forward `--pane` and a status
    /// set from a background pane records which surface blocked; overlay surfaces pass nil (nil→main).
    public static func session(sessionID: UUID, windowID: UUID?, workspaceID: UUID?,
                               socketPath: String, pane: StatusPane? = nil) -> [String: String] {
        var env = [
            "ROOK_ENABLED": "1",
            "ROOK_SESSION_ID": sessionID.uuidString,
            "ROOK_SOCKET": socketPath,
        ]
        if let windowID {
            env["ROOK_WINDOW_ID"] = windowID.uuidString
        }
        if let workspaceID {
            env["ROOK_WORKSPACE_ID"] = workspaceID.uuidString
        }
        if let pane {
            env["ROOK_PANE"] = pane.rawValue
        }
        return env
    }

    /// Environment for a window's quick terminal, which is not part of the session tree.
    public static func quickTerminal(windowID: UUID, socketPath: String) -> [String: String] {
        [
            "ROOK_ENABLED": "1",
            "ROOK_WINDOW_ID": windowID.uuidString,
            "ROOK_SOCKET": socketPath,
        ]
    }
}
