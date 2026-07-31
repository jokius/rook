import Foundation

/// Parsed binary control mode with the shared default/toggle semantics used by mode-bearing commands.
public enum ControlToggleMode: Equatable, Sendable {
    case on
    case off
    case toggle

    /// Parse a mode string, defaulting nil to `toggle`. Callers keep their command-specific tokens and
    /// error strings by choosing the true/false spellings they already expose on the wire.
    public static func parse(_ mode: String?, on onToken: String = "on", off offToken: String = "off") -> ControlToggleMode? {
        let value = mode ?? "toggle"
        if value == onToken { return .on }
        if value == offToken { return .off }
        if value == "toggle" { return .toggle }
        return nil
    }

    public func desiredValue(current: Bool) -> Bool {
        switch self {
        case .on: return true
        case .off: return false
        case .toggle: return !current
        }
    }
}

/// Parsed pane selector for `session.focus`, including the default/toggle aliases.
public enum ControlPaneFocusMode: Equatable, Sendable {
    case primary
    case split
    case toggle

    public static func parse(_ pane: String?) -> ControlPaneFocusMode? {
        switch pane ?? "other" {
        case "left", "primary": return .primary
        case "right", "split": return .split
        case "other", "toggle": return .toggle
        default: return nil
        }
    }

    public func wantsSplit(currentSplitFocused: Bool) -> Bool {
        switch self {
        case .primary: return false
        case .split: return true
        case .toggle: return !currentSplitFocused
        }
    }
}

/// Parsed view mode for `sidebar.mode`.
public enum ControlSidebarViewMode: Equatable, Sendable {
    case tree
    case flagged
    case toggle

    public static func parse(_ mode: String?) -> ControlSidebarViewMode? {
        switch mode ?? "toggle" {
        case "tree": return .tree
        case "flagged": return .flagged
        case "toggle": return .toggle
        default: return nil
        }
    }
}

/// The four modes `workspace.focus` accepts: `on` replaces the marked set with the target and enables
/// the filter, `off` REMOVES the target from the set (disabling the filter once the set empties — it is
/// the "remove" mode, which is why there is deliberately no separate `remove` token), `toggle`
/// replace-toggles (clears when the set is exactly the target and the filter applies, else replaces the
/// set with the target and enables), and `add` inserts the target WITHOUT touching the filter flag —
/// marking alone, so a set can be built member by member with the whole tree still on screen (an add that
/// enabled the filter would collapse the tree onto the first member and hide the rows the next add needs).
/// There is deliberately NO membership-toggle mode: the sidebar row's membership item computes its own
/// direction from what it just read and maps to `add` or `off`. Raw values are the wire tokens.
///
/// This is `workspace.focus`'s own vocabulary rather than the shared `ControlToggleMode` because `add` has
/// no answer for that type's whole contract, `desiredValue(current:)` — it is not a boolean at all.
public enum ControlWorkspaceFocusMode: String, CaseIterable, Equatable, Sendable {
    case on, off, toggle, add

    /// The accepted names pipe-joined (`on|off|toggle|add`) — the compact form the dispatcher's rejection
    /// message uses. Derived from `allCases`, like `StatusShape.validNamesList`, so no message can go
    /// stale when the set changes.
    public static var validNamesList: String { validNames.joined(separator: "|") }

    /// The accepted names comma-joined (`on, off, toggle, add`) — the prose form the `rookctl workspace
    /// focus` local rejection message uses.
    public static var validNamesPhrase: String { validNames.joined(separator: ", ") }

    /// What this mode does to the marked set AND to the filter flag, in one clause — the building block of
    /// the `rookctl workspace focus` argument help, so that help cannot go stale when a case is added (the
    /// `StatusShape.validNamesPhrase`-builds-its-own-help precedent). Every clause names the filter effect,
    /// since `add`'s "leaves the flag alone" reads as an unexplained exception unless the others say theirs.
    public var helpSummary: String {
        switch self {
        case .on: return "on (mark it alone and apply the filter)"
        case .off: return "off (unmark it; the filter switches off as the set empties)"
        case .toggle:
            return "toggle (replace-toggle and apply the filter, the default; "
                + "clears when it is the only marked one AND the filter is applied)"
        case .add: return "add (mark it alongside the others, leaving the filter flag alone)"
        }
    }

    /// Every mode's `helpSummary`, comma-joined — the whole `--help` sentence, derived from `allCases`.
    public static var helpPhrase: String { allCases.map(\.helpSummary).joined(separator: ", ") }

    private static var validNames: [String] { allCases.map(\.rawValue) }
}

/// The mutually exclusive move forms accepted by `session.move`.
public enum ControlSessionMove: Equatable, Sendable {
    case reorder(ReorderDirection)
    case workspace(String)
    /// Relocate + position relative to an anchor session (id / prefix / `active`). `after == false`
    /// places before the anchor. The anchor carries its own workspace, so this form self-identifies the
    /// destination and never reads the workspace parameter.
    case place(anchor: String, after: Bool)
}

