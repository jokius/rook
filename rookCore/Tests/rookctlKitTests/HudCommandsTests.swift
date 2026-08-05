import ArgumentParser
import Foundation
import Testing
import rookCore
@testable import rookctlKit

/// `rookctl session hud` — argv parsing, the two ways to ask for a spinner, and the local rejections that
/// need no socket. Its own file rather than more of `CommandsTests`, which is already near the test
/// file-size budget; `request` is borrowed from it the way `PickCommandsTests` does.
struct HudCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest { try CommandsTests().request(argv) }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Rookctl.parseAsRoot(argv)
            return nil
        } catch {
            return Rookctl.message(for: error)
        }
    }

    @Test func sessionHudOpenIsTheDefaultSubcommand() throws {
        let expected = ControlRequest(cmd: .sessionHudOpen, target: "active",
                                      args: ControlArgs(message: "gathering options"))
        #expect(try request(["session", "hud", "gathering options"]) == expected)
    }

    @Test func sessionHudOpenWithEveryOption() throws {
        // --background-color maps to ControlArgs.color, as the overlay group does.
        let expected = ControlRequest(cmd: .sessionHudOpen, target: "9f3c",
                                      args: ControlArgs(sizePercent: 40, message: "building index",
                                                        detail: "3 of 12 repos", spinner: "bar", window: "w1",
                                                        color: "#2a1a3a", position: "top"))
        #expect(try request(["session", "hud", "building index", "--detail", "3 of 12 repos", "--spinner",
                             "--position", "top", "--background-color", "#2a1a3a", "--size-percent", "40",
                             "--target", "9f3c", "--window", "w1"]) == expected)
    }

    // the bare flag resolves to the default style client-side, so the socket only ever carries a name
    @Test func sessionHudBareSpinnerFlagSendsTheDefaultStyle() throws {
        let sent = try request(["session", "hud", "working", "--spinner"]).args?.spinner
        #expect(sent == HudSpinner.defaultStyle.rawValue)
    }

    @Test(arguments: HudSpinner.allCases) func sessionHudSpinnerStyleImpliesTheSpinner(style: HudSpinner) throws {
        let sent = try request(["session", "hud", "working", "--spinner-style", style.rawValue]).args?.spinner
        #expect(sent == style.rawValue, "--spinner-style must turn the spinner on without --spinner")
    }

    @Test func sessionHudSpinnerStyleWinsOverTheBareFlag() throws {
        let sent = try request(["session", "hud", "working", "--spinner",
                                "--spinner-style", "braille"]).args?.spinner
        #expect(sent == "braille")
    }

    @Test func sessionHudWithoutASpinnerSendsNone() throws {
        #expect(try request(["session", "hud", "working"]).args?.spinner == nil)
    }

    // `none` is what the read-back reports for a static panel, so the CLI must accept the value `tree` just
    // handed the caller rather than failing locally on a request the raw socket takes
    @Test func sessionHudAcceptsTheReadBacksNoneAsNoSpinner() throws {
        #expect(try request(["session", "hud", "working", "--spinner-style", "none"]).args?.spinner == nil)
    }

    @Test func sessionHudNoneBeatsABareSpinnerFlag() throws {
        let sent = try request(["session", "hud", "working", "--spinner", "--spinner-style", "none"]).args?.spinner
        #expect(sent == nil, "naming a value is the more specific instruction, as a named style is")
    }

    @Test func sessionHudUpdateStopsTheSpinnerWithNone() throws {
        #expect(try request(["session", "hud", "update", "done", "--spinner-style", "none"]).args?.spinner == nil)
    }

    @Test func sessionHudRejectsAnUnknownSpinnerStyleBeforeTheSocket() {
        #expect(throws: (any Error).self) {
            try request(["session", "hud", "working", "--spinner-style", "swirl"])
        }
    }

    @Test func sessionHudUpdateSwitchesStyleInPlace() throws {
        let sent = try request(["session", "hud", "update", "still working",
                                "--spinner-style", "dot"]).args?.spinner
        #expect(sent == "dot")
    }

    @Test func sessionHudOpenVerbPostsAMessageNamedLikeASubcommand() throws {
        let expected = ControlRequest(cmd: .sessionHudOpen, target: "active", args: ControlArgs(message: "close"))
        #expect(try request(["session", "hud", "open", "close"]) == expected)
    }

    @Test(arguments: HudPosition.allCases)
    func sessionHudOpenAcceptsEveryPosition(_ position: HudPosition) throws {
        let expected = ControlRequest(cmd: .sessionHudOpen, target: "active",
                                      args: ControlArgs(message: "wait", position: position.rawValue))
        #expect(try request(["session", "hud", "wait", "--position", position.rawValue]) == expected)
    }

    @Test func sessionHudOpenOmitsUnsetFlags() throws {
        let built = try request(["session", "hud", "wait"])
        #expect(built.args?.spinner == nil)
        #expect(built.args?.detail == nil)
        #expect(built.args?.position == nil)
        #expect(built.args?.sizePercent == nil)
        #expect(built.args?.color == nil)
    }

    @Test func sessionHudRejectsBadPosition() {
        #expect(validationMessage(["session", "hud", "wait", "--position", "middle"])
            == "position must be one of: top, center, bottom")
        #expect(validationMessage(["session", "hud", "update", "wait", "--position", "middle"])
            == "position must be one of: top, center, bottom")
    }

    @Test func sessionHudRejectsBadSizePercent() {
        #expect(validationMessage(["session", "hud", "wait", "--size-percent", "0"])
            == "--size-percent must be between 1 and 100")
        #expect(validationMessage(["session", "hud", "wait", "--size-percent", "150"])
            == "--size-percent must be between 1 and 100")
        #expect(validationMessage(["session", "hud", "update", "wait", "--size-percent", "101"])
            == "--size-percent must be between 1 and 100")
    }

    @Test func sessionHudOpenRejectsBadBackgroundColor() {
        #expect(validationMessage(["session", "hud", "wait", "--background-color", "purple"])
            == "background-color must be a #rrggbb hex value")
    }

    @Test func sessionHudOpenRequiresAMessage() {
        #expect(throws: (any Error).self) { try Rookctl.parseAsRoot(["session", "hud", "open"]) }
    }

    @Test func sessionHudUpdate() throws {
        let expected = ControlRequest(cmd: .sessionHudUpdate, target: "9f3c",
                                      args: ControlArgs(message: "ready", detail: "12 repos", position: "bottom"))
        #expect(try request(["session", "hud", "update", "ready", "--detail", "12 repos",
                             "--position", "bottom", "--target", "9f3c"]) == expected)
    }

    @Test func sessionHudUpdateWithSpinnerAndSizePercent() throws {
        let expected = ControlRequest(cmd: .sessionHudUpdate, target: "active",
                                      args: ControlArgs(sizePercent: 25, message: "still working", spinner: "bar"))
        #expect(try request(["session", "hud", "update", "still working", "--spinner",
                             "--size-percent", "25"]) == expected)
    }

    @Test func sessionHudUpdateRequiresAMessage() {
        #expect(throws: (any Error).self) { try Rookctl.parseAsRoot(["session", "hud", "update"]) }
    }

    @Test func sessionHudUpdateHasNoBackgroundColorOption() {
        #expect(throws: (any Error).self) {
            try Rookctl.parseAsRoot(["session", "hud", "update", "ready", "--background-color", "#2a1a3a"])
        }
    }

    @Test func sessionHudClose() throws {
        #expect(try request(["session", "hud", "close"]) == ControlRequest(cmd: .sessionHudClose, target: "active"))
        #expect(try request(["session", "hud", "close"]).args == nil)
    }

    @Test func sessionHudCloseWithTargetAndWindow() throws {
        let expected = ControlRequest(cmd: .sessionHudClose, target: "9f3c", args: ControlArgs(window: "w1"))
        #expect(try request(["session", "hud", "close", "--target", "9f3c", "--window", "w1"]) == expected)
    }
}
