import Foundation
import Testing
@testable import rookCore

// MARK: - Ring

@MainActor
struct ControlEventRingTests {
    private let runID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let fixedDate = Date(timeIntervalSince1970: 1_783_969_641.38)

    private func ring(capacity: Int = 4_096) -> ControlEventRing {
        ControlEventRing(capacity: capacity, runID: runID, now: { fixedDate })
    }

    private func draft(_ kind: ControlEventKind, name: String = "api-fix") -> ControlEventDraft {
        ControlEventDraft(kind: kind, window: "window", workspace: "workspace", session: "session",
                          payload: ControlEventPayload(name: name))
    }

    @Test func appendAssignsMonotonicSequenceAndTimestamp() {
        let subject = ring()

        let first = subject.append(draft(.status))
        let second = subject.append(draft(.notify))

        #expect(first.seq == 1)
        #expect(second.seq == 2)
        #expect(first.ts == fixedDate.timeIntervalSince1970)
        #expect(first.kind == .status)
        #expect(first.window == "window")
        #expect(first.payload.name == "api-fix")
    }

    @Test func bootstrapAnchorsAtTailWithoutReplayingHistory() {
        let subject = ring()
        subject.append(draft(.status))
        subject.append(draft(.notify))

        let result = subject.read(cursor: nil)

        #expect(result == .batch(ControlEventBatch(run: runID, next: 2, items: [])))
    }

    @Test func capacityEvictsOldestAndKeepsExactBoundaryReadable() {
        let subject = ring(capacity: 2)
        subject.append(draft(.status, name: "one"))
        subject.append(draft(.notify, name: "two"))
        subject.append(draft(.sessionCreated, name: "three"))

        let boundary = subject.read(cursor: ControlEventCursor(run: runID, after: 1))
        let expired = subject.read(cursor: ControlEventCursor(run: runID, after: 0))

        #expect(boundary == .batch(ControlEventBatch(run: runID, next: 3, items: [
            ControlEvent(seq: 2, ts: fixedDate.timeIntervalSince1970, draft: draft(.notify, name: "two")),
            ControlEvent(seq: 3, ts: fixedDate.timeIntervalSince1970, draft: draft(.sessionCreated, name: "three")),
        ])))
        #expect(expired == .failure(.cursorExpired, anchor: ControlEventBatch(run: runID, next: 3, items: [])))
    }

    @Test func readsAreNonDestructiveAndIndependent() {
        let subject = ring()
        subject.append(draft(.status))

        let cursor = ControlEventCursor(run: runID, after: 0)
        let first = subject.read(cursor: cursor)
        let second = subject.read(cursor: cursor)

        #expect(first == second)
        #expect(first.batch?.items.map(\.seq) == [1])
    }

    @Test func filterAdvancesAcrossNonmatchingEvents() {
        let subject = ring()
        subject.append(draft(.notify))
        subject.append(draft(.status))
        subject.append(draft(.sessionClosed))

        let result = subject.read(cursor: ControlEventCursor(run: runID, after: 0), kinds: [.status])

        #expect(result.batch?.items.map(\.kind) == [.status])
        #expect(result.batch?.next == 3)
    }

    @Test func emptyFilteredBatchAdvancesToTail() {
        let subject = ring()
        subject.append(draft(.notify))
        subject.append(draft(.sessionClosed))

        let result = subject.read(cursor: ControlEventCursor(run: runID, after: 0), kinds: [.status])

        #expect(result == .batch(ControlEventBatch(run: runID, next: 2, items: [])))
    }

    @Test func limitStopsAtLastReturnedMatchWithoutDroppingLaterMatches() {
        let subject = ring()
        subject.append(draft(.notify, name: "skip"))
        subject.append(draft(.status, name: "first"))
        subject.append(draft(.notify, name: "skip-two"))
        subject.append(draft(.status, name: "second"))

        let first = subject.read(cursor: ControlEventCursor(run: runID, after: 0), kinds: [.status], limit: 1)
        let second = subject.read(cursor: ControlEventCursor(run: runID, after: first.batch!.next),
                                  kinds: [.status], limit: 1)

        #expect(first.batch?.next == 2)
        #expect(first.batch?.items.map(\.payload.name) == ["first"])
        #expect(second.batch?.next == 4)
        #expect(second.batch?.items.map(\.payload.name) == ["second"])
    }

    @Test func runMismatchReturnsCurrentAnchor() {
        let subject = ring()
        subject.append(draft(.status))
        let otherRun = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let result = subject.read(cursor: ControlEventCursor(run: otherRun, after: 0))

        #expect(result == .failure(.runChanged, anchor: ControlEventBatch(run: runID, next: 1, items: [])))
    }

    @Test func cursorAheadReturnsCurrentAnchor() {
        let subject = ring()
        subject.append(draft(.status))

        let result = subject.read(cursor: ControlEventCursor(run: runID, after: 2))

        #expect(result == .failure(.cursorAhead, anchor: ControlEventBatch(run: runID, next: 1, items: [])))
    }
}

