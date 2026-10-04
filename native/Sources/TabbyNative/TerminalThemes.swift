import Foundation

/// Complete terminal palettes. The four original schemes retain their original
/// values for saved settings compatibility. New scheme sources:
/// Nord: https://www.nordtheme.com/docs/colors-and-palettes/
/// Solarized: https://github.com/altercation/solarized
/// Catppuccin (MIT): https://github.com/catppuccin/palette/blob/main/palette.json
struct TerminalTheme: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    let foreground: String
    let background: String
    let cursor: String
    let ansi: [String]
    static let all: [TerminalTheme] = [
        .init(id: "draculaGreen", name: "Dracula Green", foreground: "#00CC74", background: "#1e1f29", cursor: "#bbbbbb", ansi: Palette.ansi),
        .init(id: "dracula", name: "Dracula", foreground: "#f8f8f2", background: "#282a36", cursor: "#f8f8f2", ansi: Palette.ansi),
        .init(id: "solarizedDark", name: "Solarized Dark", foreground: "#839496", background: "#002b36", cursor: "#93a1a1", ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        .init(id: "light", name: "Light", foreground: "#24292f", background: "#ffffff", cursor: "#0969da", ansi: ["#24292f", "#cf222e", "#116329", "#9a6700", "#0969da", "#8250df", "#1b7c83", "#6e7781", "#57606a", "#a40e26", "#1a7f37", "#bf8700", "#218bff", "#a475f9", "#3192aa", "#d0d7de"]),
        .init(id: "solarizedLight", name: "Solarized Light", foreground: "#657b83", background: "#fdf6e3", cursor: "#586e75", ansi: ["#073642", "#dc322f", "#859900", "#b58900", "#268bd2", "#d33682", "#2aa198", "#eee8d5", "#002b36", "#cb4b16", "#586e75", "#657b83", "#839496", "#6c71c4", "#93a1a1", "#fdf6e3"]),
        .init(id: "nord", name: "Nord", foreground: "#d8dee9", background: "#2e3440", cursor: "#d8dee9", ansi: ["#3b4252", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#88c0d0", "#e5e9f0", "#4c566a", "#bf616a", "#a3be8c", "#ebcb8b", "#81a1c1", "#b48ead", "#8fbcbb", "#eceff4"]),
        .init(id: "catppuccinLatte", name: "Catppuccin Latte", foreground: "#4c4f69", background: "#eff1f5", cursor: "#dc8a78", ansi: ["#5c5f77", "#d20f39", "#40a02b", "#df8e1d", "#1e66f5", "#ea76cb", "#179299", "#acb0be", "#6c6f85", "#de293e", "#49af3d", "#eea02d", "#456eff", "#fe85d8", "#2d9fa8", "#bcc0cc"]),
        .init(id: "catppuccinFrappe", name: "Catppuccin Frappe", foreground: "#c6d0f5", background: "#303446", cursor: "#f2d5cf", ansi: ["#51576d", "#e78284", "#a6d189", "#e5c890", "#8caaee", "#f4b8e4", "#81c8be", "#a5adce", "#626880", "#e67172", "#8ec772", "#d9ba73", "#7b9ef0", "#f2a4db", "#5abfb5", "#b5bfe2"]),
        .init(id: "catppuccinMacchiato", name: "Catppuccin Macchiato", foreground: "#cad3f5", background: "#24273a", cursor: "#f4dbd6", ansi: ["#494d64", "#ed8796", "#a6da95", "#eed49f", "#8aadf4", "#f5bde6", "#8bd5ca", "#a5adcb", "#5b6078", "#ec7486", "#8ccf7f", "#e1c682", "#78a1f6", "#f2a9dd", "#63cbc0", "#b8c0e0"]),
        .init(id: "catppuccinMocha", name: "Catppuccin Mocha", foreground: "#cdd6f4", background: "#1e1e2e", cursor: "#f5e0dc", ansi: ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8", "#585b70", "#f37799", "#89d88b", "#ebd391", "#74a8fc", "#f2aede", "#6bd7ca", "#bac2de"])
    ]
    var previewANSI: [String] { ansi.count == 16 ? ansi : Self.all[0].ansi }
    var isCustom: Bool { id.hasPrefix("custom-") }
    var isLight: Bool {
        let n = UInt32(background.dropFirst(), radix: 16) ?? 0
        return (0.2126 * Double((n >> 16) & 255) + 0.7152 * Double((n >> 8) & 255) + 0.0722 * Double(n & 255)) > 145
    }
    static func library(_ preferences: Preferences) -> [TerminalTheme] { all + preferences.customTerminalThemes }
    static func selected(_ preferences: Preferences) -> TerminalTheme { library(preferences).first { $0.id == preferences.terminalTheme } ?? all[0] }
    static func effectiveANSI(_ preferences: Preferences) -> [String] {
        if let colors = preferences.ansiColors, colors.count == 16 { return colors }
        return selected(preferences).previewANSI
    }
    func matches(_ preferences: Preferences) -> Bool {
        foreground.lowercased() == preferences.foreground.lowercased() && background.lowercased() == preferences.background.lowercased()
        && cursor.lowercased() == preferences.cursorColor.lowercased() && ansi.map { $0.lowercased() } == Self.effectiveANSI(preferences).map { $0.lowercased() }
    }
    func applying(to preferences: Preferences) -> Preferences {
        var result = preferences
        result.terminalTheme = id; result.foreground = foreground; result.background = background; result.cursorColor = cursor; result.ansiColors = ansi
        return result
    }
}


/// Library operations only edit a settings draft. The caller still has to Save;
/// Revert restores the complete previous library, selection and palette together.
enum TerminalThemeLibrary {
    static func isHex(_ color: String) -> Bool {
        color.count == 7 && color.first == "#" && color.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit }
    }
    static func validPalette(_ preferences: Preferences) -> Bool {
        let colors = TerminalTheme.effectiveANSI(preferences)
        return (preferences.ansiColors == nil || preferences.ansiColors?.count == 16) && colors.count == 16 && (colors + [preferences.foreground, preferences.background, preferences.cursorColor]).allSatisfy(isHex)
    }
    static func validate(_ preferences: Preferences, chinese: Bool) throws {
        func failure(_ en: String, _ zh: String) -> AppFailure { .message(chinese ? zh : en) }
        guard validPalette(preferences) else { throw failure("Use 16 ANSI colors and #RRGGBB values", "请填写完整 16 个 ANSI 色，并使用 #RRGGBB 格式") }
        guard preferences.customTerminalThemes.count <= 100 else { throw failure("Keep up to 100 custom schemes", "自定义配色方案最多 100 个") }
        var ids = Set<String>(), names = Set(TerminalTheme.all.map { $0.name.lowercased() })
        for theme in preferences.customTerminalThemes {
            guard theme.isCustom, UUID(uuidString: String(theme.id.dropFirst(7))) != nil, ids.insert(theme.id).inserted else { throw failure("Custom scheme identifiers must be unique", "自定义配色方案标识须唯一") }
            let name = try validatedName(theme.name, chinese: chinese)
            guard names.insert(name.lowercased()).inserted else { throw failure("Scheme names must be unique", "配色方案名称不能重复") }
            guard theme.ansi.count == 16, (theme.ansi + [theme.foreground, theme.background, theme.cursor]).allSatisfy(isHex) else { throw failure("A custom scheme needs 16 valid ANSI colors", "自定义配色须包含完整、有效的 16 个 ANSI 色") }
        }
    }
    static func validatedName(_ name: String, chinese: Bool) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 48, !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw AppFailure.message(chinese ? "名称须为 1–48 个字符，且不能包含换行或控制字符" : "Use 1–48 characters without newlines or control characters")
        }
        return name
    }
    static func uniqueName(_ name: String, excluding id: String? = nil, in preferences: Preferences, chinese: Bool) throws -> String {
        let name = try validatedName(name, chinese: chinese)
        guard !TerminalTheme.library(preferences).contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw AppFailure.message(chinese ? "配色方案名称已存在" : "A scheme with this name already exists")
        }
        return name
    }
    @discardableResult static func create(name: String, in preferences: inout Preferences, chinese: Bool) throws -> String {
        let name = try uniqueName(name, in: preferences, chinese: chinese)
        guard validPalette(preferences) else { throw AppFailure.message(chinese ? "请先修正无效颜色" : "Correct invalid colors first") }
        guard preferences.customTerminalThemes.count < 100 else { throw AppFailure.message(chinese ? "自定义配色方案最多 100 个" : "Keep up to 100 custom schemes") }
        let theme = TerminalTheme(id: "custom-" + UUID().uuidString, name: name, foreground: preferences.foreground, background: preferences.background, cursor: preferences.cursorColor, ansi: TerminalTheme.effectiveANSI(preferences))
        preferences.customTerminalThemes.append(theme)
        preferences = theme.applying(to: preferences)
        return theme.id
    }
    static func rename(_ id: String, name: String, in preferences: inout Preferences, chinese: Bool) throws {
        let name = try uniqueName(name, excluding: id, in: preferences, chinese: chinese)
        guard let index = preferences.customTerminalThemes.firstIndex(where: { $0.id == id }) else { throw AppFailure.message(chinese ? "配色方案不存在" : "Scheme no longer exists") }
        preferences.customTerminalThemes[index].name = name
    }
    static func update(_ id: String, in preferences: inout Preferences, chinese: Bool) throws {
        guard validPalette(preferences) else { throw AppFailure.message(chinese ? "请先修正无效颜色" : "Correct invalid colors first") }
        guard let index = preferences.customTerminalThemes.firstIndex(where: { $0.id == id }) else { throw AppFailure.message(chinese ? "配色方案不存在" : "Scheme no longer exists") }
        let original = preferences.customTerminalThemes[index]
        preferences.customTerminalThemes[index] = TerminalTheme(id: id, name: original.name, foreground: preferences.foreground, background: preferences.background, cursor: preferences.cursorColor, ansi: TerminalTheme.effectiveANSI(preferences))
    }
    static func remove(_ id: String, in preferences: inout Preferences) {
        guard preferences.customTerminalThemes.contains(where: { $0.id == id }) else { return }
        preferences.customTerminalThemes.removeAll { $0.id == id }
        if preferences.terminalTheme == id { preferences = TerminalTheme.all[0].applying(to: preferences) }
    }
    static func filtered(_ preferences: Preferences, search: String, filter: TerminalThemeFilter) -> [TerminalTheme] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return TerminalTheme.library(preferences).filter { theme in
            (query.isEmpty || theme.name.localizedCaseInsensitiveContains(query)) && (filter == .all || (filter == .dark && !theme.isLight) || (filter == .light && theme.isLight) || (filter == .custom && theme.isCustom))
        }
    }
}

enum TerminalThemeFilter: String, CaseIterable, Identifiable {
    case all, dark, light, custom
    var id: String { rawValue }
    func title(chinese: Bool) -> String {
        switch self { case .all: return chinese ? "全部" : "All"; case .dark: return chinese ? "深色" : "Dark"; case .light: return chinese ? "浅色" : "Light"; case .custom: return chinese ? "自定义" : "Custom" }
    }
}
