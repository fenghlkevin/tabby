import Foundation
import SwiftUI
import AppKit
import SwiftTerm
import CoreText

struct KeywordRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    var pattern = ""
    var regex = false
    var caseSensitive = false
    var enabled = true
    var foreground = "#FF6B6B"
    var background = ""
    var bold = false
    var scope = "global"
    var group = ""
    var hostID: UUID?
    func expression() throws -> NSRegularExpression {
        guard !pattern.isEmpty, pattern.utf8.count <= 512, ["global", "group", "host"].contains(scope),
              scope != "group" || !group.isEmpty, scope != "host" || hostID != nil else { throw AppFailure.message("Enter a pattern and scope / 请填写匹配内容及作用范围") }
        for color in [foreground, background] where !color.isEmpty {
            guard color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else { throw AppFailure.message("Use #RRGGBB colors / 颜色须为 #RRGGBB") }
        }
        return try NSRegularExpression(pattern: regex ? pattern : NSRegularExpression.escapedPattern(for: pattern), options: caseSensitive ? [] : [.caseInsensitive])
    }
    static var presets: [KeywordRule] {
        var error = KeywordRule(); error.name = "Error"; error.pattern = "ERROR|FATAL|FAILED"; error.regex = true; error.bold = true
        var warning = KeywordRule(); warning.name = "Warning"; warning.pattern = "WARN(?:ING)?"; warning.regex = true; warning.foreground = "#FFD166"
        return [error, warning]
    }
}
struct KeywordMatch { let range: NSRange; let rule: KeywordRule }
enum KeywordMatching {
    static func effective(_ rules: [KeywordRule], host: Host?) -> [KeywordRule] {
        let applicable = rules.filter { $0.enabled && ($0.scope == "global" || ($0.scope == "group" && $0.group == host?.group) || ($0.scope == "host" && $0.hostID == host?.id)) }
        return applicable.enumerated().sorted { a, b in
            let ranks = ["host": 0, "group": 1, "global": 2]
            let x = ranks[a.element.scope] ?? 2, y = ranks[b.element.scope] ?? 2
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }
    static func matches(_ text: String, rules: [KeywordRule]) -> [KeywordMatch] {
        guard text.utf16.count <= 16384 else { return [] }
        var matches: [KeywordMatch] = []
        let deadline = Date().addingTimeInterval(0.01)
        for rule in rules {
            guard Date() < deadline, let expression = try? rule.expression() else { continue }
            expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)) { result, _, stop in
                if Date() > deadline || matches.count >= 128 { stop.pointee = true; return }
                guard let range = result?.range, range.length > 0, !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(KeywordMatch(range: range, rule: rule))
            }
        }
        return matches
    }
    static func preview(_ text: String, rules: [KeywordRule]) -> AttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)])
        for match in matches(text, rules: rules) {
            if !match.rule.foreground.isEmpty { string.addAttribute(.foregroundColor, value: NSColor(hex: match.rule.foreground), range: match.range) }
            if !match.rule.background.isEmpty { string.addAttribute(.backgroundColor, value: NSColor(hex: match.rule.background), range: match.range) }
            if match.rule.bold { string.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: match.range) }
        }
        return AttributedString(string)
    }
}