private extension ControlEventReadResult {
    var batch: ControlEventBatch? {
        guard case .batch(let batch) = self else { return nil }
        return batch
    }
}

// MARK: - Dispatcher validation

@MainActor
struct ControlEventDispatcherTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    @Test func bootstrapRoutesWithDefaultsAndReturnsActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let batch = ControlEventBatch(run: run, next: 12, items: [])
        actions.nextEventsReadResponse = ControlResponse(ok: true, result: ControlResult(events: batch))

        let response = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead))

        #expect(response == actions.nextEventsReadResponse)
        #expect(actions.calls == [.eventsRead(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100))])
    }

    @Test func parsesCursorKindsAndMaximumLimit() async {
        let actions = MockControlActions()

        _ = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .eventsRead,
            args: ControlArgs(after: "42", run: run.uuidString,
                              kinds: ["status, notify", "tree.changed", "status"], limit: 1_000)
        ))

        #expect(actions.calls == [.eventsRead(ControlEventReadOptions(
            cursor: ControlEventCursor(run: run, after: 42),
            kinds: [.status, .notify, .treeChanged],
            limit: 1_000
        ))])
    }

    @Test func cursorFieldsMustBePaired() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let runOnly = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(run: run.uuidString)))
        let afterOnly = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(after: "1")))

        #expect(runOnly == ControlResponse(ok: false, error: "events.read requires --run and --after together"))
        #expect(afterOnly == ControlResponse(ok: false, error: "events.read requires --run and --after together"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsInvalidRunAndDecimalCursor() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let badRun = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead,
                                                              args: ControlArgs(after: "1", run: "not-a-uuid")))
        let badCursor = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead,
                                                                 args: ControlArgs(after: "-1", run: run.uuidString)))

        #expect(badRun == ControlResponse(ok: false, error: "invalid event run id"))
        #expect(badCursor == ControlResponse(ok: false, error: "invalid event cursor"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsUnknownKindAfterRawRequestDecoding() async throws {
        let actions = MockControlActions()
        let json = #"{"cmd":"events.read","args":{"kinds":["status","future.kind"]}}"#
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(json.utf8))

        let response = await ControlDispatcher(actions: actions).dispatch(request)

        #expect(response == ControlResponse(ok: false, error: "invalid event kind: future.kind"))
        #expect(actions.calls.isEmpty)
    }

    @Test func rejectsEmptyKindComponents() async {
        for kinds in [[""], [","], ["status,"]] {
            let actions = MockControlActions()
            let response = await ControlDispatcher(actions: actions)
                .dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(kinds: kinds)))

            #expect(response == ControlResponse(ok: false, error: "invalid event kind: "))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test func rejectsLimitsOutsideInclusiveBounds() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let zero = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(limit: 0)))
        let tooLarge = await dispatcher.dispatch(ControlRequest(cmd: .eventsRead, args: ControlArgs(limit: 1_001)))

        #expect(zero == ControlResponse(ok: false, error: "event limit must be between 1 and 1000"))
        #expect(tooLarge == ControlResponse(ok: false, error: "event limit must be between 1 and 1000"))
        #expect(actions.calls.isEmpty)
    }
}

