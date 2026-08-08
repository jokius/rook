import Foundation
import Testing
@testable import rookCore

/// Dispatcher coverage for the caller-shell argument the spawning commands carry.
/// Split out of `ControlDispatcherTests` purely for the file-length budget — the same seam
/// `ControlDispatcherWorkspaceTests`/`…PickTests`/`…HudTests` already use.
@MainActor
struct ControlDispatcherShellTests {
    /// Builds a request from its WIRE form, for a field the typed `ControlArgs` does not carry yet — so
    /// these cases compile against the pre-feature protocol instead of failing the build.
    private func request(_ json: String) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))
    }

    /// A malformed `--shell` is rejected on every command that spawns a new shell for the caller, and it
    /// is rejected BEFORE anything is mutated — the same up-front-validation law `session.status` follows,
    /// so a typo can never both change state and return an error.
    @Test func shellMustBeAnAbsolutePathOnEverySpawningCommand() async throws {
        // already JSON-encoded: relative, empty, whitespace-only, and an absolute path carrying a newline.
        for cmd in ["session.new", "window.new", "quick"] {
            for shell in [#""fish""#, #""""#, #""  ""#, #""/bin/zsh\nrm -rf /""#] {
                let actions = MockControlActions()
                let dispatcher = ControlDispatcher(actions: actions)

                let response = await dispatcher.dispatch(
                    try request(#"{"cmd":"\#(cmd)","args":{"shell":\#(shell)}}"#))

                #expect(response == ControlResponse(ok: false, error: "invalid shell (expected an absolute path)"),
                        "\(cmd) accepted the shell \(shell)")
                #expect(actions.calls.isEmpty, "\(cmd) reached the host despite the shell \(shell)")
            }
        }
    }

    @Test func shellAcceptsAnAbsolutePath() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextSessionNewResponse = ControlResponse(ok: true, result: ControlResult(id: "fish-session"))

        let response = await dispatcher.dispatch(
            try request(#"{"cmd":"session.new","args":{"shell":"/opt/homebrew/bin/fish"}}"#))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "fish-session")))
        #expect(actions.calls.count == 1, "a valid shell must still reach the host; got \(actions.calls)")
    }
}
