import ArgumentParser
import Foundation
import agtermCore

// MARK: - workspace

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Workspace commands.",
        subcommands: [New.self, Rename.self, Delete.self, Select.self, Move.self, Focus.self, Color.self, Icon.self]
    )

    struct New: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Create a workspace.")
        @Argument(help: "Workspace name (defaults to the auto-generated name).") var name: String?
        @OptionGroup var options: ClientOptions
        var echoesResultID: Bool { true }

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

    struct Move: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Reorder a workspace among its siblings.")
        @Option(name: .long, help: "Direction: up, down, top, or bottom.") var to: String
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceMove, target: target.target, args: options.withWindow(ControlArgs(to: to)))
        }
    }

    struct Focus: RequestCommand {
        static let configuration = CommandConfiguration(abstract: "Focus the sidebar on a single workspace (on|off|toggle).")
        @Argument(help: "Mode: on (focus), off (unfocus), or toggle (default).") var mode: String = "toggle"
        @OptionGroup var target: TargetOptions
        @OptionGroup var options: ClientOptions

        func validate() throws {
            guard ["on", "off", "toggle"].contains(mode) else {
                throw ValidationError("mode must be on, off, or toggle")
            }
        }

        func makeRequest() throws -> ControlRequest {
            ControlRequest(cmd: .workspaceFocus, target: target.target, args: options.withWindow(ControlArgs(mode: mode)))
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
}
