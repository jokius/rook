import Foundation
import Testing
@testable import rookCore

struct SurfaceEnvironmentTests {
    @Test func terminalIdentityBelongsToRook() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let sessionEnv = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: nil,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0"
        )
        let quickEnv = SurfaceEnvironment.quickTerminal(
            windowID: windowID,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0"
        )

        for env in [sessionEnv, quickEnv] {
            #expect(env["TERM_PROGRAM"] == "rook")
            #expect(env["TERM_PROGRAM_VERSION"] == "0.12.0")
        }
    }

    @Test func sessionEnvironmentCarriesAllKnownIdentifiers() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "ROOK_ENABLED": "1",
            "ROOK_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "ROOK_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "ROOK_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "ROOK_SOCKET": "/tmp/rook.sock",
            "TERM_PROGRAM": "rook",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func sessionEnvironmentOmitsUnknownWindowAndWorkspace() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "ROOK_ENABLED": "1",
            "ROOK_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "ROOK_SOCKET": "/tmp/rook.sock",
            "TERM_PROGRAM": "rook",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test(arguments: [
        (StatusPane.left, "left"),
        (StatusPane.right, "right"),
        (StatusPane.scratch, "scratch"),
    ])
    func sessionEnvironmentInjectsPaneWhenGiven(pane: StatusPane, expected: String) {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0",
            pane: pane
        )

        #expect(env["ROOK_PANE"] == expected)
        // pane injection must not disturb the existing identifiers
        #expect(env["ROOK_ENABLED"] == "1")
        #expect(env["ROOK_SESSION_ID"] == "11111111-1111-1111-1111-111111111111")
        #expect(env["ROOK_SOCKET"] == "/tmp/rook.sock")
    }

    @Test func sessionEnvironmentOmitsPaneWhenNil() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let workspaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: windowID,
            workspaceID: workspaceID,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0",
            pane: nil
        )

        #expect(env["ROOK_PANE"] == nil)
        // the full identifier set is unchanged when no pane is given
        #expect(env == [
            "ROOK_ENABLED": "1",
            "ROOK_SESSION_ID": "11111111-1111-1111-1111-111111111111",
            "ROOK_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "ROOK_WORKSPACE_ID": "33333333-3333-3333-3333-333333333333",
            "ROOK_SOCKET": "/tmp/rook.sock",
            "TERM_PROGRAM": "rook",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
    }

    @Test func quickTerminalEnvironmentOmitsSessionAndWorkspaceIdentifiers() {
        let windowID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        let env = SurfaceEnvironment.quickTerminal(
            windowID: windowID,
            socketPath: "/tmp/rook.sock",
            programVersion: "0.12.0"
        )

        #expect(env == [
            "ROOK_ENABLED": "1",
            "ROOK_WINDOW_ID": "22222222-2222-2222-2222-222222222222",
            "ROOK_SOCKET": "/tmp/rook.sock",
            "TERM_PROGRAM": "rook",
            "TERM_PROGRAM_VERSION": "0.12.0",
        ])
        #expect(env["ROOK_SESSION_ID"] == nil)
        #expect(env["ROOK_WORKSPACE_ID"] == nil)
    }

    @Test func emptySocketPathIsStillEmitted() {
        let sessionID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let env = SurfaceEnvironment.session(
            sessionID: sessionID,
            windowID: nil,
            workspaceID: nil,
            socketPath: "",
            programVersion: "0.12.0"
        )

        #expect(env["ROOK_SOCKET"] == "")
    }
}
