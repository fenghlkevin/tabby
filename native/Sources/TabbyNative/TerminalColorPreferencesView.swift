import SwiftUI
import AppKit

struct TerminalColorPreferencesView: View {
    @Binding var draft: Preferences
    let chinese: Bool
    var scrollToSection: ((String) -> Void)? = nil
    @State private var search = ""
    @State private var filter = TerminalThemeFilter.all
    @State private var naming: ThemeNameRequest?
    @State private var message = ""
    private var current: TerminalTheme { TerminalTheme.selected(draft) }
    private var filtered: [TerminalTheme] { TerminalThemeLibrary.filtered(draft, search: search, filter: filter) }
    private func text(_ en: String, _ zh: String) -> String { chinese ? zh : en }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(text("Scheme library", "配色方案库")) {
                schemePreview
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField(text("Search schemes", "搜索配色方案"), text: $search).textFieldStyle(.plain).accessibilityIdentifier("axon-theme-search")
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(text("Clear search", "清空搜索")) }
                }.padding(10).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 6) {
                    ForEach(TerminalThemeFilter.allCases) { item in
                        ThemeFilterButton(title: item.title(chinese: chinese), selected: filter == item, identifier: "axon-theme-filter-" + item.rawValue) { filter = item }.frame(width: chinese ? 54 : 68, height: 30)
                    }
                    Spacer(minLength: 0)
                    Text("\(filtered.count)").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                schemeGrid.frame(height: 300)
                if let scrollToSection {
                    HStack {
                        Text(current.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted).lineLimit(1)
                        Spacer(minLength: 8)
                        PreferencesActionButton(title: text("Color guide ↓", "配色说明 ↓"), identifier: "axon-theme-color-guide") { scrollToSection("axon-terminal-color-guide") }.frame(width: 96, height: 30)
                        PreferencesActionButton(title: text("Edit palette ↓", "编辑配色 ↓"), identifier: "axon-theme-edit-colors") { scrollToSection("axon-terminal-color-editor") }.frame(width: 102, height: 30)
                    }
                }
                Text(text("Selecting a card previews all 19 colors. Save below to apply to your terminals.", "点击卡片预览完整 19 色；点击底部保存后应用到终端。" )).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            TerminalColorGuide(preferences: draft, chinese: chinese).id("axon-terminal-color-guide")
            section(text("Current palette", "当前配色")) {
                HStack(alignment: .firstTextBaseline) {
                    Text(current.name).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if !current.matches(draft) { Text(text("Modified", "已调整")).font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.accent) }
                }
                TerminalColorPreview(preferences: draft, chinese: chinese, style: .expanded)
                Text(text("Preview colors are examples; programs decide the colors of actual output.", "预览用色仅为示例；实际输出用色由程序决定。" )).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                    PreferencesActionButton(title: text("Save as custom…", "另存为自定义…"), identifier: "axon-theme-create", enabled: TerminalThemeLibrary.validPalette(draft)) { naming = ThemeNameRequest(id: nil, name: current.name + text(" Copy", " 副本")) }.frame(height: 32)
                    if current.isCustom {
                        PreferencesActionButton(title: text("Update scheme", "更新方案"), identifier: "axon-theme-update", enabled: TerminalThemeLibrary.validPalette(draft) && !current.matches(draft)) { perform { try TerminalThemeLibrary.update(current.id, in: &draft, chinese: chinese) } }.frame(height: 32)
                        PreferencesActionButton(title: text("Rename…", "重命名…"), identifier: "axon-theme-rename") { naming = ThemeNameRequest(id: current.id, name: current.name) }.frame(height: 32)
                        PreferencesActionButton(title: text("Delete scheme", "删除方案"), identifier: "axon-theme-delete", destructive: true) { TerminalThemeLibrary.remove(current.id, in: &draft); message = text("Scheme deleted from this draft. Revert can restore it before saving.", "已从草稿中删除方案；保存前可撤销恢复。") }.frame(height: 32)
                    }
                    PreferencesRestoreThemeButton(title: text("Restore scheme", "恢复方案配色")) { draft = current.applying(to: draft); message = "" }.frame(height: 32)
                }
                if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                TerminalColorField(title: text("Text", "文字"), value: $draft.foreground, identifier: "axon-theme-foreground", explanation: text("Default text when a program has not set a color.", "程序未指定颜色时的默认文字。"))
                TerminalColorField(title: text("Background", "背景"), value: $draft.background, identifier: "axon-theme-background", explanation: text("Terminal canvas and default background.", "终端底色与默认文字背景。"))
                TerminalColorField(title: text("Cursor", "光标"), value: $draft.cursorColor, identifier: "axon-theme-cursor", explanation: text("The caret at the input position.", "输入位置的光标颜色。"))
                Text(text("Color edits are drafts. Updating a custom scheme also changes only the draft library until you Save.", "颜色编辑仅修改草稿；更新自定义方案也需点击底部保存才持久生效。" )).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                if let scrollToSection {
                    PreferencesActionButton(title: text("Edit all 16 ANSI colors ↓", "编辑完整 16 个 ANSI 色 ↓"), identifier: "axon-theme-edit-ansi") { scrollToSection("axon-terminal-ansi-editor") }.frame(maxWidth: .infinity).frame(height: 30)
                }
            }.id("axon-terminal-color-editor")
            section(text("ANSI palette", "ANSI 调色板")) {
                HStack { Text(text("Normal · 0–7", "常规色 · 0–7")); Spacer(); Text(text("Bright · 8–15", "高亮色 · 8–15")) }.font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted)
                ForEach(0..<8, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        ansiField(index)
                        ansiField(index + 8)
                    }
                }
                Text(text("Programs choose ANSI slots for text and backgrounds. Editing a slot changes every use of that slot; it does not assign fixed meanings to output.", "程序选择 ANSI 色位来显示文字和背景；修改一个色位会影响它的所有用处，不会自动改变内容的语义。" )).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
            .id("axon-terminal-ansi-editor")
        }.sheet(item: $naming) { request in
            ThemeNameEditor(request: request, chinese: chinese) { name in
                if let id = request.id { try TerminalThemeLibrary.rename(id, name: name, in: &draft, chinese: chinese) }
                else { try TerminalThemeLibrary.create(name: name, in: &draft, chinese: chinese); filter = .custom; search = "" }
                naming = nil; message = ""
            }
        }
    }
    private var schemeGrid: some View {
        Group {
            if filtered.isEmpty {
                Text(text("No matching schemes. Try another filter or search.", "没有匹配的配色方案，请调整筛选或搜索。"))
                    .foregroundStyle(Palette.muted).font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 166), spacing: 12)], spacing: 12) {
                        ForEach(filtered) { theme in
                            TerminalThemeCardButton(theme: theme, selected: draft.terminalTheme == theme.id, chinese: chinese) {
                                draft = theme.applying(to: draft); message = ""
                            }.frame(height: 140)
                        }
                    }.padding(2)
                }
            }
        }
    }
    private var schemePreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(text("Live preview", "实时预览")).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text(current.name + " · " + draft.fontName + " · " + TerminalFontSizeNativeEditor.display(draft.fontSize) + " pt")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            TerminalColorPreview(preferences: draft, identifier: "axon-theme-library-preview", chinese: chinese, style: .expanded)
        }
    }
    private func perform(_ operation: () throws -> Void) { do { try operation(); message = "" } catch { message = error.localizedDescription } }
    private func ansiField(_ index: Int) -> some View {
        let names = chinese ? ["黑", "红", "绿", "黄", "蓝", "紫", "青", "白"] : ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White"]
        return VStack(alignment: .leading, spacing: 5) {
            Text("\(index) · " + names[index % 8]).font(.system(size: 10)).foregroundStyle(Palette.muted)
            TerminalColorField(title: "ANSI \(index)", value: Binding(get: { TerminalTheme.effectiveANSI(draft)[index] }, set: { color in var ansi = TerminalTheme.effectiveANSI(draft); ansi[index] = color; draft.ansiColors = ansi }), identifier: "axon-theme-ansi-\(index)", compact: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) { Text(title).font(.system(size: 14, weight: .semibold)); content() }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

enum TerminalColorPreviewStyle: Equatable {
    case compact, expanded
}

struct TerminalColorPreview: View {
    let preferences: Preferences
    var identifier = "axon-theme-preview"
    var chinese = false
    var style = TerminalColorPreviewStyle.compact
    var body: some View {
        TerminalPreferencesPreview(preferences: preferences, sample: style == .expanded ? .paletteExtended : .palette, identifier: identifier, chinese: chinese)
            .frame(height: style == .expanded ? 236 : 124).padding(12)
            .frame(maxWidth: .infinity)
            .background(Color(hex: preferences.background))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

struct TerminalColorField: View {
    let title: String
    @Binding var value: String
    let identifier: String
    var compact = false
    var explanation: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
            if !compact { Text(title).foregroundStyle(Palette.muted).frame(width: 68, alignment: .leading) }
            TextField("#RRGGBB", text: $value).appInput().font(.system(size: 11, design: .monospaced)).accessibilityLabel(title).accessibilityIdentifier(identifier)
            ColorPicker(title, selection: Binding(get: { Color(hex: value) }, set: { color in
                if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { value = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
            }), supportsOpacity: false).labelsHidden().frame(width: 28)
        }.frame(maxWidth: .infinity).overlay(alignment: .bottomLeading) { if !TerminalThemeLibrary.isHex(value) { Text("#RRGGBB").font(.system(size: 9)).foregroundStyle(.red).offset(y: 11) } }
        if let explanation { Text(explanation).font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ThemeFilterButton: NSViewRepresentable {
    let title: String
    let selected: Bool
    let identifier: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesRectNativeButton { PreferencesRectNativeButton() }
    func updateNSView(_ button: PreferencesRectNativeButton, context: Context) {
        button.title = title; button.selected = selected; button.prominent = selected; button.actionBlock = action; button.identifier = NSUserInterfaceItemIdentifier(identifier); button.setAccessibilityLabel(title); button.setAccessibilityValue(selected ? "Selected" : ""); button.needsDisplay = true
    }
}
private struct ThemeNameRequest: Identifiable { let id: String?; var name: String }
private struct ThemeNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    let request: ThemeNameRequest
    let chinese: Bool
    let confirm: (String) throws -> Void
    @State private var name = ""
    @State private var error = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.id == nil ? (chinese ? "创建自定义配色" : "Create custom scheme") : (chinese ? "重命名配色方案" : "Rename scheme")).font(.system(size: 17, weight: .semibold))
            Text(chinese ? "完整配色保存在设置草稿中；保存设置后生效。" : "The complete scheme stays in the settings draft until you Save.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField(chinese ? "方案名称" : "Scheme name", text: $name).appInput().focused($focused).onSubmit(save).accessibilityIdentifier("axon-theme-name")
            if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)) }
            HStack { Button(chinese ? "取消" : "Cancel") { dismiss() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction); Spacer(); Button(chinese ? "确定" : "Confirm", action: save).buttonStyle(ChromeButtonStyle(prominent: true)).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 360).background(Palette.background).foregroundStyle(Palette.text).onAppear { name = request.name; focused = true }
    }
    private func save() { do { try confirm(name) } catch { self.error = error.localizedDescription } }
}
