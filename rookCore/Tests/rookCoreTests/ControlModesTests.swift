import Foundation
import Testing
@testable import rookCore

struct ControlModesTests {
    @Test func toggleModeDefaultsToToggle() {
        #expect(ControlToggleMode.parse(nil) == .toggle)
        #expect(ControlToggleMode.parse(nil, on: "show", off: "hide") == .toggle)
    }

    @Test func toggleModeParsesDefaultTokens() {
        #expect(ControlToggleMode.parse("on") == .on)
        #expect(ControlToggleMode.parse("off") == .off)
        #expect(ControlToggleMode.parse("toggle") == .toggle)
    }

    @Test func toggleModeParsesCustomTrueFalseTokens() {
        #expect(ControlToggleMode.parse("show", on: "show", off: "hide") == .on)
        #expect(ControlToggleMode.parse("hide", on: "show", off: "hide") == .off)
        #expect(ControlToggleMode.parse("toggle", on: "show", off: "hide") == .toggle)
    }

    @Test func toggleModeRejectsUnknownToken() {
        #expect(ControlToggleMode.parse("yes") == nil)
        #expect(ControlToggleMode.parse("on", on: "show", off: "hide") == nil)
    }

    @Test func toggleModeComputesDesiredValue() {
        #expect(ControlToggleMode.on.desiredValue(current: false))
        #expect(ControlToggleMode.on.desiredValue(current: true))
        #expect(!ControlToggleMode.off.desiredValue(current: false))
        #expect(!ControlToggleMode.off.desiredValue(current: true))
        #expect(ControlToggleMode.toggle.desiredValue(current: false))
        #expect(!ControlToggleMode.toggle.desiredValue(current: true))
    }

    @Test func paneFocusModeDefaultsToOther() {
        #expect(ControlPaneFocusMode.parse(nil) == .toggle)
    }

    @Test func paneFocusModeParsesAliases() {
        #expect(ControlPaneFocusMode.parse("left") == .primary)
        #expect(ControlPaneFocusMode.parse("primary") == .primary)
        #expect(ControlPaneFocusMode.parse("right") == .split)
        #expect(ControlPaneFocusMode.parse("split") == .split)
        #expect(ControlPaneFocusMode.parse("other") == .toggle)
        #expect(ControlPaneFocusMode.parse("toggle") == .toggle)
    }

    @Test func paneFocusModeRejectsUnknownPane() {
        #expect(ControlPaneFocusMode.parse("center") == nil)
    }

    @Test func paneFocusModeComputesTargetPane() {
        #expect(!ControlPaneFocusMode.primary.wantsSplit(currentSplitFocused: false))
        #expect(!ControlPaneFocusMode.primary.wantsSplit(currentSplitFocused: true))
        #expect(ControlPaneFocusMode.split.wantsSplit(currentSplitFocused: false))
        #expect(ControlPaneFocusMode.split.wantsSplit(currentSplitFocused: true))
        #expect(ControlPaneFocusMode.toggle.wantsSplit(currentSplitFocused: false))
        #expect(!ControlPaneFocusMode.toggle.wantsSplit(currentSplitFocused: true))
    }

    @Test func sidebarViewModeParsesModes() {
        #expect(ControlSidebarViewMode.parse(nil) == .toggle)
        #expect(ControlSidebarViewMode.parse("tree") == .tree)
        #expect(ControlSidebarViewMode.parse("flagged") == .flagged)
        #expect(ControlSidebarViewMode.parse("toggle") == .toggle)
        #expect(ControlSidebarViewMode.parse("wide") == nil)
    }

    // MARK: - ControlWorkspaceFocusMode
    //
    // `workspace.focus`'s own vocabulary rather than the shared `ControlToggleMode`, because `add` has no
    // answer for that type's whole contract (`desiredValue(current:)` — it is not a boolean at all). It
    // parses through `RawRepresentable`, so these cases pin the WIRE TOKENS and the four derived message
    // strings the dispatcher and the CLI build from `allCases`.

    @Test func workspaceFocusModeParsesEveryWireToken() {
        #expect(ControlWorkspaceFocusMode(rawValue: "on") == .on)
        #expect(ControlWorkspaceFocusMode(rawValue: "off") == .off)
        #expect(ControlWorkspaceFocusMode(rawValue: "toggle") == .toggle)
        #expect(ControlWorkspaceFocusMode(rawValue: "add") == .add)
        // and no case is spelled something else — the tokens above are the whole vocabulary.
        #expect(ControlWorkspaceFocusMode.allCases.map(\.rawValue) == ["on", "off", "toggle", "add"])
    }

    @Test func workspaceFocusModeDefaultsToToggle() {
        // both the dispatcher (an omitted `args.mode`) and the `rookctl workspace focus` positional default
        // to this token, so the spelling is load-bearing rather than cosmetic.
        #expect(ControlWorkspaceFocusMode.toggle.rawValue == "toggle")
        #expect(ControlWorkspaceFocusMode(rawValue: ControlWorkspaceFocusMode.toggle.rawValue) == .toggle)
    }

    @Test func workspaceFocusModeRejectsUnknownToken() {
        #expect(ControlWorkspaceFocusMode(rawValue: "sideways") == nil)
        #expect(ControlWorkspaceFocusMode(rawValue: "") == nil)
        #expect(ControlWorkspaceFocusMode(rawValue: "On") == nil)
        // `off` IS the remove mode; there is deliberately no separate token for it.
        #expect(ControlWorkspaceFocusMode(rawValue: "remove") == nil)
    }

    @Test func workspaceFocusModeNameListsAreDerivedFromAllCases() {
        // derived, so adding a case cannot leave the dispatcher's rejection message or the CLI's help stale.
        #expect(ControlWorkspaceFocusMode.validNamesList
            == ControlWorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: "|"))
        #expect(ControlWorkspaceFocusMode.validNamesPhrase
            == ControlWorkspaceFocusMode.allCases.map(\.rawValue).joined(separator: ", "))
        // and the current spellings, so a reordering or rename is visible in the diff.
        #expect(ControlWorkspaceFocusMode.validNamesList == "on|off|toggle|add")
        #expect(ControlWorkspaceFocusMode.validNamesPhrase == "on, off, toggle, add")
    }

    @Test func workspaceFocusModeHelpIsDerivedAndEveryClauseNamesTheFilterEffect() {
        #expect(ControlWorkspaceFocusMode.helpPhrase
            == ControlWorkspaceFocusMode.allCases.map(\.helpSummary).joined(separator: ", "))
        for mode in ControlWorkspaceFocusMode.allCases {
            #expect(mode.helpSummary.hasPrefix(mode.rawValue), "help for \(mode.rawValue) must name its token")
            // `add`'s "leaves the flag alone" reads as an unexplained exception unless the others say theirs.
            #expect(mode.helpSummary.contains("filter"), "help for \(mode.rawValue) must name the filter effect")
            #expect(ControlWorkspaceFocusMode.helpPhrase.contains(mode.helpSummary))
        }
    }
}