/// Decorations use copied viewport snapshots; neither terminal bytes nor
/// scrollback attributes are changed. The view never intercepts input.
@MainActor final class KeywordOverlay: NSView {
    weak var terminal: TerminalView?
    weak var store: AppStore?
    var sessionID: UUID?
    private var timer: Timer?
    private var cachedRows: [TerminalVisibleRowSnapshot] = []
    private var cachedRules: [KeywordRule] = []
    private var cachedSelection = false
    private var cachedFontSize: CGFloat = 0
    private var cachedAppearance = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.window != nil, self.terminal?.isHidden == false else { return }; let host = self.store?.sessions.first { $0.id == self.sessionID }?.host
                let rules = KeywordMatching.effective(self.store?.workspace.preferences.keywordRules ?? [], host: host)
                let selection = self.terminal?.getSelection()?.isEmpty == false
                let snapshot = rules.isEmpty ? nil : self.terminal?.terminalStateSnapshot()
                let rows = snapshot?.visibleRows ?? []
                let appearance = "\(self.terminal?.font.fontName ?? "")|\(self.terminal?.nativeForegroundColor.description ?? "")|\(self.terminal?.nativeBackgroundColor.description ?? "")|\(snapshot?.cursor.row ?? -1)|\(snapshot?.cursor.col ?? -1)"
                let fontSize = self.terminal?.font.pointSize ?? 0
                if rows != self.cachedRows || rules != self.cachedRules || selection != self.cachedSelection || fontSize != self.cachedFontSize || appearance != self.cachedAppearance {
                    self.cachedRows = rows; self.cachedRules = rules; self.cachedSelection = selection; self.cachedFontSize = fontSize; self.cachedAppearance = appearance; self.needsDisplay = true
                } }
        }
    }
    deinit { timer?.invalidate() }
    override func draw(_ dirtyRect: NSRect) {
        guard let terminal, let store, !terminal.isHidden, terminal.getSelection()?.isEmpty != false else { return }
        let host = store.sessions.first { $0.id == sessionID }?.host
        let rules = KeywordMatching.effective(store.workspace.preferences.keywordRules, host: host)
        guard !rules.isEmpty else { return }
        let snapshot = terminal.terminalStateSnapshot()
        let scale = window?.backingScaleFactor ?? 2
        let width = (terminal.font.advancement(forGlyph: terminal.font.glyph(withName: "W")).width * scale).rounded() / scale
        let height = ceil(CTFontGetAscent(terminal.font) + CTFontGetDescent(terminal.font) + CTFontGetLeading(terminal.font))
        guard width > 0, height > 0 else { return }
        let deadline = Date().addingTimeInterval(0.008)
        for (rowIndex, row) in snapshot.visibleRows.enumerated() {
            guard Date() < deadline else { break }
            let matches = KeywordMatching.matches(row.text, rules: rules)
            guard !matches.isEmpty else { continue }
            var utf16 = 0, col = 0
            for character in row.text {
                while col < row.cellWidths.count, row.cellWidths[col] == 0 { col += 1 }
                let length = String(character).utf16.count
                let cells = col < row.cellWidths.count ? max(1, row.cellWidths[col]) : 1
                if let match = matches.first(where: { NSIntersectionRange($0.range, NSRange(location: utf16, length: length)).length > 0 }), !(snapshot.cursor.row == row.row && snapshot.cursor.col >= col && snapshot.cursor.col < col + cells) {
                    let rect = NSRect(x: CGFloat(col) * width, y: CGFloat(rowIndex) * height, width: CGFloat(cells) * width, height: height)
                    if rect.intersects(dirtyRect) {
                        let background = match.rule.background.isEmpty ? terminal.nativeBackgroundColor : NSColor(hex: match.rule.background)
                        background.setFill(); rect.fill()
                        let font = match.rule.bold ? NSFontManager.shared.convert(terminal.font, toHaveTrait: .boldFontMask) : terminal.font
                        let foreground = match.rule.foreground.isEmpty ? terminal.nativeForegroundColor : NSColor(hex: match.rule.foreground)
                        (String(character) as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + max(0, (height - font.ascender + font.descender) / 2)), withAttributes: [.font: font, .foregroundColor: foreground])
                    }
                }
                utf16 += length; col += cells
            }
        }
    }
    static func attach(to terminal: TerminalView, store: AppStore, sessionID: UUID) {
        let overlay = KeywordOverlay(frame: terminal.bounds); overlay.wantsLayer = true; overlay.autoresizingMask = [.width, .height]
        overlay.terminal = terminal; overlay.store = store; overlay.sessionID = sessionID
        terminal.addSubview(overlay, positioned: .above, relativeTo: nil); overlay.start()
    }
}

struct KeywordRulesPane: View {
    @EnvironmentObject var store: AppStore
    @Binding var draft: Preferences
    @State private var example = "INFO service started\nWARN disk usage 85%\nERROR connection failed\n中文日志 FAILED"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button { draft.keywordRules.append(KeywordRule()) } label: { Label(store.text("Add rule", "添加规则"), systemImage: "plus") }.buttonStyle(ChromeButtonStyle(prominent: true))
                Button(store.text("ERROR / WARN presets", "ERROR / WARN 预设")) { draft.keywordRules += KeywordRule.presets }.buttonStyle(ChromeButtonStyle())
                Spacer()
                Text("\(draft.keywordRules.count) " + store.text("rules", "条规则")).font(.caption).foregroundStyle(Palette.muted)
            }
            Text(store.text("Priority: host → group → global. The first matching rule wins.", "优先级：主机 → 分组 → 全局，同一范围内使用首个匹配规则。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            ForEach($draft.keywordRules) { $rule in
                KeywordRuleCard(rule: $rule, terminalBackground: draft.background,
                    index: (draft.keywordRules.firstIndex { $0.id == rule.id } ?? 0) + 1,
                    count: draft.keywordRules.count,
                    move: { move(rule.id, $0) }, remove: { draft.keywordRules.removeAll { $0.id == rule.id } })
            }
            Text(store.text("Preview", "预览")).font(.headline)
            DisclosureGroup(store.text("Edit preview text", "编辑预览内容")) {
                TextEditor(text: $example).font(.system(size: 12, design: .monospaced)).frame(height: 90)
            }.foregroundStyle(Palette.muted)
            Text(KeywordMatching.preview(example, rules: draft.keywordRules.filter(\.enabled))).foregroundStyle(Color(hex: draft.foreground)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color(hex: draft.background)).clipShape(RoundedRectangle(cornerRadius: 12)).font(.system(size: 13, design: .monospaced))
        }.frame(maxWidth: 820, alignment: .leading)
    }
    private func move(_ id: UUID, _ delta: Int) { if let index = draft.keywordRules.firstIndex(where: { $0.id == id }), draft.keywordRules.indices.contains(index + delta) { draft.keywordRules.swapAt(index, index + delta) } }
}

