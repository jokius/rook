import ArgumentParser
import Foundation
import agtCore

/// The connection/print surface every subcommand shares: where to connect and how to print. The
/// `RequestCommand.run()` default drives only these, so a command's options can be `BasicOptions`
/// (socket/json only, for `window.*` which target via the positional id) or `ClientOptions` (those
/// plus `--window`).
protocol ConnectionOptions {
    /// Print the raw JSON response instead of a human-readable line.
    var json: Bool { get }

    /// Resolve the socket path from `--socket` and the environment.
    func socketPath(env: [String: String]) -> String
}

extension ConnectionOptions {
    func socketPath() -> String { socketPath(env: ProcessInfo.processInfo.environment) }
}

/// Where to connect and how to print — the options every subcommand accepts. `window.*` commands use
/// this directly (they target via the positional id, so `--window` has no meaning for them); the
/// session/workspace/tree/font commands layer `--window` on top via `ClientOptions`.
struct BasicOptions: ParsableArguments, ConnectionOptions {
    /// Override the resolved socket path. Defaults to the `AGT_STATE_DIR`/app-support rendezvous.
    @Option(name: .long, help: "Override the control socket path.")
    var socket: String?

    @Flag(name: .long, help: "Print the raw JSON response.")
    var json = false

    /// Resolve the socket path: explicit `--socket`, else the agtCore rendezvous resolver. Precedence:
    /// `--socket` → `<AGT_STATE_DIR>/agt.sock` → `<$HOME>/Library/Application Support/agt/agt.sock` →
    /// `/tmp/agt/agt.sock`. `env` is injectable so the precedence is unit-testable; production passes the
    /// process environment.
    func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let socket { return socket }
        let appSupport = (env["HOME"].map { ($0 as NSString).appendingPathComponent("Library/Application Support/agt") })
            ?? "/tmp/agt"
        return ControlResolve.socketPath(stateDir: env["AGT_STATE_DIR"], appSupport: appSupport)
    }
}

/// `BasicOptions` plus the `--window` selector for the commands that operate on a window's tree.
struct ClientOptions: ParsableArguments, ConnectionOptions {
    @OptionGroup var basic: BasicOptions

    /// Target window for session/workspace/tree/font commands: id / prefix / `active` (=frontmost).
    /// Selects the window whose tree the command operates on; maps to `ControlArgs.window`.
    @Option(name: .long, help: "Target window id, unique prefix, or 'active' (defaults to the frontmost).")
    var window: String?

    var json: Bool { basic.json }

    func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String { basic.socketPath(env: env) }

    /// Fold the `--window` selector into an existing args bag, or build one carrying only the window.
    /// Returns `nil` when there is no window and no base bag, so the request stays in its compact form
    /// (no empty `args` object on the wire) and matches the no-window request value.
    func withWindow(_ base: ControlArgs? = nil) -> ControlArgs? {
        guard window != nil else { return base }
        var args = base ?? ControlArgs()
        args.window = window
        return args
    }
}

/// Options for the commands that address a single session or workspace; `--target` defaults to `active`.
struct TargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target session/workspace id, unique prefix, or 'active'.")
    var target: String = "active"
}

/// The root `agtctl` command. Subcommands mirror the control catalog 1:1.
public struct Agtctl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "agtctl",
        abstract: "Drive agt over its control socket.",
        subcommands: [Tree.self, Workspace.self, Session.self, Window.self, Quick.self, Font.self]
    )

    public init() {}
}

/// A subcommand that knows how to build the `ControlRequest` it should send. The default `run()`
/// sends it and prints the response; tests build the request directly via `makeRequest()`. `Options`
/// is `ClientOptions` for the window-targeting commands and `BasicOptions` for `window.*`.
protocol RequestCommand: ParsableCommand {
    associatedtype Options: ParsableArguments & ConnectionOptions
    var options: Options { get }
    func makeRequest() throws -> ControlRequest
}

extension RequestCommand {
    public func run() throws {
        let request = try makeRequest()
        let client = SocketClient(path: options.socketPath())
        let response = try client.send(request)
        SocketClient.printResponse(response, json: options.json)
        if !response.ok { throw ExitCode.failure }
    }
}

// MARK: - tree

struct Tree: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Print the workspace/session tree.")
    @OptionGroup var options: ClientOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .tree, args: options.withWindow())
    }
}

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceNew, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a workspace.")
        @Argument(help: "New workspace name.") var name: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceRename, target: target.target, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceDelete, target: target.target, args: options.withWindow())
        }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select a workspace.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceSelect, target: target.target, args: options.withWindow())
        }
    }
}

// MARK: - session

