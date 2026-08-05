import Foundation
import Testing
@testable import rookCore

/// The host-free half of `session.overlay.* --pane`: selector parsing, the two exclusivity rejections, and
/// the forwarding into `ControlActions`. The rejections that need a LIVE session (`alreadyOpen`,
/// `paneNotVisible`) belong to `ControlServer` and are covered by `AppStorePaneOverlayTests` instead.
@MainActor
struct ControlDispatcherOverlayPaneTests {
    private func open(_ args: ControlArgs) -> ControlRequest {
        ControlRequest(cmd: .sessionOverlayOpen, target: "s", args: args)
    }

    @Test func openForwardsTheParsedPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true)

        _ = await dispatcher.dispatch(open(ControlArgs(command: "htop", pane: "right")))
        guard case .overlayOpen(_, _, let options) = actions.calls.first else {
            Issue.record("expected an overlayOpen call, got \(actions.calls)")
            return
        }
        #expect(options.pane == .right)
    }

    /// Omitted keeps the session-wide overlay, so every pre-pane caller is unaffected.
    @Test func openWithoutAPaneStaysSessionWide() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true)

        _ = await dispatcher.dispatch(open(ControlArgs(command: "htop")))
        guard case .overlayOpen(_, _, let options) = actions.calls.first else {
            Issue.record("expected an overlayOpen call, got \(actions.calls)")
            return
        }
        #expect(options.pane == nil)
    }

    /// `primary`/`split` are accepted aliases even though the rejection names only `left or right`.
    @Test func openAcceptsThePrimaryAndSplitAliases() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayOpenResponse = ControlResponse(ok: true)

        _ = await dispatcher.dispatch(open(ControlArgs(command: "a", pane: "primary")))
        _ = await dispatcher.dispatch(open(ControlArgs(command: "a", pane: "split")))
        let panes = actions.calls.compactMap { call -> OverlayPane? in
            guard case .overlayOpen(_, _, let options) = call else { return nil }
            return options.pane
        }
        #expect(panes == [.left, .right])
    }

    /// `scratch` parses for `session.status` but has no pane to cover here, so it is a usage error rather
    /// than something the server has to guard.
    @Test func scratchAndGarbageAreRejectedBeforeTheActionRuns() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for raw in ["scratch", "middle", ""] {
            let response = await dispatcher.dispatch(open(ControlArgs(command: "a", pane: raw)))
            #expect(response == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        }
        #expect(actions.calls.isEmpty)
    }

    /// A pane overlay is always full-pane, so the two size arguments cannot be combined.
    @Test func openRejectsAPaneWithASizePercent() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(open(ControlArgs(command: "a", sizePercent: 70, pane: "left")))
        #expect(response == ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict))
        #expect(actions.calls.isEmpty)
    }

    @Test func closeAndResultForwardTheParsedPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextOverlayCloseResponse = ControlResponse(ok: true)
        actions.nextOverlayResultResponse = ControlResponse(ok: true)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayClose, target: "s",
                                                     args: ControlArgs(pane: "left")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResult, target: "s",
                                                     args: ControlArgs(pane: "right")))
        #expect(actions.calls == [
            .overlayClose(target: "s", window: nil, pane: .left),
            .overlayResult(target: "s", window: nil, pane: .right)
        ])
    }

    @Test func closeAndResultRejectABadPane() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for cmd in [Command.sessionOverlayClose, .sessionOverlayResult] {
            let response = await dispatcher.dispatch(ControlRequest(cmd: cmd, target: "s",
                                                                    args: ControlArgs(pane: "scratch")))
            #expect(response == ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        }
        #expect(actions.calls.isEmpty)
    }

    /// Resize refuses ANY `--pane`, valid spelling or not: there is no per-pane size to change.
    @Test func resizeRefusesEveryPaneSpelling() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for raw in ["left", "right", "scratch", "nonsense"] {
            let response = await dispatcher.dispatch(ControlRequest(cmd: .sessionOverlayResize, target: "s",
                                                                    args: ControlArgs(sizePercent: 50, pane: raw)))
            #expect(response == ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported))
        }
        #expect(actions.calls.isEmpty)
    }
}
