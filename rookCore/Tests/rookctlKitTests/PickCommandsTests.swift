import ArgumentParser
import Foundation
import Testing
import rookCore
@testable import rookctlKit

/// `rookctl pick` — argv parsing, stdin sniffing, and the blocking poll. The poll is exercised through
/// `execute`'s injected transport/sleep/stdout/stderr, so every wire outcome and exit mapping is covered
/// without a real socket, real delays, or replacing process file descriptors.
struct PickCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest { try CommandsTests().request(argv) }

    // MARK: - parsing

    @Test func pickDefaultsToOpen() throws {
        #expect(try Rookctl.parseAsRoot(["pick"]) is Pick.Open)
    }

    @Test func pickOpenSniffsJSONArray() throws {
        let input = Data("""
          [
            {"id":"one","label":"One","subtitle":"First"},
            {"id":"two","label":"Two"}
          ]
        """.utf8)

        #expect(try Pick.Open.parseItems(input) == [
            ControlPickItem(id: "one", label: "One", subtitle: "First"),
            ControlPickItem(id: "two", label: "Two")
        ])
    }

    @Test func pickOpenSniffsBareLines() throws {
        #expect(try Pick.Open.parseItems(Data("One\nTwo\n".utf8)) == [
            ControlPickItem(id: "One", label: "One"),
            ControlPickItem(id: "Two", label: "Two")
        ])
    }

    @Test func pickOpenDropsBlankLines() throws {
        #expect(try Pick.Open.parseItems(Data("\nOne\n \t \n\nTwo\n".utf8)) == [
            ControlPickItem(id: "One", label: "One"),
            ControlPickItem(id: "Two", label: "Two")
        ])
    }

    @Test func pickOpenAcceptsEmptyStdinAsNoItems() throws {
        #expect(try Pick.Open.parseItems(Data()).isEmpty)
    }

    @Test func pickOpenRejectsMalformedJSON() {
        #expect(throws: (any Error).self) {
            try Pick.Open.parseItems(Data("[{\"id\":\"one\"".utf8))
        }
    }

    @Test func pickOpenMapsEveryOptionToRequest() throws {
        let command = try Pick.Open.parse([
            "--prompt", "Choose one", "--query", "on", "--allow-custom", "--follow",
            "--window", "w1", "--no-block"
        ])
        let items = [ControlPickItem(id: "One", label: "One")]
        let expected = ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(
                follow: true, items: items, prompt: "Choose one", query: "on",
                allowCustom: true, window: "w1"
            )
        )

        #expect(try command.makeRequest(input: Data("One\n".utf8)) == expected)
        #expect(command.noBlock)
    }

    @Test func pickOpenDefaultsToBlockingWithoutOptionalArgs() throws {
        let command = try Pick.Open.parse([])
        let items = [ControlPickItem(id: "One", label: "One")]

        #expect(try command.makeRequest(input: Data("One\n".utf8)) ==
            ControlRequest(cmd: .pickOpen, args: ControlArgs(items: items)))
        #expect(!command.noBlock)
    }

    @Test func pickOpenComposesTheItemlessRenameRequest() throws {
        let command = try Pick.Open.parse(["--allow-custom", "--query", "old name"])

        #expect(try command.makeRequest(input: Data()) == ControlRequest(
            cmd: .pickOpen,
            args: ControlArgs(items: [], query: "old name", allowCustom: true)
        ))
    }

    @Test func pickResultMapsIDAndWindow() throws {
        #expect(try request(["pick", "result", "pick-1", "--window", "w1"]) ==
            ControlRequest(cmd: .pickResult, target: "pick-1", args: ControlArgs(window: "w1")))
    }

    @Test func pickCancelMapsIDAndWindow() throws {
        #expect(try request(["pick", "cancel", "pick-1", "--window", "w1"]) ==
            ControlRequest(cmd: .pickCancel, target: "pick-1", args: ControlArgs(window: "w1")))
    }

    @Test func pickOpenHasNoTimeoutOption() {
        #expect(throws: (any Error).self) {
            try Rookctl.parseAsRoot(["pick", "--timeout", "60"])
        }
    }

    // MARK: - formatting and exit mapping

    @Test func formatsPickIDAsJSON() throws {
        let line = try Pick.formatPickID("pick-1")
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])

        #expect(object == ["id": "pick-1"])
    }

    @Test func formatsPickResultAsJSON() throws {
        let result = ControlPickResult(result: .picked, id: "two", label: "Two", index: 1)
        let line = try Pick.formatPickResult(result)

        #expect(try JSONDecoder().decode(ControlPickResult.self, from: Data(line.utf8)) == result)
    }

    @Test(arguments: [
        (ControlPickOutcome.pending, Int32(1)),
        (.picked, Int32(0)),
        (.custom, Int32(0)),
        (.cancelled, Int32(2))
    ])
    func pickExitCodeMapsEveryOutcome(_ outcome: ControlPickOutcome, _ expected: Int32) {
        #expect(Pick.exitCode(for: outcome).rawValue == expected)
    }

    @Test func pickPollBackoffUsesTenFastSleepsThenSlowSleeps() {
        #expect((1...10).map(Pick.pollDelay(afterPendingPoll:)) == Array(repeating: 0.1, count: 10))
        #expect(Pick.pollDelay(afterPendingPoll: 11) == 0.5)
        #expect(Pick.pollDelay(afterPendingPoll: 100) == 0.5)
    }

    // MARK: - the blocking poll

    @Test func pickNoBlockPrintsIDWithoutPolling() throws {
        let command = try Pick.Open.parse(["--no-block"])
        var requests: [ControlRequest] = []
        var output: [String] = []

        try command.execute(
            input: Data("One\n".utf8),
            send: { request in
                requests.append(request)
                return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
            },
            sleep: { _ in Issue.record("--no-block must not sleep") },
            output: { output.append($0) }
        )

        #expect(requests == [
            ControlRequest(
                cmd: .pickOpen,
                args: ControlArgs(items: [ControlPickItem(id: "One", label: "One")])
            )
        ])
        #expect(try JSONSerialization.jsonObject(with: Data(#require(output.first).utf8)) as? [String: String] ==
            ["id": "pick-1"])
    }

    @Test func pickBlockPollsWithBackoffPrintsResultAndExitsZero() throws {
        let command = try Pick.Open.parse(["--window", "w1"])
        var requests: [ControlRequest] = []
        var sleeps: [TimeInterval] = []
        var output: [String] = []
        var polls = 0

        try command.execute(
            input: Data("One\n".utf8),
            send: { request in
                requests.append(request)
                if request.cmd == .pickOpen {
                    return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                }
                polls += 1
                if polls <= 11 {
                    return ControlResponse(ok: true, result: ControlResult(
                        pick: ControlPickResult(result: .pending)
                    ))
                }
                return ControlResponse(ok: true, result: ControlResult(
                    pick: ControlPickResult(result: .picked, id: "One", label: "One", index: 0)
                ))
            },
            sleep: { sleeps.append($0) },
            output: { output.append($0) }
        )

        #expect(requests.dropFirst().allSatisfy {
            $0 == ControlRequest(cmd: .pickResult, target: "pick-1")
        })
        #expect(sleeps == Array(repeating: 0.1, count: 10) + [0.5])
        let result = try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        )
        #expect(result == ControlPickResult(result: .picked, id: "One", label: "One", index: 0))
    }

    @Test func pickBlockThrowsCancelledExitCodeAfterPrintingResult() throws {
        let command = try Pick.Open.parse([])
        var output: [String] = []

        do {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: true, result: ControlResult(
                            pick: ControlPickResult(result: .cancelled)
                        ))
                },
                sleep: { _ in Issue.record("a terminal result must not sleep") },
                output: { output.append($0) }
            )
            Issue.record("expected the cancelled exit code")
        } catch let code as ExitCode {
            #expect(code.rawValue == 2)
        }

        let result = try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        )
        #expect(result.result == .cancelled)
    }

    @Test func pickBlockFailsForOpenErrorAndMalformedResult() throws {
        let command = try Pick.Open.parse([])
        var errors: [String] = []
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { _ in ControlResponse(ok: false, error: "boom") },
                sleep: { _ in },
                output: { _ in Issue.record("a non-JSON server error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: boom"])

        errors.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: true)
                },
                sleep: { _ in },
                output: { _ in Issue.record("a protocol error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: pick.result missing result"])
    }

    @Test func pickBlockCancelsThePickerItCanNoLongerWaitOn() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []
        // ok, but with no pick payload: the server still holds the picker, so it must be dismissed.
        let malformedPoll: (ControlRequest) throws -> ControlResponse = { request in
            sent.append(request)
            return request.cmd == .pickOpen
                ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                : ControlResponse(ok: true)
        }

        #expect(throws: ExitCode.failure) {
            try command.execute(input: Data("One\n".utf8), send: malformedPoll,
                                sleep: { _ in }, output: { _ in }, errorOutput: { _ in })
        }
        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult, .pickCancel],
                "a poll that cannot continue must dismiss the picker it opened")
        #expect(sent.last?.target == "pick-1")

        sent.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    guard request.cmd != .pickCancel else { throw SocketClientError("socket gone") }
                    return try malformedPoll(request)
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }
        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult],
                "a failing cancel is best effort and must not replace the poll failure")
    }

    @Test func pickBlockDoesNotCancelWhenTheServerAlreadyLostThePicker() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    sent.append(request)
                    return request.cmd == .pickOpen
                        ? ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                        : ControlResponse(ok: false, error: "unknown pick: pick-1")
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }

        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult],
                "the poll carries no window selector, so a not-ok result means there is nothing left to cancel")
    }

    @Test func pickBlockCancelsWhenThePollItselfThrows() throws {
        let command = try Pick.Open.parse([])
        var sent: [ControlRequest] = []

        #expect(throws: SocketClientError.self) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { request in
                    sent.append(request)
                    switch request.cmd {
                    case .pickOpen: return ControlResponse(ok: true, result: ControlResult(id: "pick-1"))
                    case .pickResult: throw SocketClientError("no response from /tmp/rook.sock")
                    default: return ControlResponse(ok: true)
                    }
                },
                sleep: { _ in }, output: { _ in }, errorOutput: { _ in }
            )
        }

        #expect(sent.map(\.cmd) == [.pickOpen, .pickResult, .pickCancel],
                "a transport failure mid-wait must still dismiss the picker rather than leave it pending")
        #expect(sent.last?.target == "pick-1")
    }

    @Test func pickBlockRoutesJSONServerErrorThroughInjectedStdout() throws {
        let command = try Pick.Open.parse(["--json"])
        var output: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                input: Data("One\n".utf8),
                send: { _ in ControlResponse(ok: false, error: "boom") },
                sleep: { _ in },
                output: { output.append($0) },
                errorOutput: { _ in Issue.record("a JSON server error must not use stderr") }
            )
        }

        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(#require(output.first).utf8))
        #expect(!response.ok)
        #expect(response.error == "boom")
    }

    // MARK: - the one-shot read

    @Test(arguments: [
        (ControlPickOutcome.picked, Int32(0)),
        (.custom, Int32(0)),
        (.pending, Int32(1)),
        (.cancelled, Int32(2)),
    ])
    func pickResultExecutesRequestPrintsJSONAndMapsExit(
        _ outcome: ControlPickOutcome,
        _ expectedExit: Int32
    ) throws {
        let command = try Pick.Result.parse(["pick-1", "--window", "w1"])
        var request: ControlRequest?
        var output: [String] = []
        let run = {
            try command.execute(
                send: {
                    request = $0
                    return ControlResponse(ok: true, result: ControlResult(
                        pick: ControlPickResult(result: outcome)
                    ))
                },
                output: { output.append($0) }
            )
        }

        if expectedExit == 0 {
            try run()
        } else {
            do {
                try run()
                Issue.record("expected mapped exit \(expectedExit)")
            } catch let code as ExitCode {
                #expect(code.rawValue == expectedExit)
            }
        }
        #expect(request == ControlRequest(
            cmd: .pickResult,
            target: "pick-1",
            args: ControlArgs(window: "w1")
        ))
        #expect(try JSONDecoder().decode(
            ControlPickResult.self,
            from: Data(#require(output.first).utf8)
        ).result == outcome)
    }

    @Test func pickResultRoutesServerAndProtocolErrorsThroughInjectedStderr() throws {
        let command = try Pick.Result.parse(["pick-1"])
        var errors: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: false, error: "boom") },
                output: { _ in Issue.record("a non-JSON server error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: boom"])

        errors.removeAll()
        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: true) },
                output: { _ in Issue.record("a protocol error must not use stdout") },
                errorOutput: { errors.append($0) }
            )
        }
        #expect(errors == ["error: pick.result missing result"])
    }

    @Test func pickResultRoutesJSONServerErrorThroughInjectedStdout() throws {
        let command = try Pick.Result.parse(["pick-1", "--json"])
        var output: [String] = []

        #expect(throws: ExitCode.failure) {
            try command.execute(
                send: { _ in ControlResponse(ok: false, error: "boom") },
                output: { output.append($0) },
                errorOutput: { _ in Issue.record("a JSON server error must not use stderr") }
            )
        }

        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(#require(output.first).utf8))
        #expect(!response.ok)
        #expect(response.error == "boom")
    }
}
