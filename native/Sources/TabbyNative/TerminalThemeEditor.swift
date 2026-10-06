import SwiftUI
import AppKit

/// The editor owns a separate value, so closing its sheet never touches settings.
/// Saving merges only theme fields into the parent draft and is atomic on errors.
struct TerminalThemeEditorDraft {
    enum SaveMode: String, CaseIterable { case update, create }
    let source: TerminalTheme
    let canUpdate: Bool
    let copyName: String
    var mode: SaveMode
    var name: String
    var palette: Preferences

    init(preferences: Preferences, saveAsNew: Bool, chinese: Bool) {
        source = TerminalTheme.selected(preferences)
        canUpdate = source.isCustom && !saveAsNew
        copyName = Self.availableCopyName(source.name, in: preferences, chinese: chinese)
        mode = canUpdate ? .update : .create
        name = canUpdate ? source.name : copyName
        palette = preferences
        // Older workspaces may omit ANSI values; the editor always shows 16 slots.
        palette.ansiColors = TerminalTheme.effectiveANSI(preferences)
    }
    mutating func choose(_ mode: SaveMode) {
        self.mode = canUpdate ? mode : .create
        name = self.mode == .update ? source.name : copyName
    }
    func saving(to settings: Preferences, chinese: Bool) throws -> Preferences {
        var result = settings
        result.foreground = palette.foreground
        result.background = palette.background
        result.cursorColor = palette.cursorColor
        result.ansiColors = TerminalTheme.effectiveANSI(palette)
        guard TerminalThemeLibrary.validPalette(palette) else {
            throw AppFailure.message(chinese ? "请先修正无效颜色，格式为 #RRGGBB" : "Correct invalid colors first using #RRGGBB")
        }
        if mode == .update {
            guard canUpdate else { throw AppFailure.message(chinese ? "内置方案请另存为新方案" : "Save built-in schemes as a new scheme") }
            try TerminalThemeLibrary.rename(source.id, name: name, in: &result, chinese: chinese)
            try TerminalThemeLibrary.update(source.id, in: &result, chinese: chinese)
            result.terminalTheme = source.id
        } else {
            try TerminalThemeLibrary.create(name: name, in: &result, chinese: chinese)
        }
        return result
    }
    private static func availableCopyName(_ name: String, in preferences: Preferences, chinese: Bool) -> String {
        let suffix = chinese ? " 副本" : " Copy"
        for index in 1...101 {
            let numberedSuffix = suffix + (index == 1 ? "" : " \(index)")
            let candidate = String(name.prefix(max(1, 48 - numberedSuffix.count))) + numberedSuffix
            if !TerminalTheme.library(preferences).contains(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) { return candidate }
        }
        return String(name.prefix(24)) + suffix + " " + String(UUID().uuidString.prefix(8))
    }
}

enum TerminalThemeEditorLayout {
    static func size(forVisibleSize visibleSize: NSSize) -> NSSize {
        NSSize(width: min(1180, max(1, visibleSize.width - 64)),
               height: min(840, max(1, visibleSize.height - 64)))
    }
    @MainActor static var visibleSize: NSSize {
        (NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(width: 1440, height: 900)
    }
}

struct TerminalThemeEditorRequest: Identifiable {
    let id = UUID()
    let draft: TerminalThemeEditorDraft
    let size: NSSize
    @MainActor init(preferences: Preferences, saveAsNew: Bool, chinese: Bool, visibleSize: NSSize? = nil) {
        draft = TerminalThemeEditorDraft(preferences: preferences, saveAsNew: saveAsNew, chinese: chinese)
        size = TerminalThemeEditorLayout.size(forVisibleSize: visibleSize ?? TerminalThemeEditorLayout.visibleSize)
    }
}

struct TerminalThemeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let chinese: Bool
    let persistsImmediately: Bool
    let save: (TerminalThemeEditorDraft) throws -> Void
    private let size: NSSize
    @State private var draft: TerminalThemeEditorDraft
    @State private var error = ""
    @State private var columnHeight: CGFloat = 0
    @FocusState private var nameFocused: Bool

