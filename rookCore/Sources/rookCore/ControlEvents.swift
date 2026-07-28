import Foundation

/// Event kinds retained by the app-run control event ring.
public enum ControlEventKind: String, Codable, CaseIterable, Sendable, Equatable {
    case status
    case notify
    case sessionCreated = "session.created"
    case sessionClosed = "session.closed"
    case treeChanged = "tree.changed"
}

/// Kind-specific event data. Optional fields keep the encoded payload compact while preserving one
/// stable object shape for shell/JSON consumers.
public struct ControlEventPayload: Codable, Sendable, Equatable {
    public var name: String?
    public var status: String?
    public var pane: String?
    public var blink: Bool?
    public var color: String?
    public var title: String?
    public var body: String?

    public init(name: String? = nil, status: String? = nil, pane: String? = nil,
                blink: Bool? = nil, color: String? = nil, title: String? = nil, body: String? = nil) {
        self.name = name
        self.status = status
        self.pane = pane
        self.blink = blink
        self.color = color
        self.title = title
        self.body = body
    }
}

/// An event before the ring assigns its app-run sequence and timestamp.
public struct ControlEventDraft: Sendable, Equatable {
    public let kind: ControlEventKind
    public let window: String?
    public let workspace: String?
    public let session: String?
    public let payload: ControlEventPayload

    public init(kind: ControlEventKind, window: String? = nil, workspace: String? = nil,
                session: String? = nil, payload: ControlEventPayload = ControlEventPayload()) {
        self.kind = kind
        self.window = window
        self.workspace = workspace
        self.session = session
        self.payload = payload
    }
}

/// One immutable entry in the event ring.
public struct ControlEvent: Codable, Sendable, Equatable {
    public let seq: UInt64
    public let ts: TimeInterval
    public let kind: ControlEventKind
    public let window: String?
    public let workspace: String?
    public let session: String?
    public let payload: ControlEventPayload

    public init(seq: UInt64, ts: TimeInterval, kind: ControlEventKind,
                window: String? = nil, workspace: String? = nil, session: String? = nil,
                payload: ControlEventPayload = ControlEventPayload()) {
        self.seq = seq
        self.ts = ts
        self.kind = kind
        self.window = window
        self.workspace = workspace
        self.session = session
        self.payload = payload
    }

    public init(seq: UInt64, ts: TimeInterval, draft: ControlEventDraft) {
        self.init(seq: seq, ts: ts, kind: draft.kind, window: draft.window,
                  workspace: draft.workspace, session: draft.session, payload: draft.payload)
    }
}

/// An independent consumer's position within one app run.
public struct ControlEventCursor: Sendable, Equatable {
    public let run: UUID
    public let after: UInt64

    public init(run: UUID, after: UInt64) {
        self.run = run
        self.after = after
    }
}

/// A page returned by a ring read. `next` is the global sequence through which the ring scanned,
/// including filtered-out entries.
public struct ControlEventBatch: Codable, Sendable, Equatable {
    public let run: UUID
    public let next: UInt64
    public let items: [ControlEvent]

    public init(run: UUID, next: UInt64, items: [ControlEvent]) {
        self.run = run
        self.next = next
        self.items = items
    }
}

/// Cursor failures that require the caller to choose whether to rebaseline. The read fails LOUDLY
/// rather than silently re-anchoring: a consumer that missed events must learn it missed them, instead
/// of mistaking a silent rebaseline for "nothing happened".
public enum ControlEventReadError: String, Sendable, Equatable {
    case runChanged = "event run changed"
    case cursorExpired = "event cursor expired"
    case cursorAhead = "event cursor is ahead of the current sequence"
}

/// Stable dispatcher validation errors shared with CLI and socket tests.
public enum ControlEventRequestError {
    public static let cursorPair = "events.read requires --run and --after together"
    public static let invalidCursor = "invalid event cursor"
    public static let invalidRun = "invalid event run id"
    public static let invalidLimit = "event limit must be between 1 and 1000"

    public static func invalidKind(_ kind: String) -> String {
        "invalid event kind: \(kind)"
    }
}

/// A successful page or a loud cursor failure carrying the ring's current anchor.
public enum ControlEventReadResult: Sendable, Equatable {
    case batch(ControlEventBatch)
    case failure(ControlEventReadError, anchor: ControlEventBatch)
}

/// Host-facing `events.read` options after dispatcher validation and normalization.
public struct ControlEventReadOptions: Equatable, Sendable {
    public let cursor: ControlEventCursor?
    public let kinds: Set<ControlEventKind>?
    public let limit: Int

    public init(cursor: ControlEventCursor?, kinds: Set<ControlEventKind>?, limit: Int) {
        self.cursor = cursor
        self.kinds = kinds
        self.limit = limit
    }
}

/// Bounded, non-destructive event history for one app process. Main-actor isolation matches the model
/// mutation and control-dispatch seams, so the ring needs no lock or subscriber lifecycle.
@MainActor
public final class ControlEventRing {
    public static let defaultCapacity = 4_096

    private let capacity: Int
    private let runID: UUID
    private let now: () -> Date
    private var entries: [ControlEvent] = []
    private var currentSequence: UInt64 = 0

    public init(capacity: Int = ControlEventRing.defaultCapacity,
                runID: UUID = UUID(), now: @escaping () -> Date = Date.init) {
        precondition(capacity > 0, "event ring capacity must be positive")
        self.capacity = capacity
        self.runID = runID
        self.now = now
    }

