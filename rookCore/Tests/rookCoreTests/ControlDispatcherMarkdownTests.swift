import Foundation
import Testing
@testable import rookCore

/// `session.markdown` dispatcher routing + the host-free validation it owns (mode parse, "open needs a
/// path"). The FS check (exists, not a directory) is app-side and lives in `ControlServer+Markdown`.
///
/// Lives beside `ControlDispatcherTests` (whose `MockControlActions` it reuses, including this command's
/// witness below) rather than inside it — that file is at the 2000-line test budget.
@MainActor
struct ControlDispatcherMarkdownTests {
    @Test func markdownRoutesParsedModeAndPath() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let open = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMarkdown,
            target: "session",
            args: ControlArgs(mode: "open", window: "win", path: "/proj/PLAN.md")
        ))
        let close = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMarkdown,
            target: "session",
            args: ControlArgs(mode: "close")
        ))
        let toggle = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMarkdown,
            target: "session",
            args: ControlArgs(mode: "toggle", path: "docs/notes.md")
        ))
        // no mode at all = toggle with nothing to show (the menu/keybind form: close an open panel).
        let bare = await dispatcher.dispatch(ControlRequest(cmd: .sessionMarkdown, args: ControlArgs()))

        #expect(open == ControlResponse(ok: true))
        #expect(close == ControlResponse(ok: true))
        #expect(toggle == ControlResponse(ok: true))
        #expect(bare == ControlResponse(ok: true))
        #expect(actions.calls == [
            .sessionMarkdown(target: "session", window: "win", .on, path: "/proj/PLAN.md"),
            .sessionMarkdown(target: "session", window: nil, .off, path: nil),
            .sessionMarkdown(target: "session", window: nil, .toggle, path: "docs/notes.md"),
            .sessionMarkdown(target: nil, window: nil, .toggle, path: nil)
        ])
    }

    @Test func markdownOpenRequiresAPath() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .sessionMarkdown, args: ControlArgs(mode: "open")))
        let blank = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMarkdown,
            args: ControlArgs(mode: "open", path: "   ")
        ))

        #expect(missing == ControlResponse(ok: false, error: "session.markdown open requires a path"))
        #expect(blank == ControlResponse(ok: false, error: "session.markdown open requires a path"))
        #expect(actions.calls.isEmpty)
    }

    @Test func markdownRejectsUnknownMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .sessionMarkdown,
            args: ControlArgs(mode: "reroot", path: "/proj/PLAN.md")
        ))

        #expect(response == ControlResponse(ok: false, error: "invalid markdown mode: reroot"))
        #expect(actions.calls.isEmpty)
    }
}

extension MockControlActions {
    func markdownSession(_ target: String?, window: String?, mode: ControlToggleMode,
                         path: String?) -> ControlResponse {
        calls.append(.sessionMarkdown(target: target, window: window, mode, path: path))
        return ControlResponse(ok: true)
    }
}
