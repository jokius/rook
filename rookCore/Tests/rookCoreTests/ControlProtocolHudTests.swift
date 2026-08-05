import Foundation
import Testing
@testable import rookCore

/// Wire round-trips for `session.hud.*` and the `hud` node it reads back. Its own file rather than more of
/// `ControlProtocolTests`, which is already near the test file-size budget; the two `roundTrip` helpers are
/// copied for the same reason (they are four lines, and sharing them would need a third file).
struct ControlProtocolHudTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))
    }

    private func roundTrip(_ response: ControlResponse) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
    }

    @Test func sessionHudCommandsRoundTrip() throws {
        let cases: [ControlRequest] = [
            ControlRequest(cmd: .sessionHudOpen, target: "9f3c", args: ControlArgs(message: "gathering options")),
            ControlRequest(cmd: .sessionHudOpen, target: "9f3c",
                           args: ControlArgs(sizePercent: 40, message: "gathering options",
                                             detail: "scanning 400 files", spinner: "braille",
                                             window: "win", color: "#2a1a3a", position: "top")),
            ControlRequest(cmd: .sessionHudUpdate, target: "9f3c",
                           args: ControlArgs(message: "almost there", detail: "12 left", position: "bottom")),
            ControlRequest(cmd: .sessionHudClose, target: "9f3c"),
        ]
        for request in cases {
            #expect(try roundTrip(request) == request)
        }
    }

    @Test func sessionHudRawStringsMapToCommands() {
        #expect(Command(rawValue: "session.hud.open") == .sessionHudOpen)
        #expect(Command(rawValue: "session.hud.update") == .sessionHudUpdate)
        #expect(Command(rawValue: "session.hud.close") == .sessionHudClose)
    }

    @Test func sessionHudOpenOmitsUnsetArgs() throws {
        let request = ControlRequest(cmd: .sessionHudOpen, target: "9f3c", args: ControlArgs(message: "working"))
        let decoded = try roundTrip(request)
        #expect(decoded == request)
        #expect(decoded.args?.detail == nil)
        #expect(decoded.args?.spinner == nil)
        #expect(decoded.args?.position == nil)
        #expect(decoded.args?.sizePercent == nil)
        let json = String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
        for key in ["detail", "spinner", "position", "sizePercent", "color"] {
            #expect(!json.contains(key), "an unset \(key) must be omitted from the JSON; got \(json)")
        }
    }

    @Test(arguments: HudSpinner.allCases) func everySpinnerStyleRoundTrips(style: HudSpinner) throws {
        let request = ControlRequest(cmd: .sessionHudOpen, target: "9f3c",
                                     args: ControlArgs(message: "x", spinner: style.rawValue))
        #expect(try roundTrip(request).args?.spinner == style.rawValue)
    }

    @Test func sessionHudSpinnerCarriesNoneAsAnAbsentField() throws {
        let off = ControlRequest(cmd: .sessionHudOpen, target: "9f3c", args: ControlArgs(message: "x"))
        #expect(try roundTrip(off).args?.spinner == nil)
    }

    @Test func treeSessionNodeRoundTripsWithHud() throws {
        let hud = ControlHudNode(message: "gathering options", detail: "scanning 400 files", spinner: "braille",
                                 backgroundColor: "#2a1a3a", sizePercent: 35, heightPercent: 12, position: "top")
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false, hud: hud)
        let response = ControlResponse(ok: true, result: ControlResult(tree: ControlTree(
            workspaces: [ControlWorkspaceNode(id: "w1", name: "work", active: true, sessions: [session])])))
        let decoded = try roundTrip(response)
        #expect(decoded == response)
        #expect(decoded.result?.tree?.workspaces.first?.sessions.first?.hud == hud)
    }

    @Test func treeSessionNodeOmitsHudWhenNil() throws {
        let session = ControlSessionNode(id: "s1", name: "shell", cwd: "/tmp", active: true, split: false,
                                         overlay: true)
        let json = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? ""
        #expect(!json.contains("hud"), "no HUD must be omitted from the JSON; got \(json)")
        let decoded = try JSONDecoder().decode(ControlSessionNode.self, from: Data(json.utf8))
        #expect(decoded.hud == nil)
    }

    @Test func controlHudNodeOmitsUnsetFieldsButAlwaysReportsPositionAndSpinner() throws {
        let hud = ControlHudNode(message: "working", position: "center")
        let json = String(data: try JSONEncoder().encode(hud), encoding: .utf8) ?? ""
        #expect(!json.contains("detail"), "a nil detail must be omitted from the JSON; got \(json)")
        #expect(!json.contains("backgroundColor"), "a nil background must be omitted from the JSON; got \(json)")
        #expect(!json.contains("sizePercent"), "a nil size must be omitted from the JSON; got \(json)")
        #expect(!json.contains("heightPercent"), "a nil height must be omitted from the JSON; got \(json)")
        #expect(json.contains("\"position\":\"center\""), "the effective position must always be emitted; got \(json)")
        #expect(json.contains("\"spinner\":\"none\""), "the effective spinner must always be emitted; got \(json)")
        let decoded = try JSONDecoder().decode(ControlHudNode.self, from: Data(json.utf8))
        #expect(decoded == hud)
    }

    @Test func treeSessionNodeToleratesMissingHud() throws {
        // a pre-`session.hud.open` server omits the key entirely, so it must decode as nil.
        let raw = #"{"id":"s1","name":"shell","cwd":"/tmp","active":true,"split":false,"# +
            #""overlay":false,"scratch":false,"flagged":false}"#
        #expect(try JSONDecoder().decode(ControlSessionNode.self, from: Data(raw.utf8)).hud == nil)
    }
}
