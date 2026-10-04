import Foundation
import AppKit
import SwiftTerm

enum PreferencesValidation {
    static func validated(_ original: Preferences, chinese: Bool) throws -> Preferences {
        func failure(_ en: String, _ zh: String) -> AppFailure { .message(chinese ? zh : en) }
        var value = original
        guard ["auto", "zh-CN", "en-US"].contains(value.language) else { throw failure("Choose a language", "请选择语言") }
        guard ApplicationIconAppearance.styles.contains(value.applicationIcon) else { throw failure("Choose an application icon", "请选择应用图标") }
        value.fontName = value.fontName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.fontSize.isFinite, (10...40).contains(value.fontSize), NSFont(name: value.fontName, size: value.fontSize) != nil else { throw failure("Choose an installed font and a size from 10 to 40", "请选择已安装字体及 10–40 的字号") }
        guard (0...1_000_000).contains(value.scrollback) else { throw failure("Scrollback must be from 0 to 1000000", "回滚行数须为 0–1000000") }
        guard ["block", "bar", "underline"].contains(value.cursorShape) else { throw failure("Choose a cursor shape", "请选择光标形状") }
        guard BellStyle(tagName: value.bellStyle) != nil else { throw failure("Choose a bell style", "请选择铃声方式") }
        try TerminalThemeLibrary.validate(value, chinese: chinese)
        guard TerminalTheme.library(value).contains(where: { $0.id == value.terminalTheme }) else { throw failure("Choose a terminal theme", "请选择终端主题") }
        for color in [value.foreground, value.background, value.cursorColor] {
            guard color.count == 7, color.first == "#", color.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw failure("Colors must use #RRGGBB", "颜色须使用 #RRGGBB 格式") }
        }
        guard (1...120).contains(value.sshConnectTimeout) else { throw failure("Connection timeout must be from 1 to 120 seconds", "连接超时须为 1–120 秒") }
        for path in [value.localShell, value.localDirectory] {
            guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw failure("Paths cannot contain control characters", "路径不能包含控制字符") }
        }
        value.localShell = value.localShell.trimmingCharacters(in: .whitespacesAndNewlines)
        value.localDirectory = value.localDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.localShell.isEmpty {
            let path = (value.localShell as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue, FileManager.default.isExecutableFile(atPath: path) else { throw failure("Choose an existing executable shell using an absolute path", "请选择已存在、可执行的 Shell，并使用绝对路径") }
            value.localShell = path
        }
        if !value.localDirectory.isEmpty {
            let path = (value.localDirectory as NSString).expandingTildeInPath
            var directory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw failure("Choose an existing starting directory using an absolute path", "请选择已存在的启动目录，并使用绝对路径") }
            value.localDirectory = path
        }
        return value
    }
}

struct LocalTerminalLaunch: Equatable {
    let executable: String
    let arguments: [String]
    let directory: String
    init(preferences: Preferences, environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) {
        executable = preferences.localShell.isEmpty ? (environment["SHELL"] ?? "/bin/zsh") : preferences.localShell
        arguments = preferences.localLoginShell ? ["-l"] : []
        directory = preferences.localDirectory.isEmpty ? home : preferences.localDirectory
    }
}

enum TerminalAppearance {
    static func cursorStyle(_ preferences: Preferences) -> CursorStyle {
        switch (preferences.cursorShape, preferences.cursorBlink) {
        case ("bar", true): return .blinkBar
        case ("bar", false): return .steadyBar
        case ("underline", true): return .blinkUnderline
        case ("underline", false): return .steadyUnderline
        case (_, true): return .blinkBlock
        default: return .steadyBlock
        }
    }
    @MainActor static func apply(_ preferences: Preferences, to view: TerminalView) {
        view.font = NSFont(name: preferences.fontName, size: preferences.fontSize) ?? .monospacedSystemFont(ofSize: preferences.fontSize, weight: .light)
        view.optionAsMetaKey = preferences.optionAsMeta
        view.backspaceSendsControlH = preferences.backspaceControlH
        view.allowMouseReporting = preferences.mouseReporting
        view.bellStyle = BellStyle(tagName: preferences.bellStyle) ?? .none
        view.useBrightColors = true
        view.caretColor = NSColor(hex: preferences.cursorColor)
        view.nativeForegroundColor = NSColor(hex: preferences.foreground)
        view.nativeBackgroundColor = NSColor(hex: preferences.background)
        view.installColors(TerminalTheme.effectiveANSI(preferences).map { hex in
            let n = UInt32(hex.dropFirst(), radix: 16) ?? 0
            return SwiftTerm.Color(red8: UInt16((n >> 16) & 255), green8: UInt16((n >> 8) & 255), blue8: UInt16(n & 255))
        })
        view.setCursorStyle(cursorStyle(preferences))
        view.changeScrollback(max(0, min(1_000_000, preferences.scrollback)))
    }
}

enum TerminalPaste {
    static func prepared(_ text: String, preferences: Preferences) -> String {
        preferences.trimPaste ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
    static func needsConfirmation(_ text: String, preferences: Preferences) -> Bool {
        preferences.confirmMultilinePaste && (text.contains("\n") || text.contains("\r"))
    }
    /// Both terminal subclasses use this path. Cancellation never sends bytes.
    @MainActor static func perform(_ text: String, preferences: Preferences, confirm: (String) -> Bool, send: (String) -> Void) {
        let text = prepared(text, preferences: preferences)
        guard !text.isEmpty else { return }
        if needsConfirmation(text, preferences: preferences), !confirm(text) { return }
        send(text)
    }
    @MainActor static func confirm(_ text: String, chinese: Bool, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = chinese ? "粘贴多行内容？" : "Paste multiple lines?"
        alert.informativeText = chinese ? "多行内容可能立即执行命令，请确认后粘贴。" : "Multiple lines may execute commands immediately. Review before pasting."
        alert.addButton(withTitle: chinese ? "粘贴" : "Paste"); alert.addButton(withTitle: chinese ? "取消" : "Cancel")
        let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        preview.string = String(text.prefix(4000)); preview.isEditable = false; preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView(frame: preview.frame); scroll.documentView = preview; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        return alert.runModal() == .alertFirstButtonReturn
    }
}

@MainActor extension AppStore {
    func commitPreferences(_ draft: Preferences) throws {
        let value = try PreferencesValidation.validated(draft, chinese: chinese)
        let previous = workspace
        let iconChange = value.applicationIcon != previous.preferences.applicationIcon
            ? try applicationIconController?.prepare(value.applicationIcon, chinese: chinese) : nil
        workspace.preferences = value
        guard save() else {
            workspace = previous
            if iconChange?.rollback() == false {
                throw AppFailure.message(text("Could not save settings or restore the previous file icon. Choose the previous icon again after restoring write access.", "设置保存失败，旧图标也未能恢复。恢复写入权限后请重新选择旧图标。"))
            }
            throw AppFailure.message(error ?? text("Could not save settings", "无法保存设置"))
        }
        iconChange?.commit()
        for session in sessions { if let terminal = session.terminal { TerminalAppearance.apply(value, to: terminal) } }
    }

    func applyApplicationIconAtLaunch() {
        do { try applicationIconController?.prepare(workspace.preferences.applicationIcon, chinese: chinese).commit() }
        catch { self.error = error.localizedDescription }
    }
}
