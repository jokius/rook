import rookCore
import AppKit
import SwiftUI
import os

// category stays "SettingsView": this view was split out of `SettingsView.swift` and its one log line
// is unchanged, so the emitted log keeps its existing identity.
private let logger = Logger(subsystem: "com.rook.app", category: "SettingsView")

/// Agent Status tab: a Glyphs section (one row per status — its sidebar tint AND its silhouette), a
/// Sound section (the blocked sound), an Auto-follow section (the idle-timeout picker +
/// stay-on-active toggle), and a trailing Reset that clears the colors and sound back to their defaults.
struct AgentStatusSettingsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Glyphs") {
                glyphRow(.active)
                glyphRow(.blocked)
                glyphRow(.completed)
                Toggle("Highlight blocked and completed rows", isOn: statusRowHighlightEnabled)
                    .accessibilityIdentifier("settings-status-row-highlight")
            }

            Section("Sound") {
                Picker("Blocked sound", selection: blockedStatusSound) {
                    Text("None").tag("None")
                    ForEach(StatusSoundPlayer.standardNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .accessibilityIdentifier("settings-status-blocked-sound")
            }

            Section("Auto-follow") {
                Picker("Auto-follow blocked sessions", selection: autoFollowAttention) {
                    Text("Disabled").tag(AppSettings.AutoFollowAttention.off)
                    Text("5 sec idle").tag(AppSettings.AutoFollowAttention.s5)
                    Text("10 sec idle").tag(AppSettings.AutoFollowAttention.s10)
                    Text("30 sec idle").tag(AppSettings.AutoFollowAttention.s30)
                    Text("60 sec idle").tag(AppSettings.AutoFollowAttention.s60)
                    Text("5 min idle").tag(AppSettings.AutoFollowAttention.m5)
                }
                .accessibilityIdentifier("settings-auto-follow")
                Toggle("Auto-follow away from a running session", isOn: autoFollowAwayFromRunning)
                    .accessibilityIdentifier("settings-auto-follow-stay-active")
                    .disabled(autoFollowAttention.wrappedValue == .off)
                SettingHint("Only applies while auto-follow is on.")
            }

            Section("Quitting") {
                Stepper(value: agentQuitGrace, in: 0 ... 30, step: 1) {
                    Text("Let agents wrap up: \(agentQuitGraceLabel)")
                }
                .accessibilityIdentifier("settings-agent-quit-grace")
                SettingHint("On quit, rook tells agents that are mid-turn to wrap up and waits for them, "
                            + "closing early once they finish. Needs the agent-status hooks installed. "
                            + "0 turns this off; long values visibly delay a system logout.")
            }

            Section {
                Button("Reset to defaults") { model.resetAgentStatus() }
                    .accessibilityIdentifier("settings-status-reset")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// One status' glyph controls: its tint well and its silhouette picker. Everything — both bindings and
    /// both accessibility identifiers — derives from `status`, so a row cannot label one state while
    /// driving another's setting. The status name is the row's only visible text: both controls hide their
    /// own labels, which is what keeps the two-control cluster inside one Form row.
    private func glyphRow(_ status: AgentStatus) -> some View {
        let tint = statusColor(for: status)
        return HStack {
            Text(status.rawValue.capitalized)
            Spacer()
            ColorPicker("Color", selection: tint, supportsOpacity: false)
                .labelsHidden()
                .accessibilityIdentifier("settings-status-\(status.rawValue)")
            shapePicker(for: status, tint: tint.wrappedValue)
        }
    }

    /// The per-status silhouette picker: a symbol-only menu of Default + the six `StatusShape`s, each drawn
    /// in the ROW's own tint (re-picking a color rebuilds the options, since they read the same binding).
    /// No text beside the symbol — the silhouette is the thing being picked, and a name would crowd the row
    /// — so each option carries its name as an accessibility label only.
    private func shapePicker(for status: AgentStatus, tint: Color) -> some View {
        let selection = statusShape(for: status)
        return Picker("Shape", selection: selection) {
            // Default renders the status' OWN semantic glyph, which is what makes a purely symbolic menu
            // self-explanatory: rook keeps meaningful defaults (ellipsis / exclamationmark / checkmark), so
            // "no shape" is a real, distinct option and not a synonym for Circle.
            shapeOption(nil, symbol: status.symbolName(override: nil, configured: nil), label: Self.defaultShapeLabel, tint: tint)
            ForEach(StatusShape.allCases, id: \.self) { shape in
                shapeOption(shape, symbol: shape.symbolName, label: Self.label(for: shape), tint: tint)
            }
        }
        .labelsHidden()
        .frame(width: Self.shapeColumnWidth, alignment: .trailing)
        .accessibilityIdentifier("settings-status-shape-\(status.rawValue)")
        .accessibilityValue(selection.wrappedValue.map(Self.label(for:)) ?? Self.defaultShapeLabel)
    }

    @ViewBuilder
    private func shapeOption(_ shape: StatusShape?, symbol: String, label: String, tint: Color) -> some View {
        if let image = Self.tintedSymbol(symbol, tint: tint) {
            image
                .accessibilityLabel(label)
                .tag(shape)
        }
    }

    /// An SF Symbol rendered in `tint` for a picker option. `isTemplate = false` is load-bearing: a menu
    /// recolors a TEMPLATE symbol to its own text color, which would wash out the very tint the option is
    /// previewing. An unresolvable symbol is logged and dropped rather than shown as a blank option — the
    /// names come from `AgentStatus`/`StatusShape`, so this only fires on an OS missing one of them.
    private static func tintedSymbol(_ name: String, tint: Color) -> Image? {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(tint)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            logger.error("agent status shape symbol did not resolve: \(name, privacy: .public)")
            return nil
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }

    /// Reserved width for the shape column. A menu Picker sizes itself to the glyph it currently shows, so
    /// an unreserved column makes the three color wells jog horizontally as different silhouettes are
    /// picked. This clears the widest option (a 13pt `capsule.fill` plus the popup's chevron and insets)
    /// with room to spare, and `alignment: .trailing` pins the button to the column's right edge so the
    /// cluster ends flush with the Sound and Auto-follow pickers instead of floating inboard.
    private static let shapeColumnWidth: CGFloat = 72

    private static let defaultShapeLabel = "Default"

    /// Display name of a shape, for the option's accessibility label and the picker's accessibility value.
    private static func label(for shape: StatusShape) -> String { shape.rawValue.capitalized }

    /// The tint of one status row: the stored hex, else that status' built-in default (the same fallbacks
    /// `GhosttyApp.setAgentStatusColors` resolves). One switch per status pairs the getter, the default and
    /// the setter, so a row cannot read one status' color and write another's; a pick stores the sRGB hex
    /// and "Reset to defaults" clears it back to nil. `idle` renders no glyph and has no row.
    private func statusColor(for status: AgentStatus) -> Binding<Color> {
        switch status {
        case .active:
            return Binding(get: { Self.color(model.settings.activeStatusColorHex, or: GhosttyApp.defaultActiveStatusColor) },
                           set: { model.setActiveStatusColorHex(NSColor($0).rookHexString) })
        case .blocked:
            return Binding(get: { Self.color(model.settings.blockedStatusColorHex, or: .systemOrange) },
                           set: { model.setBlockedStatusColorHex(NSColor($0).rookHexString) })
        case .completed:
            return Binding(get: { Self.color(model.settings.completedStatusColorHex, or: .systemGreen) },
                           set: { model.setCompletedStatusColorHex(NSColor($0).rookHexString) })
        case .idle:
            return .constant(.clear)
        }
    }

    private static func color(_ hex: String?, or fallback: NSColor) -> Color {
        Color(nsColor: NSColor(rookHex: hex) ?? fallback)
    }

    /// The configured silhouette of one status, nil meaning the semantic default glyph. Reads through the
    /// host-free resolver (so an unset or unparseable stored value reads as Default, exactly as it renders)
    /// and writes through that status' setter — nil clears the key, keeping settings.json minimal.
    private func statusShape(for status: AgentStatus) -> Binding<StatusShape?> {
        Binding(get: { model.settings.effectiveStatusShape(for: status) },
                set: { shape in
                    switch status {
                    case .active: model.setActiveStatusShape(shape)
                    case .blocked: model.setBlockedStatusShape(shape)
                    case .completed: model.setCompletedStatusShape(shape)
                    case .idle: break
                    }
                })
    }

    /// 1:1 with the toggle; nil (the default) reads as on, so settings.json stays minimal until the user
    /// turns the row wash off. `active` rows are never washed either way — only the attention states.
    private var statusRowHighlightEnabled: Binding<Bool> {
        Binding(get: { model.settings.statusRowHighlightEnabled ?? true },
                set: { model.setStatusRowHighlightEnabled($0 ? nil : false) })
    }

    // the system sound played when a session enters `blocked`; "None" maps to nil. Selecting a sound
    // previews it so you hear the choice, the way macOS sound settings do.
    private var blockedStatusSound: Binding<String> {
        Binding(get: { model.settings.blockedStatusSoundName ?? "None" },
                set: { name in
                    let value = name == "None" ? nil : name
                    model.setBlockedStatusSoundName(value)
                    if let value { StatusSoundPlayer.shared.action(for: value)?() }
                })
    }

    /// The auto-follow idle timeout; nil (the default) reads as `.off`, and picking `.off` stores nil so
    /// settings.json stays minimal. An unknown stored value also resolves to `.off`.
    private var autoFollowAttention: Binding<AppSettings.AutoFollowAttention> {
        Binding(get: { AppSettings.AutoFollowAttention(tolerant: model.settings.autoFollowAttention) },
                set: { model.setAutoFollowAttention($0 == .off ? nil : $0.rawValue) })
    }

    /// The quit-time drain budget in seconds; the default maps back to nil so settings.json stays
    /// minimal, matching the other "unset = default" controls. 0 is the user's off switch and IS stored —
    /// it is a real choice, not the default.
    private var agentQuitGrace: Binding<Double> {
        Binding(get: { model.settings.effectiveAgentQuitGraceSeconds },
                set: { model.setAgentQuitGraceSeconds($0 == AppSettings.defaultAgentQuitGraceSeconds ? nil : $0) })
    }

    /// The budget as the stepper shows it: "Off" at 0 (a duration reading "0s" would look like a bug),
    /// else the seconds.
    private var agentQuitGraceLabel: String {
        let seconds = Int(model.settings.effectiveAgentQuitGraceSeconds)
        return seconds == 0 ? "Off" : "\(seconds)s"
    }

    /// Inverted view of the stored `autoFollowStayOnActive` so the toggle reads forward ("auto-follow away"
    /// ON = do leave a running session) instead of a double negative. The stored default nil means "follow
    /// away", so the toggle shows ON by default; opting to STAY (toggle OFF) stores `true`, and toggling back
    /// to the follow-away default stores nil to keep settings.json minimal.
    private var autoFollowAwayFromRunning: Binding<Bool> {
        Binding(get: { !(model.settings.autoFollowStayOnActive ?? false) },
                set: { model.setAutoFollowStayOnActive($0 ? nil : true) })
    }
}
