import Foundation
import Testing
@testable import rookCore

/// dispatcher tests for the `dashboard --mru` open path. They live here rather than in
/// `ControlDispatcherTests.swift` only because that file is near the 2000-line test-file cap; they share its
/// `MockControlActions` (which our fork already keeps in its own files). The other dashboard dispatcher
/// cases (explicit ids, font modes, close, no-capping) stay in `ControlDispatcherTests`.
@MainActor
struct ControlDispatcherDashboardTests {
    @Test func dashboardMruRoutesWithMruTrueAndNoTargets() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let plain = await dispatcher.dispatch(ControlRequest(cmd: .dashboard, args: ControlArgs(mru: true)))
        let autoSized = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(window: "win", autoSize: true, mru: true)))
        let fixed = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(fontSize: 12, mru: true)))

        #expect(plain == ControlResponse(ok: true))
        #expect(autoSized == ControlResponse(ok: true))
        #expect(fixed == ControlResponse(ok: true))
        #expect(actions.calls == [
            .dashboard(targets: [], window: nil, close: false, fontMode: .untouched, mru: true),
            .dashboard(targets: [], window: "win", close: false, fontMode: .auto, mru: true),
            .dashboard(targets: [], window: nil, close: false, fontMode: .fixed(12), mru: true)
        ])
    }

    @Test func dashboardMruRejectsExplicitIdsAndClose() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let withIds = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["a"], mru: true)))
        let withClose = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(close: true, mru: true)))

        #expect(withIds == ControlResponse(
            ok: false, error: "dashboard --mru cannot be combined with explicit session ids"))
        #expect(withClose == ControlResponse(
            ok: false, error: "dashboard --close takes no ids, --mru, or font options"))
        #expect(actions.calls.isEmpty)
    }

    /// Malformed GRAMMAR is hard: it fails the whole command here, before any window is touched. A
    /// well-formed ref that names no live pane is the app's problem and joins the `unresolved` note instead.
    @Test func dashboardRejectsMalformedPaneSuffixBeforeReachingTheApp() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for raw in ["A:lft", "A:primary", "A:scratch", "surface:A:left", ""] {
            let response = await dispatcher.dispatch(ControlRequest(
                cmd: .dashboard, args: ControlArgs(targets: ["ok", raw])))
            #expect(response == ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(raw)' — use <id>, <id>:left, or <id>:right"))
        }
        #expect(actions.calls.isEmpty) // nothing reached the app, so no grid half-opened
    }

    /// Well-formed ids — bare or pane-suffixed — forward VERBATIM: the dispatcher checks the grammar but
    /// leaves resolution (and re-parsing) to the app side, so the raw strings must survive the hop.
    @Test func dashboardForwardsWellFormedPaneRefsVerbatim() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .dashboard, args: ControlArgs(targets: ["A", "B:left", "active:RIGHT"])))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [
            .dashboard(targets: ["A", "B:left", "active:RIGHT"], window: nil, close: false,
                       fontMode: .untouched, mru: false)
        ])
    }
}
