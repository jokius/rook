import SwiftUI

/// The Settings window (Cmd+,): three tabs — General and Key Mapping are placeholders for later
/// phases; Appearance holds the font family, default font size, and ghostty theme.
struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        TabView {
            PlaceholderSettings(message: "General settings coming soon.")
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView(model: model)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            PlaceholderSettings(message: "Key mapping coming soon.")
                .tabItem { Label("Key Mapping", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 320)
    }
}

/// Appearance tab: font family, default font size, theme. Each control persists and live-applies
/// through `SettingsModel`.
private struct AppearanceSettingsView: View {
    let model: SettingsModel
    private let themes = SettingsCatalog.themeNames()
    private let fonts = SettingsCatalog.monospacedFontFamilies()

    var body: some View {
        Form {
            Picker("Font", selection: fontFamily) {
                Text("Default").tag(String?.none)
                ForEach(fonts, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .accessibilityIdentifier("settings-font-family")

            Stepper(value: fontSize, in: 8 ... 32, step: 1) {
                Text("Default font size: \(Int(model.settings.fontSize ?? 13))")
            }
            .accessibilityIdentifier("settings-font-size")

            Picker("Theme", selection: theme) {
                Text("Default").tag(String?.none)
                ForEach(themes, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .accessibilityIdentifier("settings-theme")
        }
        .formStyle(.grouped)
        .padding()
    }

    private var fontFamily: Binding<String?> {
        Binding(get: { model.settings.fontFamily }, set: { model.setFontFamily($0) })
    }

    private var fontSize: Binding<Double> {
        Binding(get: { model.settings.fontSize ?? 13 }, set: { model.setFontSize($0) })
    }

    private var theme: Binding<String?> {
        Binding(get: { model.settings.theme }, set: { model.setTheme($0) })
    }
}

private struct PlaceholderSettings: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
