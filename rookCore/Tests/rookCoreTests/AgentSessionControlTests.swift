import Foundation
import Testing
@testable import rookCore

@MainActor
@Suite("session.agent")
struct AgentSessionControlTests {
    private func dispatcher() -> (ControlDispatcher, MockControlActions) {
        let actions = MockControlActions()
        return (ControlDispatcher(actions: actions), actions)
    }

    private func request(agent: String, id: String? = nil, configDir: String? = nil,
                         pane: String? = nil, agentPid: Int? = nil) -> ControlRequest {
        ControlRequest(cmd: .sessionAgent, target: "active",
                       args: ControlArgs(pane: pane, agent: agent, agentID: id,
                                         configDir: configDir, agentPid: agentPid))
    }

    @Test("a reported conversation reaches the app with its pane and proof of ownership")
    func routesThroughActions() async {
        let (dispatcher, actions) = dispatcher()
        let response = await dispatcher.dispatch(request(agent: "claude", id: "abc",
                                                         configDir: "/Users/x/.claude-work",
                                                         pane: "right", agentPid: 4242))
        #expect(response?.ok == true)
        #expect(actions.calls == [
            .sessionAgent(target: "active", window: nil,
                          ControlAgentSessionUpdate(ref: AgentSessionRef(kind: .claude, id: "abc",
                                                                         configDir: "/Users/x/.claude-work"),
                                                    pane: .right, agentPid: 4242)),
        ])
    }

    @Test("no id clears the pane's remembered conversation")
    func noIDClears() async {
        let (dispatcher, actions) = dispatcher()
        let response = await dispatcher.dispatch(request(agent: "codex"))
        #expect(response?.ok == true)
        #expect(actions.calls == [
            .sessionAgent(target: "active", window: nil,
                          ControlAgentSessionUpdate(ref: nil, pane: nil, agentPid: nil)),
        ])
    }

    @Test("an unknown agent is rejected")
    func unknownAgentRejected() async {
        let (dispatcher, actions) = dispatcher()
        let response = await dispatcher.dispatch(request(agent: "gemini", id: "abc"))
        #expect(response?.ok == false)
        #expect(response?.error == "invalid agent (expected claude or codex)")
        #expect(actions.calls.isEmpty)
    }

    /// A scratch terminal is never restored, so a conversation reported for it could never be resumed —
    /// saying ok would be a silent lie.
    @Test("the scratch pane is rejected, an unknown pane too")
    func paneValidation() async {
        let (dispatcher, actions) = dispatcher()
        let scratch = await dispatcher.dispatch(request(agent: "claude", id: "abc", pane: "scratch"))
        #expect(scratch?.error == "session.agent supports --pane left or right")
        let bogus = await dispatcher.dispatch(request(agent: "claude", id: "abc", pane: "middle"))
        #expect(bogus?.error == "--pane must be left, right, or scratch")
        #expect(actions.calls.isEmpty)
    }

    @Test("session.agent round-trips on the wire")
    func roundTrips() throws {
        let request = request(agent: "claude", id: "abc", configDir: "/c", pane: "left", agentPid: 7)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ControlRequest.self, from: data)
        #expect(decoded.cmd == .sessionAgent)
        #expect(decoded.args?.agent == "claude")
        #expect(decoded.args?.agentID == "abc")
        #expect(decoded.args?.configDir == "/c")
        #expect(decoded.args?.agentPid == 7)
    }
}

@MainActor
@Suite("AppStore agent conversations")
struct AppStoreAgentSessionTests {
    private func storeWithSession() -> (AppStore, UUID) {
        let store = AppStore(persistence: PersistenceStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())))
        let workspace = store.addWorkspace(name: "w")
        let session = store.addSession(toWorkspace: workspace.id, cwd: "/tmp")!
        return (store, session.id)
    }

    @Test("a reported conversation is remembered per pane and read back on the tree")
    func setAndReadBack() {
        let (store, id) = storeWithSession()
        let ref = AgentSessionRef(kind: .claude, id: "abc", configDir: "/c")
        store.setAgentSession(ref, forSession: id, pane: .left)

        #expect(store.session(withID: id)?.agentSession == ref)
        let node = store.controlTree().workspaces.flatMap(\.sessions).first { $0.id == id.uuidString }
        #expect(node?.agentSession == ref)
        #expect(node?.splitAgentSession == nil)
    }

    /// A promoted split survivor keeps its baked `ROOK_PANE=right`, so its agent keeps reporting `right`
    /// for what is now the main pane — the same normalization `setAgentIndicator` does.
    @Test("a right-pane report on a session with no split lands on the main pane")
    func rightPaneWithoutSplitNormalizesToMain() {
        let (store, id) = storeWithSession()
        let ref = AgentSessionRef(kind: .claude, id: "abc")
        store.setAgentSession(ref, forSession: id, pane: .right)

        #expect(store.session(withID: id)?.agentSession == ref)
        #expect(store.session(withID: id)?.splitAgentSession == nil)
    }

    @Test("clearing forgets the conversation")
    func clearForgets() {
        let (store, id) = storeWithSession()
        store.setAgentSession(AgentSessionRef(kind: .claude, id: "abc"), forSession: id, pane: .left)
        store.setAgentSession(nil, forSession: id, pane: .left)
        #expect(store.session(withID: id)?.agentSession == nil)
    }

    @Test("the conversation survives a snapshot round-trip")
    func snapshotRoundTrips() throws {
        let (store, id) = storeWithSession()
        let ref = AgentSessionRef(kind: .codex, id: "cx", configDir: "/Users/x/.codex")
        store.setAgentSession(ref, forSession: id, pane: .left)

        let data = try JSONEncoder().encode(store.snapshot())
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(decoded.workspaces.first?.sessions.first?.agentSession == ref)
    }

    /// A snapshot written before this feature (or by a NEWER build naming an agent we don't know) must not
    /// take the whole tree down with it — the pane just restores without a resume.
    @Test("a legacy or unknown-agent snapshot decodes to no conversation, not a wiped tree")
    func lossyDecode() throws {
        let legacy = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp"}"#
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.agentSession == nil)

        let future = #"{"id":"\#(UUID().uuidString)","cwd":"/tmp","agentSession":{"kind":"gemini","id":"x"}}"#
        let tolerated = try JSONDecoder().decode(SessionSnapshot.self, from: Data(future.utf8))
        #expect(tolerated.agentSession == nil)
        #expect(tolerated.cwd == "/tmp")
    }
}