// MARK: - Wire shape

struct ControlEventProtocolTests {
    private let run = UUID(uuidString: "CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1")!

    private var sample: [ControlEvent] {
        [
            ControlEvent(seq: 1, ts: 1.25, kind: .status, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", status: "blocked", pane: "right",
                                                      blink: true, color: "#aabbcc")),
            ControlEvent(seq: 2, ts: 2.5, kind: .notify, window: "win", workspace: "work", session: "sess",
                         payload: ControlEventPayload(name: "api", title: "Done", body: "tests passed")),
            ControlEvent(seq: 3, ts: 3.5, kind: .sessionCreated, window: "win", workspace: "work",
                         session: "created", payload: ControlEventPayload(name: "new")),
            ControlEvent(seq: 4, ts: 4.5, kind: .sessionClosed, window: "win", workspace: "work",
                         session: "closed", payload: ControlEventPayload(name: "old")),
            ControlEvent(seq: 5, ts: 5.5, kind: .treeChanged, window: "win"),
        ]
    }

    @Test func everyEventKindMatchesGoldenWireShape() throws {
        let expected = [
            ##"{"kind":"status","payload":{"blink":true,"color":"#aabbcc","name":"api","pane":"right","status":"blocked"},"seq":1,"session":"sess","ts":1.25,"window":"win","workspace":"work"}"##,
            ##"{"kind":"notify","payload":{"body":"tests passed","name":"api","title":"Done"},"seq":2,"session":"sess","ts":2.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"session.created","payload":{"name":"new"},"seq":3,"session":"created","ts":3.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"session.closed","payload":{"name":"old"},"seq":4,"session":"closed","ts":4.5,"window":"win","workspace":"work"}"##,
            ##"{"kind":"tree.changed","payload":{},"seq":5,"ts":5.5,"window":"win"}"##,
        ]

        #expect(try sample.map(canonicalJSON) == expected)
        #expect(try JSONDecoder().decode([ControlEvent].self, from: JSONEncoder().encode(sample)) == sample)
    }

    @Test func optionalEventAndPayloadFieldsAreOmitted() throws {
        let data = try JSONEncoder().encode(ControlEvent(seq: 1, ts: 10, kind: .treeChanged, window: "win"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(object["payload"] as? [String: Any])

        #expect(object["workspace"] == nil)
        #expect(object["session"] == nil)
        #expect(payload.isEmpty)
    }

    @Test func bootstrapAndPopulatedBatchesRoundTripInResults() throws {
        let populated = ControlEventBatch(run: run, next: 5, items: sample)

        for batch in [ControlEventBatch(run: run, next: 41, items: []), populated] {
            let response = ControlResponse(ok: true, result: ControlResult(events: batch))
            let data = try JSONEncoder().encode(response)
            #expect(try JSONDecoder().decode(ControlResponse.self, from: data) == response)
        }
    }

    @Test func errorResponseCanCarryCurrentEventAnchor() throws {
        let anchor = ControlEventBatch(run: run, next: 99, items: [])
        let response = ControlResponse(ok: false, result: ControlResult(events: anchor),
                                       error: ControlEventReadError.cursorExpired.rawValue)

        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))

        #expect(decoded.result?.events == anchor)
        #expect(try canonicalJSON(response) ==
            #"{"error":"event cursor expired","ok":false,"result":{"events":{"items":[],"next":99,"run":"CBB5E3D0-7A9B-4C96-9EA2-18B14380DDB1"}}}"#)
    }

    @Test func eventReadRequestKeepsKindsAsRawStringsOnTheWire() throws {
        // unknown kinds must survive DECODING and fail in the dispatcher, so the error is a normal
        // control error rather than an undecodable request.
        let request = ControlRequest(cmd: .eventsRead,
                                     args: ControlArgs(after: "7", run: run.uuidString,
                                                       kinds: ["status", "future.kind"], limit: 250))

        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded == request)
        #expect(decoded.args?.kinds == ["status", "future.kind"])
    }

    private func canonicalJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

