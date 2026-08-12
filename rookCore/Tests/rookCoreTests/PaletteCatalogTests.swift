import Testing
@testable import rookCore

struct PaletteCatalogTests {
    @Test func titlesMatchThePaletteSourceOrder() {
        #expect(PaletteCommand.allCases.map(\.title) == [
            "New Session",
            "New Workspace",
            "Open Directory…",
            "Rename Session",
            "Duplicate Session",
            "Rename Workspace",
            "Close Session",
            "Reopen Last Closed Item",
            "Reopen Closed Item",
            "Clear Status",
            "Previous Session",
            "Next Session",
            "Previous Attention Session",
            "Next Attention Session",
            "First Session",
            "Last Session",
            "Show Attention",
            "Toggle Split",
            "Close Split",
            "Toggle Scratch",
            "Toggle Terminal Zoom",
            "Toggle Sidebar",
            "Flag Session",
            "Focus Workspace",
            "Find…",
            "Quick Terminal",
            "Dashboard",
            "Toggle Full Screen",
            "Increase Font Size",
            "Decrease Font Size",
            "Actual Font Size",
            "Select Theme…",
            "Edit Keymap",
            "Reload Keymap",
            "Edit ghostty.conf",
            "Reload Config",
            "Delete Workspace",
            "Show Flagged Sessions",
            "Clear Flagged",
            "Clear Focus",
            "Add Workspace to Focus",
            "Toggle Workspace Filter",
            "Expand Workspaces",
            "Collapse Workspaces",
            "Focus Left Pane",
            "Focus Right Pane",
        ])
    }

    @Test func catalogHasTheExpectedStaticCommandCount() {
        #expect(PaletteCommand.allCases.count == 46)
    }

    @Test func idsRoundTripThroughRawValue() {
        for command in PaletteCommand.allCases {
            #expect(PaletteCommand(rawValue: command.rawValue) == command)
        }
    }

    @Test func contextTitlesMatchToggleState() {
        #expect(PaletteCommand.toggleFlag.title(in: PaletteContext(activeSessionFlagged: false)) == "Flag Session")
        #expect(PaletteCommand.toggleFlag.title(in: PaletteContext(activeSessionFlagged: true)) == "Unflag Session")
        #expect(PaletteCommand.toggleFlaggedView.title(in: PaletteContext(sidebarShowsFlaggedOnly: false)) == "Show Flagged Sessions")
        #expect(PaletteCommand.toggleFlaggedView.title(in: PaletteContext(sidebarShowsFlaggedOnly: true)) == "Show All Sessions")
    }

    @Test func clearFlaggedVisibleOnlyWhenSomethingIsFlagged() {
        #expect(!PaletteCommand.clearFlagged.isVisible(in: PaletteContext(hasFlaggedSessions: false)))
        #expect(PaletteCommand.clearFlagged.isVisible(in: PaletteContext(hasFlaggedSessions: true)))
    }

    @Test func flaggedToggleVisibleWithFlagsOrWhileAlreadyInFlaggedView() {
        #expect(!PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext()))
        #expect(PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext(hasFlaggedSessions: true)))
        #expect(PaletteCommand.toggleFlaggedView.isVisible(in: PaletteContext(sidebarShowsFlaggedOnly: true)))
    }

    @Test func treeExpansionCommandsShowOnlyInWorkspaceTreeMode() {
        #expect(PaletteCommand.expandWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: true)))
        #expect(PaletteCommand.collapseWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: true)))
        #expect(!PaletteCommand.expandWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: false)))
        #expect(!PaletteCommand.collapseWorkspaces.isVisible(in: PaletteContext(sidebarShowsWorkspaceTree: false)))
    }

    @Test func workspaceAndSplitCommandsFollowTheirPredicates() {
        #expect(!PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: false)))
        #expect(PaletteCommand.deleteWorkspace.isVisible(in: PaletteContext(canRemoveWorkspace: true)))
        #expect(!PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: false)))
        #expect(PaletteCommand.clearFocus.isVisible(in: PaletteContext(hasMarkedWorkspaces: true)))
        #expect(!PaletteCommand.focusLeftPane.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.focusRightPane.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
        #expect(!PaletteCommand.closeSplit.isVisible(in: PaletteContext(activeSessionHasSplit: false)))
        #expect(PaletteCommand.closeSplit.isVisible(in: PaletteContext(activeSessionHasSplit: true)))
        #expect(!PaletteCommand.undoClose.isVisible(in: PaletteContext(hasPendingClose: false)))
        #expect(PaletteCommand.undoClose.isVisible(in: PaletteContext(hasPendingClose: true)))
        #expect(!PaletteCommand.reopenRecent.isVisible(in: PaletteContext(hasRecentClosed: false)))
        #expect(PaletteCommand.reopenRecent.isVisible(in: PaletteContext(hasRecentClosed: true)))
    }

    @Test func focusEntriesKeyOnMembershipNotOnTheFilterFlag() {
        // the two focus-set entries hang off the MARKED set, not off whether the filter applies: with
        // nothing marked there is nothing to clear and nothing to filter to, which is the same state the
        // bottom-bar toggle renders disabled in.
        for command in [PaletteCommand.clearFocus, .toggleWorkspaceFilter] {
            #expect(!command.isVisible(in: PaletteContext(hasMarkedWorkspaces: false)),
                    "\(command.rawValue) must hide with nothing marked")
            #expect(command.isVisible(in: PaletteContext(hasMarkedWorkspaces: true)),
                    "\(command.rawValue) must show as soon as something is marked")
        }

        // "Add Workspace to Focus" keys on the OTHER predicate — the current workspace's own membership —
        // so it hides exactly where it would be a silent no-op, and shows even with other workspaces marked.
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(in: PaletteContext(activeWorkspaceMarked: false)))
        #expect(!PaletteCommand.addWorkspaceToFocus.isVisible(in: PaletteContext(activeWorkspaceMarked: true)))
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(
            in: PaletteContext(hasMarkedWorkspaces: true, activeWorkspaceMarked: false)))

        // and it is deliberately NOT gated on the sidebar mode — membership is model state the tree applies
        // the moment it is shown again, exactly like its Clear Focus / Toggle Workspace Filter siblings.
        let flaggedMode = PaletteContext(sidebarShowsWorkspaceTree: false, sidebarShowsFlaggedOnly: true,
                                         hasMarkedWorkspaces: true, activeWorkspaceMarked: false)
        #expect(PaletteCommand.addWorkspaceToFocus.isVisible(in: flaggedMode))
        #expect(PaletteCommand.toggleWorkspaceFilter.isVisible(in: flaggedMode))
        #expect(PaletteCommand.clearFocus.isVisible(in: flaggedMode))
    }

    @Test func builtinMappingsCoverRebindableCommands() {
        #expect(PaletteCommand.newSession.builtinAction == .newSession)
        #expect(PaletteCommand.find.builtinAction == .toggleSearch)
        #expect(PaletteCommand.toggleTerminalZoom.builtinAction == .toggleTerminalZoom)
        #expect(PaletteCommand.resetFontSize.builtinAction == .resetFontSize)
        #expect(PaletteCommand.reopenRecent.builtinAction == .reopenRecent)
        #expect(PaletteCommand.undoClose.builtinAction == .undoClose)
        #expect(PaletteCommand.toggleWorkspaceFilter.builtinAction == .toggleWorkspaceFilter)
        #expect(PaletteCommand.clearFlagged.builtinAction == nil)
        #expect(PaletteCommand.expandWorkspaces.builtinAction == nil)
        // marking the current workspace has no keymap action of its own — it rides the palette/menu only.
        #expect(PaletteCommand.addWorkspaceToFocus.builtinAction == nil)
    }
}
