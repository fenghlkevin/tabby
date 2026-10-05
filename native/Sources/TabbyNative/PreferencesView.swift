import SwiftUI
import AppKit

enum PreferencesPage: String, CaseIterable, Identifiable {
    case general, terminal, appearance, keyboard, connection, importHosts, storage, shortcuts, about
    var id: String { rawValue }
    var icon: String {
        switch self { case .general: return "gearshape"; case .terminal: return "terminal"; case .appearance: return "paintpalette"; case .keyboard: return "keyboard"; case .connection: return "network"; case .importHosts: return "arrow.up.arrow.down"; case .storage: return "externaldrive.badge.icloud"; case .shortcuts: return "command"; case .about: return "info.circle" }
    }
    func title(chinese: Bool) -> String {
        switch self {
        case .general: return chinese ? "通用" : "General"
        case .terminal: return chinese ? "终端" : "Terminal"
        case .appearance: return chinese ? "终端配色" : "Terminal colors"
        case .keyboard: return chinese ? "键盘与剪贴板" : "Keyboard & Clipboard"
        case .connection: return chinese ? "连接" : "Connection"
        case .importHosts: return chinese ? "导入与导出" : "Import & Export"
        case .storage: return chinese ? "云备份" : "Cloud backup"
        case .shortcuts: return chinese ? "快捷键" : "Shortcuts"
        case .about: return chinese ? "关于" : "About"
        }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    @State private var localPage: PreferencesPage
    private let selection: Binding<PreferencesPage>?
    private let showsSidebar: Bool
    private var page: PreferencesPage {
        get { selection?.wrappedValue ?? localPage }
        nonmutating set { if let selection { selection.wrappedValue = newValue } else { localPage = newValue } }
    }
    @State private var draft = Preferences()
    @State private var scrollbackValid = true
    @State private var fontSizeValid = true
    @State private var fontSizeInput = "19"
    @State private var timeoutValid = true
    @State private var error = ""
    @State private var saved = false
    @State private var loaded = false
    @State private var draftRevision = 0
    @State private var colorCommitSnapshot: Preferences?
    init(page: PreferencesPage = .general, selection: Binding<PreferencesPage>? = nil, showsSidebar: Bool = true) {
        _localPage = State(initialValue: page); self.selection = selection; self.showsSidebar = showsSidebar
    }
    private var dirty: Bool { draft != store.workspace.preferences || !scrollbackValid || !fontSizeValid || !timeoutValid }
    private var validNumbers: Bool { scrollbackValid && fontSizeValid && timeoutValid }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                    Rectangle().fill(Palette.border).frame(width: 1)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            PaneHeading(title: page.title(chinese: store.chinese), subtitle: subtitle).id("axon-preferences-heading")
                            pageContent(scrollToSection: { proxy.scrollTo($0, anchor: .top) }).id(draftRevision)
                        }.padding(24).frame(maxWidth: page == .appearance ? .infinity : 840, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.background(Palette.background)
                        .onChange(of: page) { _, _ in proxy.scrollTo("axon-preferences-heading", anchor: .top) }
                }
            }
            Rectangle().fill(Palette.border).frame(height: 1)
            HStack(spacing: 12) {
                if !error.isEmpty { Text(error).foregroundStyle(.red).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true) }
                else { Text(saved && !dirty ? store.text("Settings saved", "设置已保存") : dirty ? store.text("Unsaved changes", "有未保存的更改") : store.text("Changes apply after saving", "保存后生效")).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 8)
                Button(store.text("Revert", "撤销更改"), action: reload).buttonStyle(ChromeButtonStyle()).disabled(!dirty).accessibilityIdentifier("axon-preferences-revert")
                Button(store.text("Save", "保存"), action: save).buttonStyle(ChromeButtonStyle(prominent: true)).disabled(!dirty || !validNumbers).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("axon-preferences-save")
            }.padding(.horizontal, 20).padding(.vertical, 14).background(Palette.sidebar)
        }.foregroundStyle(Palette.text).font(.system(size: 13)).frame(minWidth: 650, minHeight: 520)
            .onAppear { if !loaded { reload(); loaded = true } }
            .onChange(of: draft) { _, _ in saved = false; error = "" }
            .onChange(of: store.workspace.preferences) { _, value in
                if colorCommitSnapshot == value { colorCommitSnapshot = nil }
                else { reload() }
            }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Axon").font(.system(size: 20, weight: .semibold)).padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 16)
            ForEach(PreferencesPage.allCases) { item in
                PreferencesNavigationButton(title: item.title(chinese: store.chinese), symbol: item.icon, selected: page == item, identifier: "axon-preferences-page-" + item.rawValue) { page = item }
                    .frame(height: 42)
            }
            Spacer()
        }.padding(.horizontal, 10).frame(width: 168).frame(maxHeight: .infinity).background(Palette.sidebar)
    }
    private var subtitle: String {
        switch page {
        case .general: return store.text("Application icon, language and local terminal startup.", "程序图标、语言与本地终端启动方式。")
        case .terminal: return store.text("Font, history and cursor behavior.", "字体、历史回滚与光标行为。")
        case .appearance: return store.text("Choose a scheme or create your own complete terminal palette.", "选择主题方案，或创建自己的完整终端配色。")
        case .keyboard: return store.text("Tune shortcuts, mouse input and pasted commands.", "调整按键、鼠标与命令粘贴方式。")
        case .connection: return store.text("Timeout for new SSH and SFTP connections.", "新 SSH 与 SFTP 连接的超时设置。")
        case .importHosts: return store.text("Import SSH profiles, export hosts or back up your workspace.", "导入 SSH 配置、导出主机或备份工作区。")
        case .storage: return store.text("Encrypted backups in iCloud Drive or S3-compatible storage.", "将加密备份保存到 iCloud Drive 或 S3 兼容存储。")
        case .shortcuts: return store.text("Keyboard shortcuts for windows, sessions and terminals.", "窗口、会话与终端的快捷操作。")
        case .about: return store.text("Application version and component information.", "应用版本与组件信息。")
        }
    }
    @ViewBuilder private func pageContent(scrollToSection: @escaping (String) -> Void) -> some View {
        switch page {
        case .general: general
        case .terminal: terminal
        case .appearance: TerminalColorPreferencesView(draft: $draft, chinese: store.chinese, scrollToSection: scrollToSection, commit: saveTerminalColors)
        case .keyboard: keyboard
        case .connection: connection
        case .importHosts: ImportPreferencesPane()
        case .storage: CloudBackupPreferencesPane()
        case .shortcuts: shortcuts
        case .about: about
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(store.text("Application", "应用")) {
                row(store.text("Language", "语言")) { Picker("", selection: $draft.language) { Text(store.text("Automatic", "自动")).tag("auto"); Text("简体中文").tag("zh-CN"); Text("English").tag("en-US") }.labelsHidden() }
                Text(store.text("Application icon", "程序图标")).foregroundStyle(Palette.muted)
                ApplicationIconPicker(selection: $draft.applicationIcon, chinese: store.chinese)
                note(store.text("Both icons keep the yellow node. Save to apply the selected application icon and logo.", "两款均保留黄色节点；保存后应用于程序图标与应用 Logo。"))
            }
            section(store.text("Local terminal", "本地终端")) {
                pathField(store.text("Shell executable", "Shell 程序"), text: $draft.localShell, placeholder: store.text("System default", "使用系统默认"), directory: false)
                pathField(store.text("Starting directory", "启动目录"), text: $draft.localDirectory, placeholder: "~", directory: true)
                Toggle(store.text("Run as a login shell", "作为登录 Shell 启动"), isOn: $draft.localLoginShell)
                note(store.text("Empty paths use your system shell and home directory. Applies to newly opened local terminals.", "路径留空时使用系统 Shell 与用户主目录；应用于新建本地终端。"))
            }
        }
    }
    private var terminal: some View {
        TerminalPreferencesPane(draft: $draft, scrollbackValid: $scrollbackValid, fontSizeValid: $fontSizeValid, chinese: store.chinese, fontSizeInput: $fontSizeInput)
    }
    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 18) {
            section(store.text("Keyboard & mouse", "键盘与鼠标")) {
                Toggle(store.text("Use Option as Meta", "将 Option 用作 Meta"), isOn: $draft.optionAsMeta)
                Toggle(store.text("Backspace sends Control-H", "退格键发送 Control-H"), isOn: $draft.backspaceControlH)
                Toggle(store.text("Allow mouse reporting to terminal apps", "允许终端程序处理鼠标事件"), isOn: $draft.mouseReporting)
                row(store.text("Terminal bell", "终端铃声")) { Picker("", selection: $draft.bellStyle) { Text(store.text("Off", "关闭")).tag("none"); Text(store.text("Sound", "声音")).tag("sound"); Text(store.text("Flash", "闪烁")).tag("visual"); Text(store.text("Sound & flash", "声音与闪烁")).tag("soundAndVisual") }.labelsHidden() }
            }
            section(store.text("Clipboard", "剪贴板")) {
                Toggle(store.text("Copy on selection", "选中即复制"), isOn: $draft.copyOnSelect)
                Toggle(store.text("Right click to paste", "右键粘贴"), isOn: $draft.rightClickPaste)
                Toggle(store.text("Middle click to paste", "中键粘贴"), isOn: $draft.middleClickPaste)
                Toggle(store.text("Trim pasted whitespace", "去除粘贴首尾空白"), isOn: $draft.trimPaste)
                Toggle(store.text("Confirm multiline paste", "粘贴多行内容前确认"), isOn: $draft.confirmMultilinePaste)
                note(store.text("Applies to open terminals after saving. Multiline confirmation shows a preview before sending text.", "保存后应用到已打开终端；多行粘贴会在发送前展示内容预览。"))
            }
        }
    }
    private var connection: some View {
        section(store.text("SSH & SFTP", "SSH 与 SFTP")) {
            row(store.text("TCP timeout (s)", "TCP 超时（秒）")) { IntegerInput(value: $draft.sshConnectTimeout, valid: $timeoutValid, range: 1...120, placeholder: "30", label: store.text("SSH connection timeout", "SSH 连接超时")) }
            note(store.text("Sets how long a direct TCP connection can take. Saved credentials and jump routes stay in host or group details. Applies on the next connection; existing sessions remain open.", "设置直连 TCP 建立连接的等待时间。登录凭据与跳板机在主机或分组详情中设置；新连接时生效，现有会话保持连接。"))
            note(store.text("SSH authentication has a separate 10-second limit provided by the connection library.", "SSH 认证由连接库单独限制为 10 秒。"))
        }
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Axon") {
                HStack(spacing: 14) { Image(nsImage: ApplicationIconAppearance.image(for: store.workspace.preferences.applicationIcon) ?? NSApp.applicationIconImage).resizable().frame(width: 44, height: 44).accessibilityLabel(store.text("Axon application icon", "Axon 程序图标")); VStack(alignment: .leading, spacing: 5) { Text("Axon " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")).font(.system(size: 16, weight: .semibold)); Text("macOS · SwiftUI · SwiftTerm · Citadel").font(.system(size: 11)).foregroundStyle(Palette.muted) } }
            }
        }
    }
    private var shortcuts: some View {
            section(store.text("Keyboard shortcuts", "快捷键")) {
                shortcut(store.text("New tab", "新标签"), "⌘ T")
                shortcut(store.text("Search hosts or tabs", "搜索主机或标签"), "⌘ K")
                shortcut(store.text("Local terminal", "本地终端"), "⇧ ⌘ T")
                shortcut(store.text("Split terminal", "终端分屏"), "⌘ D")
                shortcut(store.text("Find in terminal", "搜索终端"), "⌘ F")
                shortcut(store.text("Close session", "关闭会话"), "⇧ ⌘ W")
                shortcut(store.text("Settings", "设置"), "⌘ ,")
                shortcut(store.text("Save settings", "保存设置"), "⌘ ↩")
            }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 16) { Text(title).font(.system(size: 14, weight: .semibold)); content() }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Palette.card).clipShape(RoundedRectangle(cornerRadius: 12)) }
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { HStack(alignment: .center, spacing: 14) { Text(title).foregroundStyle(Palette.muted).frame(width: 112, alignment: .leading); content().frame(maxWidth: .infinity, alignment: .trailing) } }
    private func note(_ text: String) -> some View { Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
    private func shortcut(_ title: String, _ keys: String) -> some View { HStack { Text(title).foregroundStyle(Palette.muted); Spacer(); Text(keys).font(.system(size: 12, weight: .medium, design: .monospaced)) } }
    private func pathField(_ title: String, text: Binding<String>, placeholder: String, directory: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(Palette.muted)
            HStack { TextField(placeholder, text: text).appInput(); Button(store.text("Browse…", "选择…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false; if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path } }.buttonStyle(ChromeButtonStyle()) }
        }
    }
    private func colorRow(_ title: String, value: Binding<String>) -> some View {
        row(title) {
            HStack(spacing: 10) {
                TextField("#RRGGBB", text: value).appInput().font(.system(size: 12, design: .monospaced))
                ColorPicker(title, selection: Binding(get: { Color(hex: value.wrappedValue) }, set: { color in
                    if let rgb = NSColor(color).usingColorSpace(.deviceRGB) { value.wrappedValue = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded())) }
                }), supportsOpacity: false).labelsHidden()
            }
        }
    }
    private func reload() { draft = store.workspace.preferences; fontSizeInput = TerminalFontSizeNativeEditor.display(draft.fontSize); scrollbackValid = true; fontSizeValid = true; timeoutValid = true; error = ""; saved = false; draftRevision += 1 }
    private func saveTerminalColors(_ value: Preferences) throws {
        try store.commitTerminalColors(value)
        colorCommitSnapshot = store.workspace.preferences
        draft = draft.replacingTerminalColors(from: store.workspace.preferences)
        error = ""
    }
    private func save() {
        guard validNumbers else { return }
        do { try store.commitPreferences(draft); draft = store.workspace.preferences; saved = true; error = "" }
        catch { self.error = error.localizedDescription }
    }
}

/// A native action keeps keyboard and accessibility activation consistent in
/// this settings window, including when the color well has keyboard focus.
struct PreferencesRestoreThemeButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    func makeNSView(context: Context) -> PreferencesThemeResetNativeButton {
        let button = PreferencesThemeResetNativeButton()
        button.setButtonType(.momentaryPushIn); button.isBordered = false
        button.font = .systemFont(ofSize: 12); button.identifier = NSUserInterfaceItemIdentifier("axon-preferences-restore-theme")
        return button
    }
    func updateNSView(_ button: PreferencesThemeResetNativeButton, context: Context) { button.title = title; button.actionBlock = action; button.setAccessibilityLabel(title) }
}
final class PreferencesThemeResetNativeButton: PreferencesRectNativeButton {}