struct Session: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Session commands.",
        subcommands: [New.self, Close.self, Select.self, Rename.self, Move.self, TypeText.self, Split.self, Focus.self, Copy.self, Overlay.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a session.")
        @Option(name: .long, help: "Working directory (defaults to $HOME).") var cwd: String?
        @Option(name: .long, help: "Target workspace id/prefix (defaults to the current one).") var workspace: String?
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionNew, args: options.withWindow(ControlArgs(cwd: cwd, workspace: workspace)))
        }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a session.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionClose, target: target.target, args: options.withWindow())
        }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select a session.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSelect, target: target.target, args: options.withWindow())
        }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a session.")
        @Argument(help: "New session name.") var name: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionRename, target: target.target, args: options.withWindow(ControlArgs(name: name)))
        }
    }

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Move a session to another workspace.")
        @Argument(help: "Destination workspace id/prefix.") var workspace: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionMove, target: target.target, args: options.withWindow(ControlArgs(workspace: workspace)))
        }
    }

    struct TypeText: RequestCommand {
        static let configuration = CommandConfiguration(commandName: "type", abstract: "Inject text into a session.")
        @Argument(help: "Text to inject (omit with --stdin).") var text: String?
        @Flag(name: .long, help: "Read the text from stdin instead of an argument.") var stdin = false
        @Flag(name: .long, help: "Select (and realize) a never-shown session before injecting.") var select = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            let payload: String
            if stdin {
                // non-UTF8 stdin decodes to nil and injects nothing — terminal input is UTF-8 text.
                let data = FileHandle.standardInput.readDataToEndOfFile()
                payload = String(data: data, encoding: .utf8) ?? ""
            } else if let text {
                payload = text
            } else {
                throw ValidationError("provide TEXT or --stdin")
            }
            return ControlRequest(cmd: .sessionType, target: target.target,
                                  args: options.withWindow(ControlArgs(text: payload, select: select)))
        }
    }

    struct Split: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Split a session (on|off|toggle).")
        @Argument(help: "Mode: on, off, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionSplit, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Focus a split session's pane (left|right|other).")
        @Argument(help: "Pane: left, right, or other (toggle, default).") var pane: String = "other"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionFocus, target: target.target, args: options.withWindow(ControlArgs(pane: pane)))
        }
    }

    struct Copy: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Print a session's selected text (does not touch the system clipboard).")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .sessionCopy, target: target.target, args: options.withWindow())
        }
    }

    struct Overlay: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Open or close an ephemeral overlay terminal on a session.",
            subcommands: [Open.self, Close.self]
        )

        struct Open: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Open an overlay running COMMAND; it closes when COMMAND exits.")
            @Argument(help: "Program to run in the overlay (e.g. revdiff).") var command: String
            @Option(name: .long, help: "Working directory (default: the session's current directory).") var cwd: String?
            @Flag(name: .long, help: "Keep the overlay open after COMMAND exits (press any key to close).") var wait = false
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayOpen, target: target.target,
                               args: options.withWindow(ControlArgs(cwd: cwd, command: command, wait: wait ? true : nil)))
            }
        }

        struct Close: RequestCommand {
            static let configuration = CommandConfiguration(abstract: "Close the overlay terminal (destroys it).")
            @OptionGroup var target: TargetOptions
            @OptionGroup var options: ClientOptions

            func makeRequest() throws -> ControlRequest {
                ControlRequest(cmd: .sessionOverlayClose, target: target.target, args: options.withWindow())
            }
        }
    }
}

// MARK: - window

struct Window: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Window commands.",
        subcommands: [New.self, List.self, Select.self, Close.self, Rename.self, Delete.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create and open a window.")
        @Argument(help: "Window name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowNew, args: ControlArgs(name: name))
        }
    }

    struct List: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "List windows (id, name, open, active).")
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowList) }
    }

    struct Select: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Select (raise or open) a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowSelect, target: id) }
    }

    struct Close: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Close a window (its bundle is kept).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowClose, target: id) }
    }

    struct Rename: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Rename a window.")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String
        @Argument(help: "New window name.") var name: String
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .windowRename, target: id, args: ControlArgs(name: name))
        }
    }

    struct Delete: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a window (keeps at least one).")
        @Argument(help: "Window id, unique prefix, or 'active'.") var id: String = "active"
        @OptionGroup var options: BasicOptions

        func makeRequest() throws -> ControlRequest { ControlRequest(cmd: .windowDelete, target: id) }
    }
}

// MARK: - quick

struct Quick: RequestCommand {
    static let configuration = CommandConfiguration(abstract: "Quick terminal (show|hide|toggle).")
    @Argument(help: "Mode: show, hide, or toggle (default).") var mode: String = "toggle"
    // the quick terminal is always the frontmost window's, so this carries no `--window` selector.
    @OptionGroup var options: BasicOptions

    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .quick, args: ControlArgs(mode: mode))
    }
}

// MARK: - font

struct Font: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Font size commands.",
        subcommands: [Inc.self, Dec.self, Reset.self]
    )

    struct Inc: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Increase font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontInc, target: target.target, args: options.withWindow())
        }
    }

    struct Dec: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Decrease font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontDec, target: target.target, args: options.withWindow())
        }
    }

    struct Reset: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reset font size.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .fontReset, target: target.target, args: options.withWindow())
        }
    }
}