    /// Append one event, assigning the next sequence and current Unix timestamp.
    @discardableResult
    public func append(_ draft: ControlEventDraft) -> ControlEvent {
        currentSequence += 1
        let event = ControlEvent(seq: currentSequence, ts: now().timeIntervalSince1970, draft: draft)
        entries.append(event)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        return event
    }

    /// Read retained entries after `cursor`, optionally filtering by kind. A nil cursor is the
    /// subscribe-from-now bootstrap: it anchors at the tail and intentionally returns no history.
    public func read(cursor: ControlEventCursor?, kinds: Set<ControlEventKind>? = nil,
                     limit: Int = 100) -> ControlEventReadResult {
        let anchor = ControlEventBatch(run: runID, next: currentSequence, items: [])
        guard let cursor else { return .batch(anchor) }
        guard cursor.run == runID else { return .failure(.runChanged, anchor: anchor) }
        guard cursor.after <= currentSequence else { return .failure(.cursorAhead, anchor: anchor) }
        if let oldest = entries.first?.seq, cursor.after < oldest - 1 {
            return .failure(.cursorExpired, anchor: anchor)
        }

        var items: [ControlEvent] = []
        for event in entries where event.seq > cursor.after {
            guard kinds == nil || kinds!.contains(event.kind) else { continue }
            items.append(event)
            // stop AT the last returned match, not at the ring tail — the events the filter skipped
            // past after it have not been examined for the caller's next page yet.
            if items.count == limit {
                return .batch(ControlEventBatch(run: runID, next: event.seq, items: items))
            }
        }
        return .batch(ControlEventBatch(run: runID, next: currentSequence, items: items))
    }
}

// MARK: - Store emission

extension AppStore {
    /// Emits one window-scoped draft through the app-wide ring seam. The library-owned closure adds the
    /// window id; callers supply model identities and already-normalized kind-specific payloads.
    func emitControlEvent(_ kind: ControlEventKind, workspace: UUID? = nil, session: UUID? = nil,
                          payload: ControlEventPayload = ControlEventPayload()) {
        controlEventSink?(ControlEventDraft(
            kind: kind,
            workspace: workspace?.uuidString,
            session: session?.uuidString,
            payload: payload
        ))
    }

    /// Signals that this window's tree shape changed. The library debounces these per window, so a
    /// batch mutation (a multi-session move, a workspace reopen) collapses into one `tree.changed`.
    func scheduleTreeChanged() {
        emitControlEvent(.treeChanged)
    }

    func emitSessionCreated(_ session: Session, workspace: UUID) {
        emitControlEvent(.sessionCreated, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName))
        scheduleTreeChanged()
    }

    func emitSessionClosed(_ session: Session, workspace: UUID) {
        emitControlEvent(.sessionClosed, workspace: workspace, session: session.id,
                         payload: ControlEventPayload(name: session.displayName))
        scheduleTreeChanged()
    }

    /// Closes out a whole workspace. An EMPTY workspace emits no `session.closed` at all, so it needs its
    /// own `tree.changed` — its disappearance still reshapes the tree.
    func emitWorkspaceClosed(_ workspace: Workspace) {
        for session in workspace.sessions { emitSessionClosed(session, workspace: workspace.id) }
        if workspace.sessions.isEmpty { scheduleTreeChanged() }
    }

    /// The mirror of `emitWorkspaceClosed`, for a workspace arriving whole (an undo / reopen-recent).
    func emitWorkspaceCreated(_ workspace: Workspace) {
        for session in workspace.sessions { emitSessionCreated(session, workspace: workspace.id) }
        if workspace.sessions.isEmpty { scheduleTreeChanged() }
    }

    /// Every session of every workspace in this store, for a window close/delete.
    func emitAllSessionsClosed() {
        for workspace in workspaces { emitWorkspaceClosed(workspace) }
    }

    /// Every session of every workspace in this store, for a window open that is NOT a launch restore.
    func emitAllSessionsCreated() {
        for workspace in workspaces { emitWorkspaceCreated(workspace) }
    }

    /// Emits the already-normalized indicator `setAgentIndicator` just stored. Lives here (not inline in
    /// the setter) purely to keep `AppStore.swift` inside its file-length budget.
    func emitStatusChanged(_ indicator: AgentIndicator, for session: Session, id: UUID) {
        emitControlEvent(
            .status,
            workspace: workspace(forSession: id)?.id,
            session: id,
            payload: ControlEventPayload(
                name: session.displayName,
                status: indicator.status.rawValue,
                pane: indicator.statusPane?.rawValue,
                blink: indicator.blink,
                color: indicator.color
            )
        )
    }

    /// Records an accepted terminal/control notification in the app event ring and returns its effective
    /// title. An unresolved session returns nil and emits nothing. Delivery gating belongs to the caller.
    @discardableResult
    public func recordNotificationEvent(forSession id: UUID, title: String, body: String) -> String? {
        guard let session = session(withID: id), let workspace = workspace(forSession: id) else { return nil }
        let effectiveTitle = title.isEmpty ? session.displayName : title
        emitControlEvent(
            .notify,
            workspace: workspace.id,
            session: id,
            payload: ControlEventPayload(name: session.displayName, title: effectiveTitle, body: body)
        )
        return effectiveTitle
    }
}
