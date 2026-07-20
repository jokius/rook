import Foundation
import Testing
@testable import rookCore

/// The host-free `InterfaceElement` chrome-visibility rules: the title-bar group-divider boundary table,
/// the tolerant raw-string decode of `AppSettings.hiddenInterfaceElements`, the section partition, and the
/// workspace add-session element.
struct InterfaceElementTests {
    @Test func hiddenInterfaceElementsDefaultsNilAndShowsEverything() {
        let settings = AppSettings()
        #expect(settings.hiddenInterfaceElements == nil)
        #expect(settings.resolvedHiddenInterfaceElements.isEmpty)
        for element in InterfaceElement.allCases {
            #expect(!settings.isInterfaceElementHidden(element))
        }
    }

    @Test func unknownInterfaceElementDecodesTolerantly() throws {
        // a future-written element name must decode tolerantly (the forward-compat rule): the unknown name
        // is dropped from the resolved set, and it must NOT fail the whole decode and discard other fields.
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{ "hiddenInterfaceElements": ["scratch", "teleporter"], "fontSize": 16 }"#.utf8))
        #expect(decoded.fontSize == 16)
        #expect(decoded.resolvedHiddenInterfaceElements == [.scratch])
        #expect(decoded.isInterfaceElementHidden(.scratch))
    }

    @Test func interfaceElementSectionsPartitionAllCases() {
        // every case belongs to exactly one section, and both sections are non-empty — the Settings tab
        // relies on this to group the toggles.
        let titleBar = InterfaceElement.allCases.filter { $0.section == .titleBar }
        let sidebar = InterfaceElement.allCases.filter { $0.section == .sidebar }
        #expect(titleBar.count + sidebar.count == InterfaceElement.allCases.count)
        #expect(sidebar == [.newWorkspace, .newSession, .flaggedView, .workspaceAddSession])
        #expect(!titleBar.isEmpty)
    }

    @Test func workspaceAddSessionIsADistinctSidebarInterfaceElement() {
        // the workspace-row hover "+" is a separate, sidebar-section toggle from the footer newSession button.
        #expect(InterfaceElement.workspaceAddSession.section == .sidebar)
        #expect(InterfaceElement.workspaceAddSession.displayName == "Workspace add-session")
        let hidden = AppSettings(hiddenInterfaceElements: ["workspaceAddSession"])
        #expect(hidden.isInterfaceElementHidden(.workspaceAddSession))
        #expect(!hidden.isInterfaceElementHidden(.newSession)) // hiding one does not hide the other
    }

    @Test(arguments: [
        // (countA, countB, countC, afterA, afterB)
        (1, 2, 2, false, true),  // default: lone recent flows in, one divider between the two full groups
        (1, 1, 2, false, false), // hide a B button: B is a single, no divider anywhere
        (2, 2, 2, true, true),   // all full: both dividers
        (2, 0, 2, false, true),  // empty B: a full A and a full C meet directly
        (2, 1, 2, false, false), // lone B between two full groups: no bridge, no dividers
        (2, 2, 1, true, false),  // lone C: divider only between the two full A/B groups
        (0, 2, 2, false, true),  // empty A: divider only between B and C
        (0, 0, 2, false, false), // only C present: no dividers at the leading edge
        (2, 2, 0, true, false),  // empty C: divider only between A and B
        (0, 0, 0, false, false), // nothing visible
    ])
    func titlebarGroupDividersOnlyBetweenFullGroups(countA: Int, countB: Int, countC: Int,
                                                    afterA: Bool, afterB: Bool) {
        let dividers = InterfaceElement.titlebarGroupDividers(countA: countA, countB: countB, countC: countC)
        #expect(dividers.afterA == afterA)
        #expect(dividers.afterB == afterB)
    }
}
