import ArgumentParser
import Foundation
import rookCore

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self, Move.self, Focus.self, Filter.self,
                      Color.self, Icon.self, Root.self, Collapse.self, Expand.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @Flag(name: .long, help: "Create the workspace collapsed in the sidebar.") var collapsed = false
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

        func makeRequest() throws -> ControlRequest {
            // false sends nothing: the flag is the opt-in, so the default stays byte-identical on the wire.
            ControlRequest(cmd: .workspaceNew,
                           args: options.withWindow(ControlArgs(name: name, collapsed: collapsed ? true : nil)))
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

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reorder a workspace among its siblings.")
        @Option(name: .long, help: "Direction: up, down, top, or bottom.") var to: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceMove, target: target.target, args: options.withWindow(ControlArgs(to: to)))
        }
    }

    /// `rookctl workspace focus [on|off|toggle|add] [--target W]` — marks or unmarks ONE workspace in the
    /// sidebar's focus set. `add` only marks; applying the set is `workspace filter on`. The accepted list,
    /// the per-mode help prose, and the local rejection message ALL derive from
    /// `ControlWorkspaceFocusMode.allCases` (via `validNamesList`/`helpPhrase`/`validNamesPhrase`), so a
    /// new case reaches every one of them and the CLI cannot drift from the dispatcher's parse.
    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a workspace in the sidebar focus set (\(ControlWorkspaceFocusMode.validNamesList))."
        )
        @Argument(help: "Mode: \(ControlWorkspaceFocusMode.helpPhrase).")
        var mode: String = ControlWorkspaceFocusMode.toggle.rawValue
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ControlWorkspaceFocusMode(rawValue: mode) != nil else {
                throw ValidationError("mode must be one of: \(ControlWorkspaceFocusMode.validNamesPhrase)")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFocus, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    /// `rookctl workspace filter [on|off|toggle] [--window W]` — applies or lifts the sidebar's workspace
    /// focus filter for a WHOLE window, leaving the marked set intact. It deliberately carries NO
    /// `--target`: it flips the window's filter rather than acting on one workspace, so its shape is
    /// `sidebar expand`/`sidebar collapse` (`ClientOptions` only), not the `workspace.*` target commands.
    /// The three mode names are spelled out here rather than derived: `ControlToggleMode` carries no
    /// `validNames` because its tokens are per-command (`sidebar` spells the same three `show|hide|toggle`),
    /// so this matches its siblings (`session flag`, `sidebar mode`) instead of the enum-derived `Focus`.
    struct Filter: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Apply or lift the sidebar workspace focus filter, keeping the marked set (on|off|toggle)."
        )
        @Argument(help: "Mode: on, off, or toggle (default).") var mode: String = "toggle"
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ["on", "off", "toggle"].contains(mode) else {
                throw ValidationError("mode must be on, off, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFilter, args: options.withWindow(ControlArgs(mode: mode)))
        }
    }

    struct Color: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Color a workspace's sidebar icon (#rrggbb, or clear).")
        @Argument(help: "Color as #rrggbb, or `clear` to reset to the theme default.") var color: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard color == "clear" || WatermarkConfig.isValidColorHex(color) else {
                throw ValidationError("color must be #rrggbb or clear")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceColor, target: target.target, args: options.withWindow(ControlArgs(color: color)))
        }
    }

    struct Icon: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a workspace's sidebar icon (SF Symbol name, emoji, image file, or clear)."
        )
        @Argument(help: "An SF Symbol name (hammer.fill), a single emoji, a path to an svg/png/jpeg, or `clear`.")
        var icon: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            // only the local, host-free half: an image must be a supported format. Whether the file exists
            // and whether a symbol name resolves are answered by the app (filesystem + AppKit).
            guard icon != "clear", WorkspaceIcon.kind(forRawIcon: icon) == .image else { return }
            guard WorkspaceIcon.isSupportedImage(icon) else {
                throw ValidationError("icon image must be svg, png, or jpeg")
            }
        }

        func makeRequest() throws -> ControlRequest {
            // an image path is expanded + absolutized HERE: the app resolves it in its own working
            // directory, where a `~` or a relative path would not find the user's file.
            var value = icon
            if icon != "clear", WorkspaceIcon.kind(forRawIcon: icon) == .image {
                value = URL(fileURLWithPath: (icon as NSString).expandingTildeInPath).standardizedFileURL.path
            }
            return ControlRequest(cmd: .workspaceIcon, target: target.target,
                                  args: options.withWindow(ControlArgs(icon: value)))
        }
    }

    struct Root: RequestCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set a workspace's root directory (new sessions open there), or clear it."
        )
        @Argument(help: "A directory path, or `clear` to unset the root.") var dir: String?
        @Flag(name: .long, help: "Clear the workspace's root directory.") var clear: Bool = false
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard dir != nil || clear else {
                throw ValidationError("provide a directory path, or --clear")
            }
        }

        func makeRequest() throws -> ControlRequest {
            // `--clear` (or a literal `clear`) sends no path; the dispatcher treats a nil/`clear` path as
            // clear. Otherwise absolutize like Icon: the app resolves the path in its own working directory.
            var path: String?
            if !clear, let dir, dir != "clear" {
                path = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).standardizedFileURL.path
            }
            return ControlRequest(cmd: .workspaceRoot, target: target.target,
                                  args: options.withWindow(ControlArgs(path: path)))
        }
    }

    struct Collapse: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Collapse a workspace in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceCollapse, target: target.target, args: options.withWindow())
        }
    }

    struct Expand: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Expand a workspace in the sidebar tree.")
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceExpand, target: target.target, args: options.withWindow())
        }
    }
}