    init(request: TerminalThemeEditorRequest, chinese: Bool, persistsImmediately: Bool = false, save: @escaping (TerminalThemeEditorDraft) throws -> Void) {
        self.chinese = chinese; self.persistsImmediately = persistsImmediately; self.save = save
        size = request.size
        _draft = State(initialValue: request.draft)
    }
    private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.border).frame(height: 1)
            ScrollView {
                HStack(alignment: .top, spacing: 22) {
                    column(previewColumn).frame(width: previewWidth)
                    column(ansiColors).frame(maxWidth: .infinity)
                }.padding(22)
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            footer
        }.frame(width: size.width, height: size.height).background(Palette.background).foregroundStyle(Palette.text)
            .onPreferenceChange(ThemeEditorColumnHeight.self) { columnHeight = $0 }
            .accessibilityIdentifier("axon-theme-editor")
            .onAppear { nameFocused = true }
    }
    private func column<Content: View>(_ content: Content) -> some View {
        content.padding(16).fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in Color.clear.preference(key: ThemeEditorColumnHeight.self, value: geometry.size.height) })
            .frame(minHeight: columnHeight, alignment: .top).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 10))
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "paintpalette").font(.system(size: 20)).foregroundStyle(Palette.accent)
                    .frame(width: 42, height: 42).background(Palette.selected).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.canUpdate ? text("Edit custom scheme", "编辑自定义方案") : text("Create custom scheme", "创建自定义方案")).font(.system(size: 18, weight: .semibold))
                    Text(text("Based on ", "基于 ") + draft.source.name + text(" · 19 editable colors", " · 完整 19 色"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                if draft.canUpdate {
                    HStack(spacing: 4) {
                        modeButton(.update, title: text("Update existing", "更新当前方案"))
                        modeButton(.create, title: text("Save as new", "另存为新方案"))
                    }
                } else {
                    Text(text("Save as a new scheme", "另存为新方案")).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                }
            }
            HStack(spacing: 12) {
                Text(text("Scheme name", "方案名称")).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 78, alignment: .leading)
                TextField(text("Name your scheme", "为配色方案命名"), text: $draft.name).appInput().focused($nameFocused)
                    .onSubmit(confirm).accessibilityIdentifier("axon-theme-name")
            }
        }.padding(22).background(Palette.card)
    }
    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(text("Live preview", "实时预览")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(text("Color preview", "配色预览")).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            TerminalColorPreview(preferences: previewPreferences, identifier: "axon-theme-editor-preview", chinese: chinese, style: .expanded)
            Text(text("Preview updates while editing. The terminal font size stays unchanged; Cancel keeps your previous scheme.", "调整颜色时即时预览，终端字号保持设置值；取消保留原方案。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            baseColors
        }
    }
    private var previewWidth: CGFloat { size.width >= 1100 ? 420 : size.width >= 960 ? 360 : 300 }
    private var previewPreferences: Preferences {
        var value = draft.palette
        value.fontSize = size.width >= 1100 ? 13 : 11
        return value
    }
    private var baseColors: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("Base colors", "基础配色")).font(.system(size: 13, weight: .semibold))
            TerminalColorField(title: text("Text", "文字"), value: $draft.palette.foreground, identifier: "axon-theme-foreground")
            TerminalColorField(title: text("Background", "背景"), value: $draft.palette.background, identifier: "axon-theme-background")
            TerminalColorField(title: text("Cursor", "光标"), value: $draft.palette.cursorColor, identifier: "axon-theme-cursor")
        }
    }
    private var ansiColors: some View {
        let names = chinese ? ["黑", "红", "绿", "黄", "蓝", "紫", "青", "白"] : ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return VStack(alignment: .leading, spacing: 12) {
            Text(text("ANSI palette", "ANSI 调色板")).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 12) {
                Text(text("Normal · 0–7", "常规色 · 0–7")).frame(maxWidth: .infinity, alignment: .leading)
                Text(text("Bright · 8–15", "高亮色 · 8–15")).frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(0..<8, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    ansiField(index, name: names[index])
                    ansiField(index + 8, name: names[index])
                }
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                else { Text(persistsImmediately ? text("Save to keep the scheme and apply it to open terminals immediately.", "保存后立即保留方案，并应用到已打开终端。") : text("Scheme changes stay in the settings draft until you Save settings.", "方案保存到设置草稿；点击设置底部「保存」后持久生效。"))
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            ThemeEditorActionButton(title: text("Cancel", "取消"), identifier: "axon-theme-editor-cancel", keyEquivalent: "\u{1b}") { dismiss() }.frame(width: 76, height: 34)
            ThemeEditorActionButton(title: saveTitle, identifier: "axon-theme-editor-save", keyEquivalent: "\r", prominent: true, action: confirm)
                .frame(width: chinese ? 118 : 182, height: 34)
        }.padding(.horizontal, 22).padding(.vertical, 16).background(Palette.card)
    }
    private var saveTitle: String {
        if persistsImmediately { return draft.mode == .update ? text("Save changes & apply", "保存修改并应用") : text("Save & apply", "保存并应用") }
        return draft.mode == .update ? text("Save changes", "保存修改") : text("Save new scheme", "保存新方案")
    }
    private func modeButton(_ mode: TerminalThemeEditorDraft.SaveMode, title: String) -> some View {
        PreferencesActionButton(title: title, identifier: "axon-theme-editor-mode-" + mode.rawValue, prominent: draft.mode == mode) { draft.choose(mode); error = "" }
            .frame(width: chinese ? 98 : 118, height: 30)
    }
    private func ansiField(_ index: Int, name: String) -> some View {
        HStack(spacing: 8) {
            Text("\(index) · " + name).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .frame(width: chinese ? 48 : 76, alignment: .leading)
            TerminalColorField(title: "ANSI \(index)", value: Binding(get: { TerminalTheme.effectiveANSI(draft.palette)[index] }, set: { color in
                var colors = TerminalTheme.effectiveANSI(draft.palette); colors[index] = color; draft.palette.ansiColors = colors
            }), identifier: "axon-theme-ansi-\(index)", compact: true)
        }.frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
    private func confirm() {
        do { try save(draft); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct ThemeEditorActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    let keyEquivalent: String
    var prominent = false
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesRectNativeButton { PreferencesRectNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.prominent = prominent; button.actionBlock = action
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.keyEquivalent = keyEquivalent; button.keyEquivalentModifierMask = []
        button.setAccessibilityLabel(title); button.needsDisplay = true
    }
}

private struct ThemeEditorColumnHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
