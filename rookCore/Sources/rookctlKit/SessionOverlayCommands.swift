import ArgumentParser
import Foundation
import rookCore

/// The two occupants of a session's overlay SLOT, as `rookctl session` subcommands: `overlay`, which runs a
/// caller's program in a temporary terminal, and `hud`, the passive message panel. Split out of
/// `SessionCommands.swift` for the file-size budget; `Overlay` moved here verbatim.
extension Session {
    struct Overlay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open, resize, or close an ephemeral overlay terminal on a session.",
            subcommands: [Open.self, Close.self, Resize.self, Result.self]
        )

        /// `--pane` validation for the overlay commands: `left|right` only, deliberately NOT the shared
        /// `validatePaneArgument`, which also accepts `scratch` — there is no scratch pane to cover, and
        /// reusing it would send `scratch` to the socket instead of failing as a usage error.
        static func validatePane(_ pane: String?) throws {
            if let pane, OverlayPane(controlName: pane) == nil {
                throw ValidationError("--pane must be left or right")
            }
        }

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open an overlay running COMMAND; it closes when COMMAND exits.")
            @Argument(help: "Program to run in the overlay (e.g. revdiff).") var command: String
            @Option(name: .long, help: "Working directory (default: the session's current directory).") var cwd: String?
            @Flag(name: .long, help: "Keep the overlay open after COMMAND exits (press any key to close).") var wait = false
            @Flag(name: .long, help: "Block until COMMAND exits and exit with its status (the program renders normally; capture its output via the program's own output file).") var block = false
            @Flag(name: .long, help: "Select (switch to) the target session after opening the overlay (default: open without switching).") var follow = false
            @Option(name: .long, help: "Render a floating, framed panel at PERCENT (1-100) of the pane instead of full-size.") var sizePercent: Int?
            @Option(name: .long, help: "Solid background color (#rrggbb) for the overlay pane, independent of the session's own.") var backgroundColor: String?
            @Option(name: .long, help: """
                Scope the overlay to ONE split pane (left or right), leaving the sibling pane live and \
                visible; omit for the session-wide overlay. A pane overlay is always full-pane, so this \
                cannot be combined with --size-percent.
                """)
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // reject the mutually-exclusive combos + a malformed color at parse time (before any connection),
            // so it's a clean usage error and is unit-testable without a socket.
            func validate() throws {
                if block && wait { throw ValidationError("--block cannot be combined with --wait") }
                if let backgroundColor, !WatermarkConfig.isValidColorHex(backgroundColor) {
                    throw ValidationError("background-color must be a #rrggbb hex value")
                }
                try Overlay.validatePane(pane)
                if pane != nil, sizePercent != nil {
                    throw ValidationError("--pane cannot be combined with --size-percent (pane overlays are always full)")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayOpen, target: target.target,
                               args: options.withWindow(ControlArgs(cwd: cwd, command: command, wait: wait ? true : nil,
                                                                     sizePercent: sizePercent, follow: follow ? true : nil,
                                                                     pane: pane, color: backgroundColor)))
            }

            /// The `--block` poll request. Extracted from `run()` so the `--pane` forwarding is assertable
            /// without a live socket: polling a pane overlay with no pane reads the session-wide slot and
            /// blocks forever. No window scope — the returned id is globally unique and resolves cross-window,
            /// so a frontmost-window change during the run cannot make the poll miss the session.
            func resultRequest(id: String) -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: id, args: pane.map { ControlArgs(pane: $0) })
            }

            func run() throws {
                guard block else { try defaultRun(); return }
                let client = SocketClient(path: options.socketPath())
                // open via the same `makeRequest()` the non-block path uses (DRY): in block mode `validate()`
                // guarantees `!wait`, so its `wait` is nil — identical to opening non-wait, and the floating
                // `--size-percent` is carried through the single source instead of a duplicated ControlArgs.
                let opened = try client.send(requestForSending())
                guard opened.ok, let id = opened.result?.id else {
                    SocketClient.printResponse(opened, json: options.json)
                    throw ExitCode.failure
                }
                while true {
                    let res = try client.send(resultRequest(id: id))
                    if res.ok {
                        if options.json { SocketClient.printResponse(res, json: true) }
                        // a successful result must carry the status; its absence is a protocol violation, not success.
                        guard let code = res.result?.exitCode else {
                            FileHandle.standardError.write(Data("error: result missing exit code\n".utf8))
                            throw ExitCode.failure
                        }
                        throw ExitCode(rawValue: Int32(code))
                    }
                    if res.error == OverlayResultError.stillRunning {
                        Thread.sleep(forTimeInterval: 0.1)
                        continue
                    }
                    SocketClient.printResponse(res, json: options.json)
                    throw ExitCode.failure
                }
            }
        }

        struct Close: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Close the overlay terminal (destroys it).")
            @Option(name: .long, help: "Close that split pane's overlay (left or right); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Overlay.validatePane(pane) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayClose, target: target.target,
                               args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
            }
        }

        struct Resize: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Resize an open overlay: floating at a percent, or back to full-pane.")
            @Option(name: .long, help: "Resize to a floating, framed panel at PERCENT (1-100) of the pane.") var sizePercent: Int?
            @Flag(name: .long, help: "Resize to full-pane (translucent, hides the session).") var full = false
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            // require exactly one of --size-percent / --full at parse time (before any connection), so it is a
            // clean usage error and unit-testable without a socket; the dispatcher re-checks the same rules.
            func validate() throws {
                if full && sizePercent != nil { throw ValidationError("--full cannot be combined with --size-percent") }
                if !full && sizePercent == nil { throw ValidationError("provide --size-percent PERCENT or --full") }
                if let sizePercent, !(1...100).contains(sizePercent) {
                    throw ValidationError("--size-percent must be between 1 and 100")
                }
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResize, target: target.target,
                               args: options.withWindow(ControlArgs(sizePercent: sizePercent, full: full ? true : nil)))
            }
        }

        struct Result: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Print the overlay program's exit status (errors if it is still running or never ran).")
            @Option(name: .long, help: "Read that split pane's overlay status (left or right); omit for the session-wide overlay.")
            var pane: String?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws { try Overlay.validatePane(pane) }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayResult, target: target.target,
                               args: options.withWindow(pane.map { ControlArgs(pane: $0) }))
            }
        }
    }

    /// The passive message panel. `Open` is the default subcommand, so posting one is
    /// `rookctl session hud "gathering options…"`; a message that is literally `update` or `close` needs
    /// the explicit `hud open` verb. Message length and control characters are the dispatcher's to reject —
    /// only what needs no socket is checked here.
    struct Hud: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Post, update, or close a passive message panel over a session.",
            subcommands: [Open.self, Update.self, Close.self],
            defaultSubcommand: Open.self
        )

        /// `--position` help and validation both derive from `HudPosition`, so a new case reaches each.
        static func validatePosition(_ position: String?) throws {
            if let position, HudPosition(rawValue: position) == nil {
                throw ValidationError("position must be one of: \(HudPosition.validNamesPhrase)")
            }
        }

        /// Accepts `HudSpinner.noneName` beside the styles, exactly as the dispatcher does: `none` is what
        /// the read-back reports for a static panel, and refusing it here would make a value `tree` just
        /// handed the caller fail locally while the identical raw-socket request succeeds.
        static func validateSpinnerStyle(_ style: String?) throws {
            if let style, style != HudSpinner.noneName, HudSpinner(rawValue: style) == nil {
                throw ValidationError("spinner style must be one of: \(HudSpinner.acceptedNamesPhrase)")
            }
        }

        /// The one spinner value the socket carries, from the two ways to ask for one: `--spinner-style`
        /// names it and turns it on by itself, so the bare `--spinner` flag is only needed for the default.
        /// Nil when neither is given, which is the static panel.
        ///
        /// An explicit `--spinner-style none` also resolves to nil, and beats a bare `--spinner` beside it:
        /// naming a value is the more specific instruction, which is the same rule that makes a named style
        /// win over the flag's default.
        static func spinnerValue(spinner: Bool, style: String?) -> String? {
            if style == HudSpinner.noneName { return nil }
            return style ?? (spinner ? HudSpinner.defaultStyle.rawValue : nil)
        }

        static func validateSizePercent(_ sizePercent: Int?) throws {
            if let sizePercent, !(1...100).contains(sizePercent) {
                throw ValidationError("--size-percent must be between 1 and 100")
            }
        }

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Post a message panel over the session; the session keeps focus and stays typable.")
            @Argument(help: "Message shown in the panel.") var message: String
            @Option(name: .long, help: "Dim second line under the message (e.g. what the caller is waiting on).") var detail: String?
            @Flag(name: .long, help: "Animate a spinner glyph in the panel, in the default style.")
            var spinner = false
            @Option(name: .long, help: """
                Spinner style: \(HudSpinner.acceptedNamesPhrase) \
                (default: \(HudSpinner.defaultStyle.rawValue)). Implies --spinner; \
                \(HudSpinner.noneName) leaves the panel static.
                """)
            var spinnerStyle: String?
            @Option(name: .long, help: """
                Vertical placement: \(HudPosition.validNamesPhrase) (default: center). \
                top and bottom hold a fixed margin at the pane's edge.
                """)
            var position: String?
            @Option(name: .long, help: "Solid background color (#rrggbb) for the panel, independent of the session's own.") var backgroundColor: String?
            @Option(name: .long, help: """
                Set the panel's WIDTH to PERCENT (1-100) of the pane instead of measuring the message; \
                bounded to \(HudLayout.minSizePercent)-\(HudLayout.maxSizePercent), so it stays readable \
                and never covers the session. Height always follows the message.
                """)
            var sizePercent: Int?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                if let backgroundColor, !WatermarkConfig.isValidColorHex(backgroundColor) {
                    throw ValidationError("background-color must be a #rrggbb hex value")
                }
                try Hud.validatePosition(position)
                try Hud.validateSpinnerStyle(spinnerStyle)
                try Hud.validateSizePercent(sizePercent)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudOpen, target: target.target,
                               args: options.withWindow(ControlArgs(
                                   sizePercent: sizePercent, message: message, detail: detail,
                                   spinner: Hud.spinnerValue(spinner: spinner, style: spinnerStyle),
                                   color: backgroundColor, position: position)))
            }
        }

        /// Repaints the live panel in place. An update replaces the whole message, so every argument it
        /// accepts must be repeated to survive — including `--spinner`. `--background-color` is deliberately
        /// absent: the surface reads it once at creation, so only a fresh `hud` can change it.
        struct Update: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Replace the panel's text in place (no re-spawn, no blink).")
            @Argument(help: "New message; it replaces the old one entirely.") var message: String
            @Option(name: .long, help: "Dim second line under the message; omit to drop the old one.") var detail: String?
            @Flag(name: .long, help: "Keep (or start) the spinner in the default style; omit to stop it.")
            var spinner = false
            @Option(name: .long, help: """
                Switch the spinner to \(HudSpinner.acceptedNamesPhrase); implies --spinner, and repaints \
                the live panel without a re-spawn. \(HudSpinner.noneName) stops it.
                """)
            var spinnerStyle: String?
            @Option(name: .long, help: "Move the panel to \(HudPosition.validNamesPhrase) (default: center).") var position: String?
            @Option(name: .long, help: """
                Resize the panel's WIDTH to PERCENT (1-100) of the pane instead of measuring the message; \
                bounded to \(HudLayout.minSizePercent)-\(HudLayout.maxSizePercent), so it stays readable \
                and never covers the session. Height always follows the message.
                """)
            var sizePercent: Int?
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func validate() throws {
                try Hud.validatePosition(position)
                try Hud.validateSpinnerStyle(spinnerStyle)
                try Hud.validateSizePercent(sizePercent)
            }

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudUpdate, target: target.target,
                               args: options.withWindow(ControlArgs(
                                   sizePercent: sizePercent, message: message, detail: detail,
                                   spinner: Hud.spinnerValue(spinner: spinner, style: spinnerStyle),
                                   position: position)))
            }
        }

        struct Close: RequestCommand {
            static let configuration = CommandConfiguration(
                abstract: "Take the message panel down (a program overlay in the same slot is left alone).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionHudClose, target: target.target, args: options.withWindow())
            }
        }
    }
}
