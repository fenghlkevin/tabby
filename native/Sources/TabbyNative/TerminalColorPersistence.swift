import Foundation

extension Preferences {
    /// The color editor has its own save boundary. Other settings remain drafts.
    func replacingTerminalColors(from colors: Preferences) -> Preferences {
        var value = self
        value.terminalTheme = colors.terminalTheme
        value.foreground = colors.foreground
        value.background = colors.background
        value.cursorColor = colors.cursorColor
        value.ansiColors = colors.ansiColors
        value.customTerminalThemes = colors.customTerminalThemes
        return value
    }
}

@MainActor extension AppStore {
    func commitTerminalColors(_ colors: Preferences) throws {
        try commitPreferences(workspace.preferences.replacingTerminalColors(from: colors))
    }
}