struct KeywordRuleCard: View {
    @EnvironmentObject var store: AppStore
    @Binding var rule: KeywordRule
    let terminalBackground: String
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", index)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.muted).frame(width: 28, height: 28).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 7))
                Text(rule.name.isEmpty ? store.text("New rule", "新规则") : rule.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(store.text("Enabled", "启用"), isOn: $rule.enabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 11))
                Divider().frame(height: 18)
                Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 1).help(store.text("Move up", "上移"))
                Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count).help(store.text("Move down", "下移"))
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help(store.text("Delete rule", "删除规则"))
            }.buttonStyle(IconButtonStyle())
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    nameField.frame(width: 190)
                    patternField.frame(minWidth: 260)
                }
                VStack(alignment: .leading, spacing: 12) { nameField; patternField }
            }
            HStack(spacing: 18) {
                Toggle(store.text("Regular expression", "正则表达式"), isOn: $rule.regex).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Case sensitive", "区分大小写"), isOn: $rule.caseSensitive).toggleStyle(AxonCheckboxStyle())
                Toggle(store.text("Bold", "加粗文字"), isOn: $rule.bold).toggleStyle(AxonCheckboxStyle())
                Spacer(minLength: 0)
            }.toggleStyle(AxonCheckboxStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 22) { appearance; Spacer(minLength: 12); scope }
                VStack(alignment: .leading, spacing: 14) { appearance; scope }
            }
            if !rule.pattern.isEmpty, let error = validationError {
                Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
            }
        }.padding(20).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.border.opacity(0.6), lineWidth: 1))
    }
    private var nameField: some View {
        VStack(alignment: .leading, spacing: 7) {
            caption(store.text("Rule name", "规则名称"))
            TextField(store.text("e.g. Error messages", "例如：错误日志"), text: $rule.name).appInput()
        }
    }
    private var patternField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) { caption(store.text("Match", "匹配内容")); Text(store.text("Required", "必填")).font(.system(size: 9)).foregroundStyle(Palette.muted) }
            TextField(rule.regex ? "ERROR|FATAL|FAILED" : "ERROR", text: $rule.pattern).appInput()
        }
    }
    private var appearance: some View {
        HStack(spacing: 16) {
            color(store.text("Text", "文字"), value: $rule.foreground)
            Toggle(store.text("Background", "背景"), isOn: Binding(get: { !rule.background.isEmpty }, set: { rule.background = $0 ? terminalBackground : "" }))
                .toggleStyle(AxonCheckboxStyle()).font(.system(size: 11)).foregroundStyle(Palette.muted)
            if !rule.background.isEmpty { color("", value: $rule.background) }
        }.fixedSize()
    }
    private var scope: some View {
        HStack(spacing: 8) {
            caption(store.text("Scope", "范围"))
            AxonChoiceField(selection: $rule.scope,
                choices: [("global", store.text("Global", "全局")), ("group", store.text("Group", "分组")), ("host", store.text("Host", "主机"))],
                placeholder: store.text("Scope", "作用范围"), symbol: "scope", identifier: "keyword-scope-" + rule.id.uuidString,
                menuTitle: store.text("Apply rule to", "作用范围"),
                descriptions: [store.text("Global", "全局"): store.text("All terminals", "所有终端会话"), store.text("Group", "分组"): store.text("Hosts in the selected group", "所选分组中的主机"), store.text("Host", "主机"): store.text("Only the selected host", "仅所选主机")]).frame(width: 124)
            if rule.scope == "group" {
                AxonChoiceField(selection: $rule.group,
                    choices: [("", store.text("Choose group", "选择分组"))] + store.groups.map { ($0, $0) },
                    placeholder: store.text("Choose group", "选择分组"), symbol: "folder", identifier: "keyword-group-" + rule.id.uuidString).frame(width: 170)
            }
            if rule.scope == "host" {
                AxonChoiceField(selection: $rule.hostID,
                    choices: [(nil as UUID?, store.text("Choose host", "选择主机"))] + store.workspace.hosts.map { (Optional($0.id), $0.name.isEmpty ? $0.address : $0.name) },
                    placeholder: store.text("Choose host", "选择主机"), symbol: "server.rack", identifier: "keyword-host-" + rule.id.uuidString).frame(width: 190)
            }
        }.fixedSize()
    }
    private func caption(_ text: String) -> some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted) }
    private func color(_ title: String, value: Binding<String>) -> some View {
        HStack(spacing: 6) {
            ColorPicker(title, selection: Binding(get: { Color(hex: value.wrappedValue) }, set: { color in
                if let rgb = NSColor(color).usingColorSpace(.deviceRGB) {
                    value.wrappedValue = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                }
            }), supportsOpacity: false).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.fixedSize()
    }
    private var validationError: String? { do { _ = try rule.expression(); return nil } catch { return error.localizedDescription } }
}
