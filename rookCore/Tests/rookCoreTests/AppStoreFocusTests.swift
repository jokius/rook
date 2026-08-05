import Foundation
import Testing
@testable import rookCore

/// The sidebar focus filter: the MARKED SET (`focusedWorkspaceIDs`), the separate APPLY flag
/// (`focusEnabled`), everything derived from the pair, and the lifecycle guards that keep them in step.
///
/// Its own file because the set model is a contract with several invariants that no single feature owns:
/// `enabled + empty` is unrepresentable, marking never applies, "toggle" has one definition, and the control
/// read-back keeps `focused` (EFFECTIVE) apart from `marked` (MEMBERSHIP). Those tests used to live in
/// `AppStoreTests` (at its 2000-line cap) and `AppStoreOrganizationTests` (which is about moving/reordering,
/// not filtering).
@MainActor
struct AppStoreFocusTests {

    // MARK: - The replacing Focus

    @Test func setFocusedWorkspaceReplacesTheMarkedSetAndAppliesTheFilter() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)

        store.setFocusedWorkspace(a.id)
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)

        store.setFocusedWorkspace(b.id) // the single-workspace zoom REPLACES; it never adds
        #expect(store.focusedWorkspaceIDs == [b.id])
        #expect(store.focusEnabled)

        store.clearFocus()
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    @Test func setFocusedWorkspaceRefusesAnIDNamingNoWorkspace() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")

        store.setFocusedWorkspace(UUID()) // marking a phantom would persist a member no tree can render
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)

        store.setFocusedWorkspace(a.id)
        store.setFocusedWorkspace(UUID()) // ...and must not replace a live focus with one either
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)
    }

    @Test func clearFocusForgetsTheSetSoTheFilterCannotBeReApplied() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        store.setFocusedWorkspace(work.id)

        store.clearFocus() // the menu/palette "Clear Focus" and the clearing half of the replace-toggle
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
        // re-enabling with nothing marked is a clean no-op — there is nothing to filter to.
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func clearFocusAfterACrossSetJumpStillForgetsTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inside.id)
        store.setFocusedWorkspace(work.id)
        store.selectSession(outside.id) // an involuntary jump: the flag drops, the set survives

        // the flag already reads false here, so a mutator that delta-guarded on it alone would early-return
        // and KEEP the set — and `workspace.filter on` would then resurrect a focus the user dismissed.
        store.clearFocus()
        #expect(store.focusedWorkspaceIDs.isEmpty)
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs.isEmpty)
    }

    // MARK: - Membership (I2, I3)

    @Test func markingRefusesAPhantomIDWhileUnMarkingIsNeverGatedOnExistence() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")

        store.setFocusMembership(UUID(), member: true) // a phantom member can never be persisted
        #expect(store.focusedWorkspaceIDs.isEmpty)

        // plant a stale member the way only an outside window could — the mutators cannot produce one, so
        // the stored fields are written directly (`internal(set)`, reachable via `@testable`).
        let stale = UUID()
        store.focusedWorkspaceIDs = [keep.id, stale]
        store.focusEnabled = true

        store.setFocusMembership(stale, member: false) // UN-marking is never gated: a stale id stays removable
        #expect(store.focusedWorkspaceIDs == [keep.id])
        #expect(store.focusEnabled)
    }

    @Test func markingWithTheFilterOffBuildsTheSetWithoutApplyingIt() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")

        // I3, polarity one: an add on an OFF filter leaves it off, so the working set is built row by row
        // with the whole tree still on screen — an add that enabled would hide the rows the next add needs.
        store.setFocusMembership(a.id, member: true)
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id, c.id])

        store.setFocusMembership(c.id, member: true)
        #expect(store.focusedWorkspaceIDs == [a.id, c.id])
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id, c.id])
    }

    @Test func markingWhileTheFilterAppliesLeavesItApplied() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusedWorkspace(a.id)

        // I3, polarity two: an add on an APPLIED filter must not switch it off either — it widens the view.
        store.setFocusMembership(b.id, member: true)
        #expect(store.focusedWorkspaceIDs == [a.id, b.id])
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id])
        _ = c
    }

    @Test func unMarkingDisablesTheFilterOnlyOnceTheSetEmpties() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        store.setFocusedWorkspace(a.id)
        store.setFocusMembership(b.id, member: true)

        store.setFocusMembership(a.id, member: false)
        #expect(store.focusedWorkspaceIDs == [b.id])
        #expect(store.focusEnabled) // one member left: the filter still has something to apply

        store.setFocusMembership(b.id, member: false)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled) // the last member takes the filter with it
    }

    @Test func setFocusEnabledAppliesAHandBuiltSetInOneStepAndLiftingItKeepsTheSet() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusMembership(a.id, member: true)
        store.setFocusMembership(c.id, member: true)
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id, c.id])

        store.setFocusEnabled(true) // ONE call applies the whole hand-built set
        #expect(store.focusedWorkspaceIDs == [a.id, c.id])
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, c.id])

        store.setFocusEnabled(false) // the "come back to it" leg: the set outlives the flag
        #expect(store.focusedWorkspaceIDs == [a.id, c.id])
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id, c.id])
        store.setFocusEnabled(true)
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, c.id])
    }

    // MARK: - `enabled + empty` is unrepresentable (I1)

    @Test func theFilterCanNeverBeAppliedToAnEmptySet() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")

        // every route into the flag refuses an empty set, matching the bottom-bar toggle (disabled there).
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)
        store.applyWorkspaceFilter(.on)
        #expect(!store.focusEnabled)
        store.applyWorkspaceFilter(.toggle)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs.isEmpty)

        // and a set that EMPTIES under an applied filter clamps the flag back off rather than leaving an
        // applied filter with nothing visible.
        store.setFocusedWorkspace(a.id)
        #expect(store.focusEnabled)
        store.setFocusMembership(a.id, member: false)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs.isEmpty)
    }

    @Test func restorePrunesStaleMembersAndClampsTheFlagWithThem() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        store.setFocusedWorkspace(a.id)
        store.setFocusMembership(b.id, member: true)

        let snapshot = store.snapshot()
        #expect(snapshot.focusedWorkspaceIDs == [a.id, b.id]) // TREE order, not the Set's hash order
        #expect(snapshot.focusEnabled == true)

        // a PARTIALLY stale set keeps its survivors and stays applied.
        var partialSnapshot = snapshot
        partialSnapshot.workspaces.removeAll { $0.id == b.id }
        let partial = makeStore()
        partial.restore(from: partialSnapshot)
        #expect(partial.focusedWorkspaceIDs == [a.id])
        #expect(partial.focusEnabled)

        // an ALL-stale set (its workspaces deleted by another window, or a hand-edited file) restores empty
        // AND disabled, so `enabled + empty` cannot sneak in through a restore.
        var staleSnapshot = snapshot
        staleSnapshot.workspaces = []
        let cleared = makeStore()
        cleared.restore(from: staleSnapshot)
        #expect(cleared.focusedWorkspaceIDs.isEmpty)
        #expect(!cleared.focusEnabled)
    }

    // MARK: - Toggle has ONE definition (I6)

    @Test func toggleIsTheReplaceToggleForBothTheGUIAndTheWire() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")

        store.toggleFocusedWorkspace(a.id) // nothing marked: replace with `a` and apply
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)

        store.toggleFocusedWorkspace(b.id) // a DIFFERENT workspace REPLACES — a toggle never adds
        #expect(store.focusedWorkspaceIDs == [b.id])
        #expect(store.focusEnabled)

        store.toggleFocusedWorkspace(b.id) // the sole focused one clears
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)

        // `workspace.focus toggle` routes through the SAME function, so the wire cannot drift from the GUI.
        store.applyFocusMode(.toggle, to: a.id)
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)
        store.applyFocusMode(.toggle, to: a.id)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    @Test func toggleOnAMemberOfAMultiMemberSetReplacesRatherThanUnMarking() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        store.setFocusedWorkspace(a.id)
        store.setFocusMembership(b.id, member: true)

        store.toggleFocusedWorkspace(b.id) // `b` is a member but NOT the sole focus, so this zooms to it
        #expect(store.focusedWorkspaceIDs == [b.id])
        #expect(store.focusEnabled)
    }

    @Test func toggleOnTheOnlyMemberWhileTheFilterIsOffReAppliesItInsteadOfClearing() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        store.setFocusMembership(a.id, member: true) // marked, but the whole tree is on screen

        store.toggleFocusedWorkspace(a.id)
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled) // nothing is zoomed to yet, so the toggle zooms rather than clears
    }

    @Test func toggleOnAnIDNamingNoWorkspaceIsACleanNoOp() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        store.setFocusedWorkspace(a.id)

        store.toggleFocusedWorkspace(UUID())
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)
    }

    // MARK: - applyFocusMode / applyWorkspaceFilter

    @Test func applyFocusModeOnMarksTheTargetAloneAndAppliesTheFilter() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusMembership(a.id, member: true)
        store.setFocusMembership(b.id, member: true)
        #expect(!store.focusEnabled)

        store.applyFocusMode(.on, to: c.id)
        #expect(store.focusedWorkspaceIDs == [c.id])
        #expect(store.focusEnabled)
    }

    @Test func applyFocusModeAddMarksAlongsideAndLeavesTheFlagAloneInBothPolarities() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")

        store.applyFocusMode(.add, to: a.id) // filter OFF stays off
        store.applyFocusMode(.add, to: b.id)
        #expect(store.focusedWorkspaceIDs == [a.id, b.id])
        #expect(!store.focusEnabled)

        store.setFocusEnabled(true)
        store.applyFocusMode(.add, to: c.id) // filter ON stays on
        #expect(store.focusedWorkspaceIDs == [a.id, b.id, c.id])
        #expect(store.focusEnabled)
    }

    @Test func applyFocusModeOffRemovesAMemberAndIsACleanNoOpOnANonMember() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusedWorkspace(a.id)
        store.applyFocusMode(.add, to: b.id)

        store.applyFocusMode(.off, to: c.id) // a NON-member: the set and the flag both stand
        #expect(store.focusedWorkspaceIDs == [a.id, b.id])
        #expect(store.focusEnabled)

        store.applyFocusMode(.off, to: b.id) // `off` IS the remove mode — there is no separate `remove` token
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)

        store.applyFocusMode(.off, to: a.id) // the last member takes the filter with it
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    @Test func applyWorkspaceFilterFlipsTheFlagWithoutForgettingTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inside.id)
        store.setFocusedWorkspace(work.id)
        store.selectSession(outside.id) // an involuntary jump: the flag drops, `work` stays marked

        store.applyWorkspaceFilter(.toggle) // the re-apply leg
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
        store.applyWorkspaceFilter(.on) // idempotent — already on
        #expect(store.focusEnabled)
        store.applyWorkspaceFilter(.off)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id]) // lifting the filter never forgets the set
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func applyWorkspaceFilterIsANoOpWithNothingMarked() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")

        store.applyWorkspaceFilter(.on) // nothing marked — there is nothing to filter to
        #expect(!store.focusEnabled)
        store.applyWorkspaceFilter(.toggle)
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    // MARK: - Idempotence, and a no-op never writes (I4)

    /// True when `body` performed no `save()`. The store's on-disk snapshot is overwritten with a sentinel
    /// first, so only a real write would replace it — every focus field reads live, which makes the file the
    /// one witness that a delta-guarded mutator actually skipped its save.
    private func wroteNothing(in directory: URL, _ body: @MainActor () -> Void) -> Bool {
        let file = directory.appendingPathComponent("workspaces.json")
        let sentinel = Data("{ not json }".utf8)
        try! sentinel.write(to: file)
        body()
        return (try? Data(contentsOf: file)) == sentinel
    }

    @Test func everyFocusMutatorIsIdempotentAndANoOpNeverWrites() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rook-tests-\(UUID().uuidString)")
        let store = AppStore(persistence: PersistenceStore(directory: dir))
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")

        // a two-member APPLIED set: re-asserting any part of it changes nothing and writes nothing.
        store.setFocusedWorkspace(a.id)
        store.setFocusMembership(b.id, member: true)
        let appliedSetIsQuiet = wroteNothing(in: dir) {
            store.setFocusMembership(a.id, member: true)  // already a member
            store.setFocusMembership(c.id, member: false) // never was one
            store.setFocusEnabled(true)                   // already applied
            store.applyWorkspaceFilter(.on)
            store.applyFocusMode(.add, to: b.id)
            store.applyFocusMode(.off, to: c.id)
            store.setFocusedWorkspace(UUID())             // refused, so nothing to persist
            store.toggleFocusedWorkspace(UUID())
        }
        #expect(appliedSetIsQuiet)
        #expect(store.focusedWorkspaceIDs == [a.id, b.id])
        #expect(store.focusEnabled)

        // a SOLE applied focus: re-focusing the same workspace is the same state.
        store.setFocusedWorkspace(a.id)
        let soleFocusIsQuiet = wroteNothing(in: dir) {
            store.setFocusedWorkspace(a.id)
            store.applyFocusMode(.on, to: a.id)
        }
        #expect(soleFocusIsQuiet)
        #expect(store.focusedWorkspaceIDs == [a.id])
        #expect(store.focusEnabled)

        // and the empty/off state, where enabling is refused rather than written.
        store.clearFocus()
        let emptySetIsQuiet = wroteNothing(in: dir) {
            store.clearFocus()
            store.setFocusEnabled(false)
            store.setFocusEnabled(true) // refused on an empty set
            store.applyWorkspaceFilter(.toggle)
        }
        #expect(emptySetIsQuiet)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)
    }

    // MARK: - Derived reads

    @Test func soleFocusedWorkspaceIDNeedsExactlyOneMemberANDAnAppliedFilter() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")

        #expect(store.soleFocusedWorkspaceID == nil) // zero members
        #expect(!store.isSoleFocus(a.id))

        store.setFocusMembership(a.id, member: true) // exactly one member, but the filter is OFF: the whole
        #expect(store.soleFocusedWorkspaceID == nil) // tree is on screen, so the mark names nothing to zoom to
        #expect(!store.isSoleFocus(a.id))

        store.setFocusEnabled(true)
        #expect(store.soleFocusedWorkspaceID == a.id)
        #expect(store.isSoleFocus(a.id))
        #expect(!store.isSoleFocus(b.id))

        store.setFocusMembership(b.id, member: true) // two members give no unambiguous answer
        #expect(store.soleFocusedWorkspaceID == nil)
        #expect(!store.isSoleFocus(a.id))
        #expect(!store.isSoleFocus(b.id))
    }

    @Test func currentWorkspaceFocusFactsFollowTheSelection() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let empty = store.addWorkspace(name: "empty")
        let inWork = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let inOther = store.addSession(toWorkspace: other.id, cwd: "/b")!
        store.selectSession(inWork.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.isCurrentWorkspaceSoleFocus)
        #expect(store.isCurrentWorkspaceFocusMember)

        store.setFocusMembership(other.id, member: true) // still a member, no longer the sole focus
        #expect(!store.isCurrentWorkspaceSoleFocus)
        #expect(store.isCurrentWorkspaceFocusMember)

        // zooming to `other` no longer strands the selection in `work`: the narrowing takes the active
        // session with it, so the CURRENT workspace follows and both facts stay true.
        store.setFocusedWorkspace(other.id)
        #expect(store.selectedSessionID == inOther.id)
        #expect(store.isCurrentWorkspaceSoleFocus)
        #expect(store.isCurrentWorkspaceFocusMember)

        // the one narrowing that CAN leave the current workspace out of the set: an empty one has no
        // session to move to, so the selection stays behind and both facts go false.
        store.setFocusedWorkspace(empty.id)
        #expect(store.selectedSessionID == inOther.id)
        #expect(!store.isCurrentWorkspaceSoleFocus)
        #expect(!store.isCurrentWorkspaceFocusMember)
    }

    @Test func visibleWorkspacesReturnsTheWholeTreeWhileTheFilterIsOff() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
        store.setFocusMembership(personal.id, member: true) // marked, but not applied
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func visibleWorkspacesReturnsTheMembersInTreeOrderForANonContiguousSet() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusMembership(c.id, member: true) // marked out of tree order on purpose
        store.setFocusMembership(a.id, member: true)
        store.setFocusEnabled(true)

        #expect(store.visibleWorkspaces.map(\.id) == [a.id, c.id]) // tree order, not insertion or hash order
        store.moveWorkspace(a.id, at: 2) // -> [b, c, a]
        #expect(store.visibleWorkspaces.map(\.id) == [c.id, a.id]) // it follows the TREE, not the set
        _ = b
    }

    @Test func staleMembersAreIgnoredAndAnAllStaleSetShowsTheWholeTree() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")

        // only reachable by writing the stored fields directly (`internal(set)`); the mutators refuse to
        // create it and `restoreFocus` prunes it, so this is the invariant-violation fallback.
        store.focusedWorkspaceIDs = [a.id, UUID()]
        store.focusEnabled = true
        #expect(store.visibleWorkspaces.map(\.id) == [a.id]) // the survivor filters; the stale id is ignored

        store.focusedWorkspaceIDs = [UUID(), UUID()]
        // the whole tree rather than an empty sidebar: stranding the user with no rows is the worse evil.
        #expect(store.visibleWorkspaces.map(\.id) == [a.id, b.id])
    }

    @Test func flaggedSessionsIgnoreFocusEntirely() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.setFlag(true, forSession: a.id)
        store.setFlag(true, forSession: b.id)

        store.setFocusedWorkspace(work.id) // focus is orthogonal — it must NOT shrink the flagged set
        #expect(store.flaggedSessions.map(\.id) == [a.id, b.id])
        store.setFocusMembership(personal.id, member: true)
        #expect(store.flaggedSessions.map(\.id) == [a.id, b.id])
    }

    // MARK: - The cross-set safety net

    @Test func selectingASessionOutsideTheSetSuspendsTheFilterButKeepsTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inside.id)
        store.setFocusedWorkspace(work.id)

        store.selectSession(outside.id) // a notification reveal / idle auto-follow lands here too
        #expect(!store.focusEnabled)                          // the target is revealed...
        #expect(store.focusedWorkspaceIDs == [work.id])       // ...and the hand-curated set survives
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func aCrossSetJumpKeepsTheSetSoOneToggleBringsTheFilterBack() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let spare = store.addWorkspace(name: "spare")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: spare.id, cwd: "/c")!
        store.selectSession(inside.id)
        store.setFocusedWorkspace(work.id)
        store.setFocusMembership(personal.id, member: true)

        store.selectSession(outside.id)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id]) // BOTH members survive, not just one

        // the snapshot carries the pair, so the set outlives a relaunch too — the flag is simply omitted.
        #expect(store.snapshot().focusedWorkspaceIDs == [work.id, personal.id]) // in tree order
        #expect(store.snapshot().focusEnabled == nil)

        store.setFocusEnabled(true) // one toggle returns to the working set
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, personal.id])
    }

    @Test func selectingASessionInsideTheSetKeepsTheFilterApplied() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inWork = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let inPersonal = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inWork.id)
        store.setFocusedWorkspace(work.id)
        store.setFocusMembership(personal.id, member: true)

        store.selectSession(inPersonal.id) // a jump to ANOTHER member is in-set, so nothing lifts
        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id, personal.id])
        store.selectSession(inWork.id)
        #expect(store.focusEnabled)
    }

    @Test func selectingWhileTheFilterIsOffTouchesNeitherFieldAndSelectingNilNeverLifts() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!

        store.setFocusMembership(work.id, member: true) // marked, filter OFF
        store.selectSession(outside.id)                 // nothing is being filtered, so nothing to reveal
        #expect(store.focusedWorkspaceIDs == [work.id])
        #expect(!store.focusEnabled)

        store.selectSession(a.id)
        store.setFocusEnabled(true)
        store.selectSession(nil) // a deselect reveals nothing, so the filter stands
        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func closingTheLastSessionOfAMemberRevealsTheReselectedTarget() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let only = store.addSession(toWorkspace: work.id, cwd: "/only")!
        _ = store.addSession(toWorkspace: personal.id, cwd: "/other")!
        store.selectSession(only.id)
        store.setFocusedWorkspace(work.id)

        store.closeSession(only.id) // reselects into personal — outside the now-empty marked workspace
        #expect(store.workspace(forSession: store.selectedSessionID!)?.id == personal.id)
        #expect(!store.focusEnabled)                    // the reselected session is revealed...
        #expect(store.focusedWorkspaceIDs == [work.id]) // ...without discarding the set
    }

    @Test func removingAWorkspaceStaysInsideTheMarkedSetRatherThanTakingThePositionalNeighbor() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        let inA = store.addSession(toWorkspace: a.id, cwd: "/a")!
        _ = store.addSession(toWorkspace: b.id, cwd: "/b")!
        let activeInC = store.addSession(toWorkspace: c.id, cwd: "/c")!
        store.selectSession(inA.id)
        store.selectSession(activeInC.id)
        store.setFocusMembership(a.id, member: true)
        store.setFocusMembership(c.id, member: true)
        store.setFocusEnabled(true) // both marked, so the active session is already visible
        #expect(store.selectedSessionID == activeInC.id)

        // the positional walk lands in `b`, which the filter isn't rendering; the visible-set pick stays
        // inside the surviving member `a`, so the filter has no reason to drop.
        store.removeWorkspace(c.id)
        #expect(store.selectedSessionID == inA.id)
        #expect(store.focusedWorkspaceIDs == [a.id] && store.focusEnabled)
    }

    @Test func removingAWorkspaceWithNothingVisibleLeftRevealsThePositionalTarget() {
        let store = makeStore()
        let empty = store.addWorkspace(name: "empty")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        let inB = store.addSession(toWorkspace: b.id, cwd: "/b")!
        let activeInC = store.addSession(toWorkspace: c.id, cwd: "/c")!
        store.selectSession(activeInC.id)
        store.setFocusMembership(empty.id, member: true)
        store.setFocusMembership(c.id, member: true)
        store.setFocusEnabled(true)
        #expect(store.selectedSessionID == activeInC.id)

        // removing `c` leaves the marked set holding only the EMPTY workspace, so nothing is visible and the
        // pick falls through to the positional walk — outside the set, which is what still drops the flag.
        store.removeWorkspace(c.id)
        #expect(store.selectedSessionID == inB.id)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [empty.id]) // only the flag drops; the mark survives
    }

    @Test func addingASessionToANonMemberWorkspaceRevealsIt() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        _ = store.addSession(toWorkspace: work.id, cwd: "/w")!
        store.setFocusedWorkspace(work.id)

        let created = store.addSession(toWorkspace: other.id, cwd: "/o")! // a control add into another workspace
        #expect(store.selectedSessionID == created.id)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func addingASessionInsideAMemberKeepsTheFilterApplied() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.setFocusedWorkspace(work.id)

        let created = store.addSession(toWorkspace: work.id, cwd: "/b")! // the GUI new-session path lands here
        #expect(store.selectedSessionID == created.id)
        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func movingTheActiveSessionOutOfTheSetRevealsIt() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)

        store.moveSession(a.id, toWorkspace: other.id)
        #expect(store.selectedSessionID == a.id)
        #expect(!store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    @Test func movingANonActiveSessionOutOfTheSetKeepsTheFilterApplied() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let other = store.addWorkspace(name: "other")
        let a = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: work.id, cwd: "/b")!
        store.selectSession(a.id)
        store.setFocusedWorkspace(work.id)

        store.moveSession(b.id, toWorkspace: other.id) // the active session never left; the filter must stand
        #expect(store.selectedSessionID == a.id)
        #expect(store.focusEnabled)
        #expect(store.focusedWorkspaceIDs == [work.id])
    }

    // MARK: - The other direction: a narrowing keeps the active session VISIBLE

    @Test func focusingAWorkspaceMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let target = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b"))
        store.selectSession(target.id)
        store.selectSession(outside.id)

        store.setFocusedWorkspace(work.id) // the zoom hides the active session's row
        #expect(store.selectedSessionID == target.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func applyingTheFilterMovesTheSelectionIntoTheVisibleSet() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inSet = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/b"))
        store.selectSession(inSet.id)
        store.selectSession(outside.id)

        store.setFocusMembership(work.id, member: true) // marking alone never applies, so nothing moves yet
        #expect(store.selectedSessionID == outside.id)

        store.setFocusEnabled(true)
        #expect(store.selectedSessionID == inSet.id)
        #expect(store.focusedWorkspaceIDs == [work.id] && store.focusEnabled)
    }

    @Test func unmarkingTheActiveSessionsWorkspaceMovesTheSelectionToASurvivingMember() throws {
        let store = makeStore()
        let staying = store.addWorkspace(name: "staying")
        let leaving = store.addWorkspace(name: "leaving")
        let survivor = try #require(store.addSession(toWorkspace: staying.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: leaving.id, cwd: "/b"))
        store.setFocusMembership(staying.id, member: true)
        store.setFocusMembership(leaving.id, member: true)
        store.setFocusEnabled(true)
        store.selectSession(active.id)

        store.setFocusMembership(leaving.id, member: false)
        #expect(store.selectedSessionID == survivor.id)
        #expect(store.focusedWorkspaceIDs == [staying.id] && store.focusEnabled)
    }

    @Test func switchingToTheFlaggedViewMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let flagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let plain = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: flagged.id)
        store.selectSession(plain.id)

        store.setSidebarMode(.flagged) // the flat list has no row for `plain`
        #expect(store.selectedSessionID == flagged.id)
    }

    @Test func unflaggingTheActiveSessionInFlaggedModeMovesTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: survivor.id)
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.setFlag(false, forSession: active.id) // unflagging IS a narrowing while the flagged view is up
        #expect(store.selectedSessionID == survivor.id)
    }

    @Test func batchUnflaggingTheActiveSessionInFlaggedModeMovesTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let survivor = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        let alsoUnflagged = try #require(store.addSession(toWorkspace: work.id, cwd: "/c", select: false))
        store.setFlag(true, forSessions: [survivor.id, active.id, alsoUnflagged.id])
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.setFlag(false, forSessions: [active.id, alsoUnflagged.id])
        #expect(store.flaggedSessions.map(\.id) == [survivor.id])
        #expect(store.selectedSessionID == survivor.id)
    }

    @Test func switchingToTheFlaggedViewNeverDisablesTheWorkspaceFilter() throws {
        let store = makeStore()
        let marked = store.addWorkspace(name: "marked")
        let other = store.addWorkspace(name: "other")
        let inSet = try #require(store.addSession(toWorkspace: marked.id, cwd: "/a"))
        let flaggedOutside = try #require(store.addSession(toWorkspace: other.id, cwd: "/b", select: false))
        store.setFlag(true, forSession: flaggedOutside.id)
        store.selectSession(inSet.id)
        store.setFocusedWorkspace(marked.id)

        // the flat flagged list is cross-workspace and ignores the marked set, so landing outside it there
        // is not a jump PAST the filter — silently dropping the flag would only be discovered back in tree
        // mode, with the whole tree unexpectedly on screen.
        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == flaggedOutside.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)

        store.setSidebarMode(.tree) // and back: the filter re-applies, so the tree pick is in-set again
        #expect(store.selectedSessionID == inSet.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)
    }

    @Test func theNarrowingReselectPrefersTheMostRecentVisibleSession() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let recent = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/c"))
        store.selectSession(first.id)
        store.selectSession(recent.id)
        store.selectSession(outside.id)

        // MRU, not positional: a filter-off-then-on round trip must land back where the user was.
        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == recent.id)
    }

    @Test func theNarrowingReselectFallsBackToTheFirstVisibleSessionWithoutRecency() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let first = try #require(store.addSession(toWorkspace: work.id, cwd: "/a", select: false))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        let outside = try #require(store.addSession(toWorkspace: personal.id, cwd: "/c"))
        store.selectSession(outside.id)

        store.setFocusedWorkspace(work.id)
        #expect(store.selectedSessionID == first.id)
    }

    @Test func aNarrowingWithNoVisibleSessionLeavesTheSelectionAlone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let empty = store.addWorkspace(name: "empty")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(active.id)

        store.setFocusedWorkspace(empty.id) // there is nowhere to move to; deselecting would leave no terminal
        #expect(store.selectedSessionID == active.id)
    }

    @Test func markingAPopulatedWorkspaceWhileTheFilterShowsAnEmptyOneMovesTheSelection() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let empty = store.addWorkspace(name: "empty")
        let populated = store.addWorkspace(name: "populated")
        let active = try #require(store.addSession(toWorkspace: home.id, cwd: "/a"))
        let target = try #require(store.addSession(toWorkspace: populated.id, cwd: "/b", select: false))
        store.selectSession(target.id)
        store.selectSession(active.id)
        store.setFocusedWorkspace(empty.id)
        #expect(store.selectedSessionID == active.id)

        // the WIDENING leg: the visible set was empty (nothing to move to), and filling it repairs the
        // stranded selection the narrowing had to leave behind.
        store.setFocusMembership(populated.id, member: true)
        #expect(store.selectedSessionID == target.id)
    }

    @Test func flaggingASessionWhileTheFlaggedViewIsEmptyMovesTheSelectionIntoIt() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let other = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)
        #expect(store.selectedSessionID == active.id) // empty flagged list: the selection stays put

        store.setFlag(true, forSession: other.id)
        #expect(store.selectedSessionID == other.id)
    }

    @Test func aBackgroundInsertionIntoAnEmptyVisibleSetDoesNotRepairIt() throws {
        let store = makeStore()
        let home = store.addWorkspace(name: "home")
        let empty = store.addWorkspace(name: "empty")
        let active = try #require(store.addSession(toWorkspace: home.id, cwd: "/a"))
        store.selectSession(active.id)
        store.setFocusedWorkspace(empty.id)

        // a DELIBERATE gap: `session.new --no-select` promises not to touch the selection, and that promise
        // outranks the repair (a script filling a background workspace must not steal the active terminal).
        _ = try #require(store.addSession(toWorkspace: empty.id, cwd: "/b", select: false))
        #expect(store.navigableSessions.count == 1)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func clearingEveryFlagInFlaggedModeLeavesTheSelectionAlone() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)
        store.setSidebarMode(.flagged)

        store.clearFlags() // clearing EVERY flag empties the list, so there is nowhere to move
        #expect(store.flaggedSessions.isEmpty)
        #expect(store.selectedSessionID == active.id)
    }

    @Test func unflaggingInTreeModeDoesNotMoveTheSelection() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        let active = try #require(store.addSession(toWorkspace: work.id, cwd: "/b"))
        store.setFlag(true, forSession: active.id)
        store.selectSession(active.id)

        store.setFlag(false, forSession: active.id) // the tree renders every session; nothing was hidden
        #expect(store.selectedSessionID == active.id)
    }

    @Test func restoreMovesASelectionThatLandsOutsideTheRestoredSet() {
        let store = makeStore()
        let markedSession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/marked")
        let straySession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/stray")
        let marked = WorkspaceSnapshot(id: UUID(), name: "marked", sessions: [markedSession])
        let unmarked = WorkspaceSnapshot(id: UUID(), name: "unmarked", sessions: [straySession])
        store.restore(from: Snapshot(selectedSessionID: straySession.id, workspaces: [marked, unmarked],
                                     focusedWorkspaceIDs: [marked.id], focusEnabled: true))
        #expect(store.selectedSessionID == markedSession.id)
        #expect(store.focusedWorkspaceIDs == [marked.id] && store.focusEnabled)
    }

    @Test func restoreReselectsByRecencyNotByTreeOrder() {
        let store = makeStore()
        let firstInTree = SessionSnapshot(id: UUID(), customName: nil, cwd: "/first")
        let mostRecent = SessionSnapshot(id: UUID(), customName: nil, cwd: "/recent")
        let straySession = SessionSnapshot(id: UUID(), customName: nil, cwd: "/stray")
        let marked = WorkspaceSnapshot(id: UUID(), name: "marked", sessions: [firstInTree, mostRecent])
        let unmarked = WorkspaceSnapshot(id: UUID(), name: "unmarked", sessions: [straySession])
        // the repair runs AFTER the recency stack is re-seeded, or the pick is positional for want of a stack.
        store.restore(from: Snapshot(selectedSessionID: straySession.id, workspaces: [marked, unmarked],
                                     focusedWorkspaceIDs: [marked.id], focusEnabled: true,
                                     sessionRecency: [mostRecent.id, firstInTree.id]))
        #expect(store.selectedSessionID == mostRecent.id)
    }

    // MARK: - Workspace lifecycle

    @Test func addWorkspaceWhileTheFilterAppliesJoinsTheNewWorkspaceToTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: work.id, cwd: "/a")!
        store.setFocusedWorkspace(work.id)

        // the new (empty) workspace must become visible — but by JOINING the set, not by clearing it, so
        // the rest of the working set stays filtered.
        let fresh = store.addWorkspace(name: "fresh")
        #expect(store.focusedWorkspaceIDs == [work.id, fresh.id])
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, fresh.id])
    }

    @Test func addWorkspaceWhileTheFilterIsOffLeavesTheSetAlone() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        store.setFocusMembership(work.id, member: true) // marked, filter OFF

        let fresh = store.addWorkspace(name: "fresh")
        // the whole tree is already on screen, so there is nothing to reveal and the set must not widen
        // behind the user's back.
        #expect(store.focusedWorkspaceIDs == [work.id])
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [work.id, fresh.id])
    }

    @Test func addWorkspaceRevealNewWorkspaceFalseLeavesTheSetUntouched() {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        store.setFocusedWorkspace(one.id)

        // the opt-out a background `session.new --no-select --create-workspace` takes: it must not widen the view.
        let background = store.addWorkspace(name: "background", revealNewWorkspace: false)
        #expect(store.focusedWorkspaceIDs == [one.id])
        #expect(store.focusEnabled)
        #expect(store.workspaces.map(\.id) == [one.id, background.id])
        #expect(store.visibleWorkspaces.map(\.id) == [one.id]) // it exists, but stays behind the filter
    }

    @Test func ensureWorkspaceJoinsOnCreateAndNeverTouchesTheSetWhenReusing() {
        let store = makeStore()
        let one = store.addWorkspace(name: "one")
        store.setFocusedWorkspace(one.id)

        let created = store.ensureWorkspace(named: "two")!
        #expect(store.focusedWorkspaceIDs == [one.id, created.id])
        #expect(store.focusEnabled)

        let reused = store.ensureWorkspace(named: "two")! // reusing an existing workspace creates nothing…
        #expect(reused.id == created.id)
        #expect(store.focusedWorkspaceIDs == [one.id, created.id]) // …so it marks nothing either

        let background = store.ensureWorkspace(named: "bg", revealNewWorkspace: false)!
        #expect(store.focusedWorkspaceIDs == [one.id, created.id])
        #expect(store.visibleWorkspaces.map(\.id) == [one.id, created.id])
        _ = background
    }

    @Test func removingTheLastMarkedWorkspaceDisablesTheFilter() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusedWorkspace(doomed.id)

        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled) // a marked root is gone; the filter goes with the last member
        #expect(store.visibleWorkspaces.map(\.id) == [work.id])
    }

    @Test func removingOneOfSeveralMarkedWorkspacesKeepsTheRestMarkedAndTheFilterApplied() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        let spare = store.addWorkspace(name: "spare")
        store.setFocusedWorkspace(keep.id)
        store.setFocusMembership(doomed.id, member: true)

        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [keep.id])
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [keep.id])
        _ = spare
    }

    @Test func removingANonMemberWorkspaceTouchesNeitherTheSetNorTheFlag() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let doomed = store.addWorkspace(name: "doomed")
        store.setFocusedWorkspace(work.id)

        store.removeWorkspace(doomed.id)
        #expect(store.focusedWorkspaceIDs == [work.id])
        #expect(store.focusEnabled)
    }

    @Test func removingAMarkedWorkspaceWhileTheFilterIsOffStillDropsItFromTheSet() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let spare = store.addWorkspace(name: "spare")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inside.id)
        store.setFocusedWorkspace(work.id)
        store.selectSession(outside.id) // filter off, `work` still marked

        store.removeWorkspace(work.id)
        // the removal prunes the member rather than leaving a dangling id behind, so re-applying the filter
        // can never come back to a workspace that no longer exists.
        #expect(store.focusedWorkspaceIDs.isEmpty)
        store.setFocusEnabled(true)
        #expect(!store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [personal.id, spare.id])
    }

    // MARK: - Restore legs: the membership comes back, the FLAG never does

    @Test func undoingASoftClosedWorkspaceReMarksItWithoutRestoringTheFilterFlag() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.setFocusMembership(doomed.id, member: true) // marked, filter OFF

        store.softRemoveWorkspace(doomed.id, grace: 60)
        #expect(store.focusedWorkspaceIDs.isEmpty)
        #expect(!store.focusEnabled)

        store.undoPendingClose()
        #expect(store.focusedWorkspaceIDs == [doomed.id]) // membership belongs to the closed workspace…
        #expect(!store.focusEnabled)                      // …the FLAG is current-window state, restored by nothing
    }

    @Test func undoingASoftClosedWorkspacePutsItBackIntoAnAppliedSet() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.setFocusedWorkspace(keep.id)
        store.setFocusMembership(doomed.id, member: true)

        store.softRemoveWorkspace(doomed.id, grace: 60)
        #expect(store.focusedWorkspaceIDs == [keep.id])
        #expect(store.focusEnabled)

        store.undoPendingClose()
        #expect(store.focusedWorkspaceIDs == [keep.id, doomed.id])
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id) == [keep.id, doomed.id]) // its row is back on screen
    }

    @Test func undoingASoftClosedEmptyWorkspaceStillReMarksIt() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed") // no sessions at all
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        store.setFocusedWorkspace(keep.id)
        store.setFocusMembership(doomed.id, member: true)

        store.softRemoveWorkspace(doomed.id, grace: 60)
        store.undoPendingClose()
        // an EMPTY workspace has no session to reselect, so the restore returns early — the re-mark has to
        // happen ahead of that, or the undone row would stay filtered out and the undo would look like a no-op.
        #expect(store.focusedWorkspaceIDs == [keep.id, doomed.id])
        #expect(store.visibleWorkspaces.map(\.id) == [keep.id, doomed.id])
    }

    @Test func suspendingTheFilterDuringTheGraceSurvivesTheUndo() {
        let store = makeStore()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.setFocusedWorkspace(keep.id)
        store.setFocusMembership(doomed.id, member: true)

        store.softRemoveWorkspace(doomed.id, grace: 60)
        #expect(store.focusEnabled)
        store.setFocusEnabled(false) // the user clicks the bottom-bar toggle INSIDE the grace window
        #expect(!store.focusEnabled)

        store.undoPendingClose()
        #expect(store.focusedWorkspaceIDs == [keep.id, doomed.id]) // membership is the record's to restore…
        // …but the record is seconds old, and restoring the flag from it would beat the user's most recent
        // explicit action. That is the whole reason the capture is membership-only.
        #expect(!store.focusEnabled)
    }

    @Test func reopenClosedItemReMarksTheWorkspaceWithoutRestoringTheFilterFlag() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.setFocusMembership(doomed.id, member: true) // marked, filter OFF

        store.removeWorkspace(doomed.id) // a HARD close: only the Open Recent record survives it
        #expect(store.focusedWorkspaceIDs.isEmpty)
        let recorded = try #require(recentClosed.load().compactMap(\.workspace).first { $0.snapshot.id == doomed.id })
        #expect(recorded.focusMember == true) // the membership went into the record BEFORE the prune

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [doomed.id])
        #expect(!store.focusEnabled) // one RecentClosedStore is shared by every window; the flag is per-window
    }

    @Test func reopenClosedItemPutsTheWorkspaceBackIntoAnAppliedSet() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let doomed = store.addWorkspace(name: "doomed")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        _ = store.addSession(toWorkspace: doomed.id, cwd: "/d")!
        store.setFocusedWorkspace(keep.id)
        store.setFocusMembership(doomed.id, member: true)
        store.removeWorkspace(doomed.id)
        #expect(store.focusEnabled)

        let item = try #require(recentClosed.load().first { $0.workspace?.snapshot.id == doomed.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [keep.id, doomed.id])
        #expect(store.focusEnabled)
        #expect(store.visibleWorkspaces.map(\.id).contains(doomed.id)) // reopening appends, so only membership is fixed
    }

    @Test func reopeningAWorkspaceClosedBeforeTheFieldExistedRestoresItUnmarked() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        // an entry written before `focusMember` existed decodes as nil, which must read as "not a member"
        // rather than marking a workspace the user never put in the set.
        let legacy = RecentClosedItem(kind: .workspace, title: "legacy", subtitle: "0 sessions",
                                      workspace: RecentClosedWorkspace(
                                        snapshot: WorkspaceSnapshot(id: UUID(), name: "legacy", sessions: []),
                                        selectedSessionID: nil))
        recentClosed.record(legacy)
        store.setFocusedWorkspace(keep.id)

        let item = try #require(recentClosed.load().first { $0.id == legacy.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.focusedWorkspaceIDs == [keep.id])
    }

    @Test func reClosingAWorkspaceRebuiltByASessionUndoKeepsItsFocusMembership() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        let ws = store.addWorkspace(name: "ws")
        _ = store.addSession(toWorkspace: keep.id, cwd: "/k")!
        let s1 = store.addSession(toWorkspace: ws.id, cwd: "/s1")!
        _ = store.addSession(toWorkspace: ws.id, cwd: "/s2")!
        store.setFocusMembership(ws.id, member: true)

        store.softCloseSession(s1.id, grace: 60)
        let sessionClose = try #require(store.pendingCloseSummary?.id)
        store.softRemoveWorkspace(ws.id, grace: 60) // this record is the only copy of the membership
        #expect(store.focusedWorkspaceIDs.isEmpty)

        // undoing the SESSION close rebuilds the missing workspace as a shell holding just s1 — and a shell
        // carries no membership, so the live set still does not hold it.
        store.undoPendingClose(sessionClose)
        #expect(store.workspaces.contains { $0.id == ws.id })
        #expect(store.focusedWorkspaceIDs.isEmpty)

        // closing that shell absorbs the still-pending workspace record; its flag has to win, because the
        // live read is false and the recent-closed entry it overwrites dedupes on the workspace id.
        store.softRemoveWorkspace(ws.id, grace: 60)
        let recorded = try #require(recentClosed.load().compactMap(\.workspace).first { $0.snapshot.id == ws.id })
        #expect(recorded.focusMember == true) // recovery route one: Reopen Closed Item

        store.undoPendingClose()
        #expect(store.focusedWorkspaceIDs == [ws.id]) // recovery route two: the undo
        #expect(!store.focusEnabled)
    }

    // MARK: - Sidebar selection prune

    @Test func workspaceFocusPrunesRowsOutsideTheMarkedSet() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = store.addSession(toWorkspace: ws1.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws2.id, cwd: "/b")!
        store.setSidebarSelection([a.id, b.id])

        store.setFocusedWorkspace(ws2.id)

        #expect(store.sidebarSelectionIDs == [b.id])
        store.clearFocus()
        #expect(store.sidebarSelectionIDs == [b.id],
                "rows hidden by the focus filter must not re-enter the selection when the filter lifts")
        // widening the set back over the hidden row must not resurrect it either.
        store.setFocusedWorkspace(ws2.id)
        store.setFocusMembership(ws1.id, member: true)
        #expect(store.sidebarSelectionIDs == [b.id])
    }

    @Test func sidebarTargetsDropRowsHiddenByModeOrFocus() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "one")
        let ws2 = store.addWorkspace(name: "two")
        let a = store.addSession(toWorkspace: ws1.id, cwd: "/a")!
        let b = store.addSession(toWorkspace: ws1.id, cwd: "/b")!
        let c = store.addSession(toWorkspace: ws2.id, cwd: "/c")!
        store.setFlag(true, forSession: a.id)

        store.selectSession(a.id)
        store.setSidebarSelection([a.id, b.id, c.id])
        store.setSidebarMode(.flagged)

        #expect(store.sidebarSelectionIDs == [a.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id])

        store.setSidebarMode(.tree)
        store.selectSession(a.id)
        store.setSidebarSelection([a.id, c.id])
        store.setFocusedWorkspace(ws1.id)

        #expect(store.sidebarSelectionIDs == [a.id])
        #expect(store.sidebarSelectionTargets(forContextSession: a.id) == [a.id])
    }

    // MARK: - The control read-back: `focused` and `marked` are DIFFERENT fields

    @Test func controlTreeReportsFocusedOnlyForTheWorkspacesTheFilterApplies() {
        let store = makeStore()
        let ws1 = store.addWorkspace(name: "first")
        let ws2 = store.addWorkspace(name: "second")
        // no focus: no workspace node reports focused.
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
        // focus the second workspace: ONLY its node reports focused == true (distinct from active).
        store.setFocusedWorkspace(ws2.id)
        let nodes = store.controlTree().workspaces
        #expect(nodes.first { $0.id == ws2.id.uuidString }?.focused == true)
        #expect(nodes.first { $0.id == ws1.id.uuidString }?.focused == nil)
        // clearing focus: no node reports focused again.
        store.clearFocus()
        #expect(store.controlTree().workspaces.allSatisfy { $0.focused == nil })
    }

    @Test func controlTreeReportsTheMarkAndTheFilterSeparately() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let personal = store.addWorkspace(name: "personal")
        let inside = store.addSession(toWorkspace: work.id, cwd: "/a")!
        let outside = store.addSession(toWorkspace: personal.id, cwd: "/b")!
        store.selectSession(inside.id)
        func node() -> ControlWorkspaceNode? {
            store.controlTree().workspaces.first { $0.id == work.id.uuidString }
        }

        #expect(node()?.marked == nil)
        #expect(store.controlTree().workspaceFilter == false)
        store.setFocusedWorkspace(work.id)
        #expect(node()?.marked == true)
        #expect(node()?.focused == true)
        #expect(store.controlTree().workspaceFilter == true)

        store.selectSession(outside.id) // involuntary jump: marked but no longer filtering...
        #expect(node()?.marked == true)   // ...which is readable ONLY because `marked` is reported
        #expect(node()?.focused == nil)   // `focused` keeps meaning EFFECTIVE focus, as it always did
        #expect(store.controlTree().workspaceFilter == false)

        store.clearFocus() // an EXPLICIT clear forgets the membership too
        #expect(node()?.marked == nil)
    }

    @Test func controlTreeReportsEveryMemberOfAMultiMemberSetAndKeepsTheThreeFieldsInStep() {
        let store = makeStore()
        let a = store.addWorkspace(name: "a")
        let b = store.addWorkspace(name: "b")
        let c = store.addWorkspace(name: "c")
        store.setFocusedWorkspace(a.id)
        store.setFocusMembership(b.id, member: true)
        func node(_ id: UUID) -> ControlWorkspaceNode? {
            store.controlTree().workspaces.first { $0.id == id.uuidString }
        }

        // TWO members with the filter on: `focused` is no longer a single-node property.
        #expect(node(a.id)?.focused == true)
        #expect(node(b.id)?.focused == true)
        #expect(node(a.id)?.marked == true)
        #expect(node(b.id)?.marked == true)
        #expect(node(c.id)?.focused == nil) // both fields are OMITTED when false, never reported as `false`
        #expect(node(c.id)?.marked == nil)
        #expect(store.controlTree().workspaceFilter == true)

        store.setFocusEnabled(false) // the filter lifts; the membership does not
        #expect(node(a.id)?.marked == true)
        #expect(node(b.id)?.marked == true)
        #expect(node(a.id)?.focused == nil)
        #expect(node(b.id)?.focused == nil)
        #expect(store.controlTree().workspaceFilter == false)

        // the frozen invariant, checked over the whole tree in BOTH flag states: a future "simplification"
        // that folds `focused` into membership (upstream's shape) breaks every record-then-restore script.
        for enabled in [true, false] {
            store.setFocusEnabled(enabled)
            let tree = store.controlTree()
            for workspace in tree.workspaces {
                #expect((workspace.focused == true) == ((workspace.marked == true) && tree.workspaceFilter == true))
            }
        }
    }
}