/// Parsed resize request for `session.resize`.
public enum ControlSplitResize: Equatable, Sendable {
    case ratio(Double)
    case delta(Double)
}

/// Host-facing `session.new` options after dispatcher-level guard validation.
public struct ControlSessionCreateOptions: Equatable, Sendable {
    public let window: String?
    public let cwd: String?
    public let workspace: String?
    public let workspaceName: String?
    public let createWorkspace: Bool?
    public let command: String?
    /// Whether a `--command` session HOLDS its surface after the command exits (`--wait`) instead of
    /// closing immediately. Meaningful only with `command`; the dispatcher rejects `--wait` without a
    /// `--command`.
    public let wait: Bool?
    public let name: String?
    /// Anchor session to place the new session right AFTER (id / prefix / `active`); the anchor carries
    /// its own workspace, so this bypasses `workspace`/`workspaceName`. Mutually exclusive with `before`.
    public let after: String?
    /// Anchor session to place the new session right BEFORE, the mirror of `after`.
    public let before: String?
    /// Create the session in the background: skip selecting and focusing it, leaving the current selection
    /// untouched (the CLI's `--no-select`). Defaults to false — the normal select-and-focus behavior.
    public let noSelect: Bool

    public init(window: String?, cwd: String?, workspace: String?, workspaceName: String?,
                createWorkspace: Bool?, command: String?, wait: Bool? = nil, name: String?,
                after: String? = nil, before: String? = nil, noSelect: Bool = false) {
        self.window = window
        self.cwd = cwd
        self.workspace = workspace
        self.workspaceName = workspaceName
        self.createWorkspace = createWorkspace
        self.command = command
        self.wait = wait
        self.name = name
        self.after = after
        self.before = before
        self.noSelect = noSelect
    }
}

/// What `session.agent` asks the app to remember for one pane: the conversation ref (nil = clear it), which
/// pane it belongs to (`left`=main, `right`=split; nil = main), and the pid of the agent that reported it —
/// the ownership proof the app checks against the pane's live foreground process.
public struct ControlAgentSessionUpdate: Equatable, Sendable {
    public let ref: AgentSessionRef?
    public let pane: StatusPane?
    public let agentPid: Int?

    public init(ref: AgentSessionRef?, pane: StatusPane? = nil, agentPid: Int? = nil) {
        self.ref = ref
        self.pane = pane
        self.agentPid = agentPid
    }
}

/// Parsed `session.status` payload. Sound validation and playback stay host-side; `color` is the
/// per-call `#rrggbb` glyph-tint override (validated for hex in the dispatcher) and `shape` the per-call
/// silhouette override (parsed to `StatusShape` in the dispatcher), both threaded onto the ephemeral
/// `AgentIndicator`.
public struct ControlSessionStatusUpdate: Equatable, Sendable {
    public let status: AgentStatus
    public let blink: Bool?
    public let autoReset: Bool?
    public let sound: String?
    public let color: String?
    /// The per-call glyph silhouette, or nil to keep the status' semantic default glyph. Already
    /// validated — the dispatcher rejects an unknown raw value before any mutation.
    public let shape: StatusShape?
    /// Which pane set the status (`left`=main, `right`=split, `scratch`), or nil when unspecified. Stamped
    /// onto the indicator so pane-scoped keystroke-clear and pane-aware navigation know which surface blocked.
    public let pane: StatusPane?
    /// The surface's STABLE spawn token (the shell's baked `ROOK_PANE_ID`, forwarded by the hook as
    /// `--pane-id`). Resolved app-side against the session's live surfaces (`Session.paneRole(forToken:)`);
    /// when it resolves it OVERRIDES the stale role `pane`, fixing a status set from a promoted-then-re-split
    /// pane. nil/empty/unknown falls back to `pane`. The resolution stays app-side because the dispatcher
    /// has no session — this only carries the token through.
    public let paneID: String?
    /// The pid of the agent that reported the status — the ownership proof the app checks against the
    /// pane's live foreground process, so a NESTED agent process the pane's own agent spawned cannot move
    /// the row. nil (a human or a script calling `rookctl` by hand) skips the check. Last in `init` so
    /// every existing call site keeps compiling.
    public let agentPid: Int?

    public init(status: AgentStatus, blink: Bool?, autoReset: Bool?, sound: String?,
                color: String? = nil, shape: StatusShape? = nil,
                pane: StatusPane? = nil, paneID: String? = nil, agentPid: Int? = nil) {
        self.status = status
        self.blink = blink
        self.autoReset = autoReset
        self.sound = sound
        self.color = color
        self.shape = shape
        self.pane = pane
        self.paneID = paneID
        self.agentPid = agentPid
    }
}
