import Foundation

/// One `dashboard` target: a resolvable head plus an optional pane selector. A nil `pane` is the bare form,
/// which expands to EVERY pane of the session; `.primary`/`.split` select that one cell. Parsing is
/// host-free so `ControlDispatcher` validates and `ControlServer` resolves against ONE grammar.
///
/// Pane refs exist because the 9-cell cap counts PANES and trims the tail: with nine sessions of which three
/// are split, sessions 7-9 never reach the grid at all, so unwatched shell panes evict watched ones. There
/// was no workaround — `session.split off` only HIDES the pane, `hasSplit` survives a hide, and only the
/// pane's own shell exiting clears it.
public struct DashboardTarget: Equatable, Sendable {
    /// The part `ControlResolve.resolve` matches: `active`, a full UUID, or a unique prefix.
    public let head: String

    /// The selected pane, or nil for the bare form. Never `.scratch`/`.overlay` — `DashboardMember`
    /// excludes those as cells.
    public let pane: TerminalZoomSurface?

    init(head: String, pane: TerminalZoomSurface?) {
        self.head = head
        self.pane = pane
    }

    /// Parse a raw `dashboard` target, returning nil when the pane suffix is malformed.
    ///
    /// Splitting on the FIRST colon is safe because a valid head never contains one — `ControlResolve`
    /// accepts only `active`, a full UUID, or a UUID prefix. So a pasted `surface:<uuid>:left` (the
    /// `surface.zoom` address) fails outright instead of half-resolving to a head of `surface`, and a typo
    /// like `A:lft` gets a real error instead of becoming a mystery `unresolved` entry.
    ///
    /// Only `left`/`right` are accepted, case-insensitively. `primary`/`split` parse as `TerminalZoomSurface`
    /// but are refused here: the `dashboardMembers` tree read-back emits `left`/`right`, and one spelling per
    /// pane is what keeps the write form identical to the read form.
    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else {
            guard !rawValue.isEmpty else { return nil }
            self.init(head: rawValue, pane: nil)
            return
        }
        let head = String(rawValue[rawValue.startIndex..<colon])
        let suffix = String(rawValue[rawValue.index(after: colon)...]).lowercased()
        guard !head.isEmpty else { return nil }
        switch suffix {
        case "left": self.init(head: head, pane: .primary)
        case "right": self.init(head: head, pane: .split)
        default: return nil
        }
    }
}

/// A `DashboardTarget` whose head has been resolved to a session. `pane` keeps the same meaning: nil is the
/// bare form taking every pane, an explicit value takes that cell alone.
public struct ResolvedDashboardTarget: Equatable, Sendable {
    public let session: UUID
    public let pane: TerminalZoomSurface?

    public init(session: UUID, pane: TerminalZoomSurface?) {
        self.session = session
        self.pane = pane
    }
}
