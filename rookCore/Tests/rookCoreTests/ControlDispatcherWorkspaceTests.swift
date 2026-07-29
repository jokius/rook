import Foundation
import Testing
@testable import rookCore

/// The `workspace.*` half of the dispatcher suite, split out of `ControlDispatcherTests` (which sits at the
/// test-file size budget) when the multi-workspace focus set arrived with its own end-to-end cases.
///
/// Two kinds of test live here. The ROUTING ones assert what reached the host — the dispatcher parsed the
/// wire token, and a rejected argument never called the host at all. The END-TO-END ones attach a live
/// `AppStore` to the mock (`MockControlActions.store`) and assert the resulting focus state, because a
/// mode's MEANING cannot be pinned by a double: a test that only checks `.workspaceFocus(…, .add)` was
/// recorded proves the token travelled, not that `add` marks without applying the filter.
@MainActor
struct ControlDispatcherWorkspaceTests {
    @Test func workspaceCommandsRouteThroughActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let created = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceNew,
            args: ControlArgs(name: "api", window: "win")
        ))
        let selected = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceSelect,
            target: "workspace",
            args: ControlArgs(window: "win")
        ))
        let renamed = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceRename,
            target: "workspace",
            args: ControlArgs(name: "  renamed  ")
        ))
        let deleted = await dispatcher.dispatch(ControlRequest(cmd: .workspaceDelete, target: "workspace"))

        #expect(created == ControlResponse(ok: true))
        #expect(selected == ControlResponse(ok: true))
        #expect(renamed == ControlResponse(ok: true))
        #expect(deleted == ControlResponse(ok: true))
        #expect(actions.calls == [
            .workspaceNew(window: "win", "api", collapsed: false),
            .workspaceSelect(target: "workspace", window: "win"),
            .workspaceRename(target: "workspace", window: nil, "renamed"),
            .workspaceDelete(target: "workspace", window: nil)
        ])
    }

    @Test func workspaceRenameRejectsMissingOrBlankNameWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let missing = await dispatcher.dispatch(ControlRequest(cmd: .workspaceRename, target: "workspace"))
        let blank = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceRename,
            target: "workspace",
            args: ControlArgs(name: "   ")
        ))

        #expect(missing == ControlResponse(ok: false, error: "workspace.rename requires a name"))
        #expect(blank == ControlResponse(ok: false, error: "workspace.rename requires a name"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceMoveRoutesDirectionAndRejectsInvalidForms() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let moved = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(window: "win", to: "bottom")
        ))
        let missing = await dispatcher.dispatch(ControlRequest(cmd: .workspaceMove, target: "workspace"))
        let bad = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceMove,
            target: "workspace",
            args: ControlArgs(to: "sideways")
        ))

        #expect(moved == ControlResponse(ok: true))
        #expect(missing == ControlResponse(ok: false, error: "workspace.move requires --to"))
        #expect(bad == ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom"))
        #expect(actions.calls == [.workspaceMove(target: "workspace", window: "win", .bottom)])
    }

    @Test func workspaceFilterParsesModeAndRoutesWindowOnly() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let on = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFilter, args: ControlArgs(mode: "on", window: "win")
        ))
        // a target is meaningless here (the filter is window-scoped) and must not reach the host.
        let defaulted = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, target: "workspace"))

        #expect(on == ControlResponse(ok: true))
        #expect(defaulted == ControlResponse(ok: true))
        #expect(actions.calls == [
            .workspaceFilter(window: "win", mode: .on),
            .workspaceFilter(window: nil, mode: .toggle) // an omitted mode defaults to toggle
        ])
    }

    @Test func workspaceFilterRejectsUnknownModeBeforeTheHostRuns() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bad = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "sideways")))

        #expect(bad == ControlResponse(ok: false, error: "invalid workspace filter mode: sideways"))
        #expect(actions.calls.isEmpty) // rejected at the boundary, so it can never half-apply
    }

    @Test func workspaceCollapseAndExpandRouteExpandedFlag() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let collapsed = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceCollapse, target: "workspace", args: ControlArgs(window: "win")
        ))
        let expanded = await dispatcher.dispatch(ControlRequest(cmd: .workspaceExpand, target: "active"))

        #expect(collapsed == ControlResponse(ok: true))
        #expect(expanded == ControlResponse(ok: true))
        #expect(actions.calls == [
            .workspaceExpansion(target: "workspace", window: "win", expanded: false),
            .workspaceExpansion(target: "active", window: nil, expanded: true)
        ])
    }

    @Test func workspaceNewRoutesCollapsedFlag() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let created = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceNew, args: ControlArgs(name: "api", collapsed: true, window: "win")
        ))

        #expect(created == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceNew(window: "win", "api", collapsed: true)])
    }

    @Test func workspaceColorPassesValidHexThrough() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let colored = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceColor,
            target: "workspace",
            args: ControlArgs(window: "win", color: "#ff8800")
        ))

        #expect(colored == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceColor(target: "workspace", window: "win", hex: "#ff8800")])
    }

    @Test func workspaceColorClearsOnClearAndOnMissingColor() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceColor, target: "a", args: ControlArgs(color: "clear")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceColor, target: "b"))

        #expect(actions.calls == [.workspaceColor(target: "a", window: nil, hex: nil),
                                  .workspaceColor(target: "b", window: nil, hex: nil)])
    }

    @Test func workspaceColorRejectsMalformedHexWithoutMutating() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let rejected = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceColor,
            target: "workspace",
            args: ControlArgs(color: "orange")
        ))

        #expect(rejected == ControlResponse(ok: false, error: "invalid color (expected #rrggbb)"))
        #expect(actions.calls.isEmpty) // a bad color must leave the workspace untouched
    }

    @Test func workspaceRootPassesPathThrough() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let set = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceRoot,
            target: "workspace",
            args: ControlArgs(window: "win", path: "/Users/me/proj")
        ))

        #expect(set == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceRoot(target: "workspace", window: "win", path: "/Users/me/proj")])
    }

    @Test func workspaceRootClearsOnClearAndOnMissingPath() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceRoot, target: "a", args: ControlArgs(path: "clear")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceRoot, target: "b"))

        #expect(actions.calls == [.workspaceRoot(target: "a", window: nil, path: nil),
                                  .workspaceRoot(target: "b", window: nil, path: nil)])
    }

    @Test func workspaceIconClassifiesSymbolEmojiAndPath() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "a",
                                                     args: ControlArgs(icon: "hammer.fill")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "b", args: ControlArgs(icon: "🚀")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "c",
                                                     args: ControlArgs(icon: "/icons/rocket.svg")))
        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "d", args: ControlArgs(icon: "clear")))

        #expect(actions.calls == [
            .workspaceIcon(target: "a", window: nil, icon: WorkspaceIcon(kind: .symbol, value: "hammer.fill")),
            .workspaceIcon(target: "b", window: nil, icon: WorkspaceIcon(kind: .emoji, value: "🚀")),
            .workspaceIcon(target: "c", window: nil, icon: WorkspaceIcon(kind: .image, value: "/icons/rocket.svg")),
            .workspaceIcon(target: "d", window: nil, icon: nil), // `clear` restores the default glyph
        ])
    }

    @Test func workspaceIconRejectsUnsupportedImageWithoutMutating() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let rejected = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "a",
                                                                args: ControlArgs(icon: "/icons/logo.gif")))
        #expect(rejected == ControlResponse(ok: false, error: "unsupported icon image (svg, png, or jpeg)"))

        // a control character in the path is rejected too (the shared watermark path check)
        let poisoned = await dispatcher.dispatch(ControlRequest(cmd: .workspaceIcon, target: "a",
                                                                args: ControlArgs(icon: "/icons/evil\n.svg")))
        #expect(poisoned?.ok == false)
        #expect(actions.calls.isEmpty, "a rejected icon must leave the workspace untouched")
    }

    // MARK: - workspace.focus: the four modes, parsed here rather than host-side

    @Test func workspaceFocusParsesEveryModeAndDefaultsToToggle() async {
        // driven off `allCases`, so a new mode cannot be added without the dispatcher routing it.
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        for mode in ControlWorkspaceFocusMode.allCases {
            let response = await dispatcher.dispatch(ControlRequest(
                cmd: .workspaceFocus, target: "workspace",
                args: ControlArgs(mode: mode.rawValue, window: "win")
            ))
            #expect(response == ControlResponse(ok: true), "mode \(mode.rawValue) must reach the host")
        }
        // an omitted mode is `toggle`: the dispatcher supplies the default, so the host never sees a nil.
        let defaulted = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, target: "workspace"))

        #expect(defaulted == ControlResponse(ok: true))
        var expected: [MockControlActions.Call] = ControlWorkspaceFocusMode.allCases.map {
            MockControlActions.Call.workspaceFocus(target: "workspace", window: "win", $0)
        }
        expected.append(.workspaceFocus(target: "workspace", window: nil, .toggle))
        #expect(actions.calls == expected)
    }

    @Test func workspaceFocusRejectsUnknownModeBeforeTheHostRuns() async {
        // replaces the old host-side-validation routing test: the mode is a typed enum on the
        // `ControlActions` boundary now, so an unparseable token is rejected before the host can half-apply.
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let bad = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "workspace", args: ControlArgs(mode: "sideways")
        ))

        #expect(bad == ControlResponse(ok: false, error: "invalid focus mode: sideways (on|off|toggle|add)"))
        #expect(actions.calls.isEmpty)
    }

    // MARK: - workspace.focus / workspace.filter end to end, against a LIVE store

    /// A dispatcher whose host drives a real two-workspace `AppStore` (`MockControlActions.store`), so a
    /// mode's MEANING is asserted on the resulting focus state instead of on what the double recorded.
    /// Every case goes through `dispatch`, covering the wire-token parse and the store mutator in one pass.
    @MainActor
    private struct Live {
        let dispatcher: ControlDispatcher
        let store: AppStore
        let work: Workspace
        let personal: Workspace

        init() {
            let appStore = makeStore()
            let actions = MockControlActions()
            actions.store = appStore
            work = appStore.addWorkspace(name: "work")
            personal = appStore.addWorkspace(name: "personal")
            store = appStore
            dispatcher = ControlDispatcher(actions: actions)
        }

        @discardableResult
        func focus(_ id: UUID, _ mode: String) async -> ControlResponse? {
            await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, target: id.uuidString,
                                                     args: ControlArgs(mode: mode)))
        }

        @discardableResult
        func filter(_ mode: String) async -> ControlResponse? {
            await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: mode)))
        }
    }

    @Test func workspaceFocusOnReplacesTheMarkedSetAndAppliesTheFilter() async {
        let live = Live()

        await live.focus(live.work.id, "add")
        await live.focus(live.personal.id, "on")

        #expect(live.store.focusedWorkspaceIDs == [live.personal.id],
                "`on` REPLACES the set, it does not join it")
        #expect(live.store.focusEnabled)
        #expect(live.store.soleFocusedWorkspaceID == live.personal.id)
    }

    @Test func workspaceFocusAddNeverAppliesTheFilterInEitherPolarity() async {
        let live = Live()

        // filter OFF: marking builds the working set with the whole tree still on screen.
        await live.focus(live.work.id, "add")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id])
        #expect(!live.store.focusEnabled, "an add must not switch the filter on")

        // filter ON: marking widens the set and leaves the flag exactly as it was.
        await live.filter("on")
        #expect(live.store.focusEnabled)
        await live.focus(live.personal.id, "add")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id, live.personal.id])
        #expect(live.store.focusEnabled, "an add must not switch the filter off either")
        #expect(live.store.visibleWorkspaces.map(\.id) == [live.work.id, live.personal.id],
                "the members render in TREE order")
    }

    @Test func workspaceFocusOffRemovesTheMemberAndDisablesAsTheSetEmpties() async {
        let live = Live()

        await live.focus(live.work.id, "on")
        await live.focus(live.personal.id, "add")
        await live.focus(live.personal.id, "off")

        #expect(live.store.focusedWorkspaceIDs == [live.work.id],
                "`off` is the REMOVE mode — there is deliberately no separate token")
        #expect(live.store.focusEnabled, "the filter survives while a member is left")

        await live.focus(live.work.id, "off")

        #expect(live.store.focusedWorkspaceIDs.isEmpty)
        #expect(!live.store.focusEnabled, "`enabled + empty` is unrepresentable, so emptying disables")
    }

    @Test func workspaceFocusToggleIsTheReplaceToggle() async {
        let live = Live()

        await live.focus(live.work.id, "toggle")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id], "nothing marked yet, so toggle marks it")
        #expect(live.store.focusEnabled)

        await live.focus(live.personal.id, "toggle")
        #expect(live.store.focusedWorkspaceIDs == [live.personal.id], "a DIFFERENT workspace replaces the set")
        #expect(live.store.focusEnabled)

        await live.focus(live.personal.id, "toggle")
        #expect(live.store.focusedWorkspaceIDs.isEmpty, "the sole focused workspace clears")
        #expect(!live.store.focusEnabled)
    }

    @Test func workspaceFocusModesAreIdempotent() async {
        let live = Live()

        await live.focus(live.work.id, "on")
        await live.focus(live.work.id, "on")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id])
        #expect(live.store.focusEnabled)

        await live.focus(live.work.id, "add")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id], "re-adding a member changes nothing")
        #expect(live.store.focusEnabled)

        await live.focus(live.work.id, "off")
        await live.focus(live.work.id, "off")
        #expect(live.store.focusedWorkspaceIDs.isEmpty)
        #expect(!live.store.focusEnabled)
    }

    @Test func workspaceFilterOnWithNothingMarkedLeavesTheFilterOff() async {
        let live = Live()

        let on = await live.filter("on")

        #expect(on == ControlResponse(ok: true), "a clean no-op, not an error — nothing to filter to")
        #expect(!live.store.focusEnabled, "enabling an EMPTY set is refused, so the read-back cannot lie")
        #expect(live.store.focusedWorkspaceIDs.isEmpty)
    }

    @Test func workspaceFilterFlipsTheFlagWithoutTouchingTheMarkedSet() async {
        let live = Live()
        await live.focus(live.work.id, "add")

        await live.filter("toggle")
        #expect(live.store.focusEnabled)
        #expect(live.store.focusedWorkspaceIDs == [live.work.id])

        await live.filter("off")
        #expect(!live.store.focusEnabled)
        #expect(live.store.focusedWorkspaceIDs == [live.work.id], "`off` lifts the filter and KEEPS the set")

        await live.filter("on")
        #expect(live.store.focusEnabled, "which is what re-applies a filter an involuntary jump dropped")
        #expect(live.store.focusedWorkspaceIDs == [live.work.id])
    }
}