// MARK: - Store / library emission

/// Class suite so each test gets its own temp state dir, like `WindowLibraryTests`.
@MainActor
final class ControlEventEmissionTests {
    private let directory: URL
    private let runID = UUID(uuidString: "9F1D3B2A-4C55-4E77-8A11-0B2C3D4E5F60")!
    private let ring: ControlEventRing

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rook-events-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ring = ControlEventRing(runID: runID)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLibrary() -> WindowLibrary {
        WindowLibrary(directory: directory, controlEventRing: ring)
    }

    /// Every event recorded so far — the ring is per app run, so `after: 0` is "since launch".
    private func recorded(_ library: WindowLibrary) -> [ControlEvent] {
        let response = library.readEvents(ControlEventReadOptions(
            cursor: ControlEventCursor(run: runID, after: 0), kinds: nil, limit: 1_000))
        return response.result?.events?.items ?? []
    }

    @Test func launchBootstrapRecordsNothing() {
        let library = makeLibrary()
        library.flushTreeEvents()

        // the seeded window brought a workspace and a session with it — replaying those as `session.created`
        // would fill the ring with launch noise before any consumer exists.
        #expect(recorded(library).isEmpty)
        #expect(library.readEvents(ControlEventReadOptions(cursor: nil, kinds: nil, limit: 100))
            .result?.events == ControlEventBatch(run: runID, next: 0, items: []))
    }

    @Test func runtimeSessionCreateAndCloseAreRecordedWithADebouncedTreeSignal() throws {
        let library = makeLibrary()
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)

        let session = try #require(store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "builder"))
        #expect(recorded(library).map(\.kind) == [.sessionCreated]) // tree.changed is still queued
        library.flushTreeEvents()
        store.closeSession(session.id)
        library.flushTreeEvents()

        let events = recorded(library)
        #expect(events.map(\.kind) == [.sessionCreated, .treeChanged, .sessionClosed, .treeChanged])
        #expect(events[0].payload.name == "builder")
        #expect(events[0].session == session.id.uuidString)
        #expect(events[0].workspace == workspace.id.uuidString)
        #expect(events[0].window == library.activeWindowID?.uuidString)
    }

    @Test func statusTransitionsRecordTheNormalizedIndicatorAndSkipRepeats() throws {
        let library = makeLibrary()
        let store = try #require(library.activeStore)
        let session = try #require(store.workspaces.first?.sessions.first)

        // `.right` on a splitless session normalizes to `.left`; a repeat of the SAME normalized value
        // must not emit again.
        store.setAgentIndicator(AgentIndicator(status: .blocked, blink: true, color: "#ff0000",
                                               statusPane: .right), forSession: session.id)
        store.setAgentIndicator(AgentIndicator(status: .blocked, blink: true, color: "#ff0000",
                                               statusPane: .right), forSession: session.id)

        let events = recorded(library).filter { $0.kind == .status }
        #expect(events.count == 1)
        #expect(events[0].payload.status == "blocked")
        #expect(events[0].payload.pane == "left")
        #expect(events[0].payload.blink == true)
        #expect(events[0].payload.color == "#ff0000")
    }

    @Test func autoResetClearIsAVisibleStatusTransition() throws {
        let library = makeLibrary()
        let store = try #require(library.activeStore)
        let session = try #require(store.workspaces.first?.sessions.first)
        store.setAgentIndicator(AgentIndicator(status: .completed, autoReset: true), forSession: session.id)

        // selecting the session consumes the one-time flash — the END of the episode must be observable,
        // not just its start.
        store.selectSession(session.id)

        #expect(recorded(library).filter { $0.kind == .status }.map(\.payload.status) == ["completed", "idle"])
    }

    @Test func notificationRecordsItsEffectiveTitleAndBody() throws {
        let library = makeLibrary()
        let store = try #require(library.activeStore)
        let session = try #require(store.workspaces.first?.sessions.first)

        let blank = store.recordNotificationEvent(forSession: session.id, title: "", body: "done")
        let titled = store.recordNotificationEvent(forSession: session.id, title: "Build", body: "green")

        #expect(blank == session.displayName) // an empty title falls back to the session name
        #expect(titled == "Build")
        let events = recorded(library).filter { $0.kind == .notify }
        #expect(events.map(\.payload.title) == [session.displayName, "Build"])
        #expect(events.map(\.payload.body) == ["done", "green"])
        #expect(store.recordNotificationEvent(forSession: UUID(), title: "x", body: "y") == nil)
    }

    // the ring's own guards are unit-tested above, but the RESPONSE mapping is where the design decision
    // lives: a bad cursor must come back `ok: false`. Answering ok with a fresh anchor would silently
    // rebaseline the caller — it would resume happily, never knowing it missed events, which is exactly
    // the failure this feature exists to prevent.
    @Test func readEventsReportsCursorFailuresLoudlyInsteadOfRebaselining() throws {
        let library = makeLibrary()
        let store = try #require(library.activeStore)
        let workspace = try #require(store.workspaces.first)
        _ = store.addSession(toWorkspace: workspace.id, cwd: "/tmp", name: "builder")
        library.flushTreeEvents()

        let stale = ControlEventCursor(run: UUID(), after: 0)                    // a previous app run
        let ahead = ControlEventCursor(run: runID, after: 9_999)                 // past the sequence
        for cursor in [stale, ahead] {
            let response = library.readEvents(ControlEventReadOptions(cursor: cursor, kinds: nil, limit: 100))
            #expect(response.ok == false)
            #expect(response.error?.isEmpty == false)
            // the anchor still rides along, so a caller that DECIDES to rebaseline can do it from this
            // same reply — deciding is the part that must not be taken away from it.
            #expect(response.result?.events?.run == runID)
        }
    }

    // the debouncer is keyed per window; one shared debouncer would look identical in every single-window
    // test, then coalesce two windows' unrelated bursts into ONE tree.changed and leave a watcher of the
    // losing window waiting for a signal that never comes.
    @Test func treeChangedDebounceIsPerWindowRatherThanShared() throws {
        let library = makeLibrary()
        let first = try #require(library.windows.first?.id)
        let second = library.newWindow().id
        library.flushTreeEvents()

        // mutate BOTH windows inside one burst — no flush in between, which is what lets a shared
        // debouncer drop one of them.
        let firstWorkspace = try #require(library.store(for: first)?.workspaces.first)
        let secondWorkspace = try #require(library.store(for: second)?.workspaces.first)
        _ = library.store(for: first)?.addSession(toWorkspace: firstWorkspace.id, cwd: "/tmp", name: "a")
        _ = library.store(for: second)?.addSession(toWorkspace: secondWorkspace.id, cwd: "/tmp", name: "b")
        library.flushTreeEvents()

        let treeChanges = recorded(library).filter { $0.kind == .treeChanged }
        #expect(Set(treeChanges.compactMap(\.window)) == [first.uuidString, second.uuidString])
    }

    @Test func reopeningAClosedWindowReplaysItsSessionsAsCreated() throws {
        let library = makeLibrary()
        let first = try #require(library.windows.first?.id)
        let second = library.newWindow().id
        let reopened = try #require(library.store(for: second)?.workspaces.first?.sessions.first?.id)
        library.flushTreeEvents()
        library.closeWindow(second)
        library.flushTreeEvents()

        _ = library.loadStore(for: second)
        library.flushTreeEvents()

        // one `tree.changed` per settled burst — the per-window debouncer is what keeps a batch mutation
        // from waking a watcher once per session.
        let events = recorded(library).filter { $0.window == second.uuidString }
        #expect(events.map(\.kind) == [.sessionCreated, .treeChanged, .sessionClosed, .treeChanged,
                                       .sessionCreated, .treeChanged])
        #expect(events.last(where: { $0.kind == .sessionCreated })?.session == reopened.uuidString)
        #expect(recorded(library).allSatisfy { $0.window != first.uuidString }) // the untouched window is silent
    }
}
