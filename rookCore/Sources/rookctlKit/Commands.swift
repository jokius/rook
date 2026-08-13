import ArgumentParser
import Foundation
import rookCore

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
    /// Override the resolved socket path. Defaults to the `ROOK_STATE_DIR`/app-support rendezvous.
    @Option(name: .long, help: "Override the control socket path.")
    var socket: String?

    @Flag(name: .long, help: "Print the raw JSON response.")
    var json = false

    /// Resolve the socket path: explicit `--socket`, else the rookCore rendezvous resolver. Precedence:
    /// `--socket` → `<ROOK_STATE_DIR>/rook.sock` → `<$HOME>/Library/Application Support/rook/rook.sock` →
    /// `/tmp/rook/rook.sock`. `env` is injectable so the precedence is unit-testable; production passes the
    /// process environment.
    func socketPath(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let socket { return socket }
        let appSupport = (env["HOME"].map { ($0 as NSString).appendingPathComponent("Library/Application Support/rook") })
            ?? "/tmp/rook"
        return ControlResolve.socketPath(stateDir: env["ROOK_STATE_DIR"], appSupport: appSupport)
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

/// Options for batch-capable session commands. Repeating `--target` preserves CLI order on the wire.
struct BatchTargetOptions: ParsableArguments {
    @Option(name: .customLong("target"), help: "Target session id, prefix, or 'active'. Repeat for a batch.")
    var targets: [String] = []

    var batchTargets: [String]? { targets.count > 1 ? targets : nil }
}

/// The caller's shell, carried by the commands that spawn a session for WHOEVER ASKED
/// (`session new`, `window new`, `quick`) so the new shell matches the one the request came from.
/// `session duplicate`/`split`/`scratch` deliberately do NOT take it — those inherit the shell of the
/// session they belong to.
struct CallerShellOptions: ParsableArguments {
    @Option(name: .long, help: "Shell to spawn, as an absolute path (defaults to the caller's $SHELL).")
    var shell: String?

    /// The value to put on the wire: the explicit flag, else `$SHELL` from the passed environment. An
    /// unset, empty, or blank `$SHELL` sends NOTHING, so the request stays byte-identical to a pre-feature
    /// one instead of tripping the server's format check on an environment the caller never set.
    ///
    /// The environment is a parameter, never read here from `ProcessInfo`: this runs on the SEND path
    /// (`requestForSending`), not while `makeRequest()` builds, so a test can build a request without the
    /// runner's own `$SHELL` leaking into it.
    func resolved(env: [String: String]) -> String? {
        if let shell { return shell }
        let inherited = env["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (inherited?.isEmpty == false) ? inherited : nil
    }
}

/// The session `rookctl` itself is running in, read from the `ROOK_SESSION_ID` the app bakes into every
/// session shell. `session new` puts it on the wire so an unaddressed create lands in the CALLER's window
/// and workspace rather than in whatever the user happens to be looking at.
///
/// The environment is a parameter for the same reason `CallerShellOptions.resolved(env:)` takes one: this
/// runs on the SEND path, so `makeRequest()` stays pure and a test can build a request without the
/// runner's own environment leaking in. Blank/unset sends NOTHING, keeping the request byte-identical to a
/// pre-feature one — which is also the "called from outside rook" case.
enum CallerSession {
    static func resolved(env: [String: String]) -> String? {
        let value = env["ROOK_SESSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

/// Options for commands that address an individual terminal surface from `tree`.
struct SurfaceTargetOptions: ParsableArguments {
    @Option(name: .long, help: "Target surface id from tree, 'quick' (the quick terminal), or 'active'.")
    var target: String = "active"
}

/// The root `rookctl` command. Subcommands mirror the control catalog 1:1.
public struct Rookctl: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "rookctl",
        abstract: "Drive rook over its control socket.",
        subcommands: [Tree.self, Events.self, Workspace.self, Session.self, Surface.self, Dashboard.self,
                      Window.self, Quick.self,
                      Sidebar.self, Notify.self, Font.self, Keymap.self, Config.self, Theme.self, Pick.self,
                      Restore.self]
    )

    public init() {}
}

/// A subcommand that knows how to build the `ControlRequest` it should send. The default `run()`
/// sends it and prints the response; tests build the request directly via `makeRequest()`. `Options`
/// is `ClientOptions` for the window-targeting commands and `BasicOptions` for `window.*`.
protocol RequestCommand: ParsableCommand {
    associatedtype Options: ParsableArguments & ConnectionOptions
    var options: Options { get }
    /// Build the request from the PARSED FLAGS ALONE. Pure: it must never read the process environment,
    /// so a test can assert the exact wire form without the runner's own environment leaking into it —
    /// an environment-derived default belongs in `requestForSending(env:)`.
    func makeRequest() throws -> ControlRequest
    /// The request as actually SENT: `makeRequest()` plus any environment-derived default. The default
    /// implementation is `makeRequest()` verbatim; only the commands that spawn a shell for the caller
    /// override it, to fold in `$SHELL`. The environment is a parameter for the same reason
    /// `ConnectionOptions.socketPath(env:)` takes one.
    func requestForSending(env: [String: String]) throws -> ControlRequest
    /// Whether the human-readable output should echo `result.id`. Default false — the id is just noise
    /// when the caller already named the target; the create commands (`*.new`) override it to true,
    /// since the new id isn't known until the command runs. The id is always present under `--json`.
    var echoesResultID: Bool { get }
}

extension RequestCommand {
    var echoesResultID: Bool { false }
    public func run() throws { try defaultRun() }

    func requestForSending(env: [String: String]) throws -> ControlRequest { try makeRequest() }

    /// The send-path entry point, filling in the process environment.
    func requestForSending() throws -> ControlRequest {
        try requestForSending(env: ProcessInfo.processInfo.environment)
    }

    /// Stamp the caller's shell onto the built request — the whole body of the three overrides, so the
    /// "explicit `--shell`, else `$SHELL`, else nothing" rule has one home.
    ///
    /// The bag is MATERIALIZED rather than reached through `args?.shell`, which would silently drop the
    /// shell for a command that built no bag. Nothing to stamp still leaves `args` exactly as it was, so a
    /// bag-less request keeps its compact wire form instead of growing an empty `args` object.
    func requestCarryingCallerShell(_ callerShell: CallerShellOptions,
                                    env: [String: String]) throws -> ControlRequest {
        var request = try makeRequest()
        guard let shell = callerShell.resolved(env: env) else { return request }
        var args = request.args ?? ControlArgs()
        args.shell = shell
        request.args = args
        return request
    }

    /// The default behavior: send the request once and print the response. Named separately so a command
    /// that overrides `run()` (the `--block` overlay path) can still reach the single-round-trip path.
    func defaultRun() throws {
        let request = try requestForSending()
        let client = SocketClient(path: options.socketPath())
        let response = try client.send(request)
        SocketClient.printResponse(response, json: options.json, echoID: echoesResultID)
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
