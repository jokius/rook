import Foundation

/// A toggleable window-chrome element in the title bar or the sidebar. Persisted by raw name in
/// `AppSettings.hiddenInterfaceElements`, so an unknown future case in a stored list decodes tolerantly
/// (it is simply dropped) rather than failing the whole decode — the AppSettings forward-compat rule.
/// Every element is shown by default; hiding one adds its raw name to the persisted list.
///
/// rook's title bar has no dashboard button (upstream-only), so that case is deliberately absent — the
/// enum lists only the chrome rook actually draws. The recent-sessions clock IS present (`recentSessions`).
public enum InterfaceElement: String, Codable, Sendable, CaseIterable {
    // title bar
    case sidebarToggle
    case sessionName
    case windowName
    case scratch
    case split
    case quickTerminal
    case recentSessions
    // sidebar
    case newWorkspace
    case newSession
    case flaggedView
    case focusFilter
    case workspaceAddSession

    /// Which chrome surface the element belongs to — the Settings tab groups the toggles by this.
    public enum Section: Sendable { case titleBar, sidebar }

    /// The surface this element lives on: the sidebar for the add/flag/filter controls (the footer buttons
    /// plus the workspace-row add-session "+"), the title bar for everything else.
    public var section: Section {
        switch self {
        case .newWorkspace, .newSession, .flaggedView, .focusFilter, .workspaceAddSession: return .sidebar
        default: return .titleBar
        }
    }

    /// The human-facing toggle label shown in the Interface settings tab.
    public var displayName: String {
        switch self {
        case .sidebarToggle: return "Sidebar toggle"
        case .sessionName: return "Session name"
        case .windowName: return "Window name"
        case .scratch: return "Scratch terminal"
        case .split: return "Split view"
        case .quickTerminal: return "Quick terminal"
        case .recentSessions: return "Recent sessions"
        case .newWorkspace: return "New workspace"
        case .newSession: return "New session"
        case .flaggedView: return "Flagged view"
        case .focusFilter: return "Workspace filter"
        case .workspaceAddSession: return "Workspace add-session"
        }
    }

    /// Which of the two separators in the title bar's trailing button cluster to draw, given how many
    /// visible buttons each of the three groups has (A = recent-sessions + attention, B = scratch + split,
    /// C = dashboard + quick-terminal). A separator sits ONLY where two groups that each still show 2+
    /// buttons meet: `afterA` between A and B, `afterB` between B and C, or — when B is empty — directly
    /// between a full A and a full C. A group reduced to one button flows in without a bracketing separator.
    /// Host-free so the rule is unit-tested without an app host; the view supplies the three counts.
    ///
    /// Ported verbatim from upstream for parity, but rook still gates its divider INLINE rather than
    /// wiring this rule: rook's title bar has the recent-sessions/attention popover group and the
    /// scratch/split + quick-terminal controls, but no dashboard button — so its `countC` (quick) never
    /// reaches 2, which collapses this "2+ on both sides" rule, and rook's convention keeps a divider for a
    /// single-button neighbor (`1+ on both sides`) that this rule would drop. The render site
    /// (`WindowContentView.titlebarTrailingActions`) gates the single popovers↔view-controls divider inline.
    public static func titlebarGroupDividers(countA: Int, countB: Int, countC: Int) -> (afterA: Bool, afterB: Bool) {
        let afterA = countA >= 2 && countB >= 2
        let afterB = (countB >= 2 && countC >= 2) || (countA >= 2 && countC >= 2 && countB == 0)
        return (afterA, afterB)
    }
}
