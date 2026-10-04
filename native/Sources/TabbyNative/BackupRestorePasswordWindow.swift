import AppKit
import SwiftUI

@MainActor final class BackupRestorePasswordModel: ObservableObject {
    @Published var password = ""
    let chinese: Bool
    let error: String?
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(chinese: Bool, error: String?) {
        self.chinese = chinese
        // Codec errors are bilingual; the dialog uses the selected language.
        let parts = error?.components(separatedBy: " / ")
        self.error = chinese ? parts?.last : parts?.first
    }
    func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    func submit() { guard !password.isEmpty else { return }; onSubmit?(password) }
}

/// A small app-styled modal keeps recovery credentials separate from backup
/// settings. Its close button cancels recovery rather than hiding the main app.
@MainActor final class BackupRestorePasswordWindowController: NSObject, NSWindowDelegate {
    let model: BackupRestorePasswordModel
    private(set) var window: NSWindow?
    private var presenting = false
    private var result: String?

    init(chinese: Bool, error: String?) {
        model = BackupRestorePasswordModel(chinese: chinese, error: error)
        super.init()
        model.onSubmit = { [weak self] in self?.finish($0) }
        model.onCancel = { [weak self] in self?.cancel() }
    }
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = model.text("Restore encrypted backup", "恢复加密备份")
        panel.identifier = NSUserInterfaceItemIdentifier("axon-backup-password-dialog")
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.backgroundColor = NSColor(Palette.card)
        panel.appearance = NSAppearance(named: .aqua)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(button)?.isHidden = true }
        panel.delegate = self
        let hosting = NSHostingView(rootView: BackupRestorePasswordView(model: model).preferredColorScheme(.light))
        hosting.sizingOptions = []
        panel.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        panel.initialFirstResponder = passwordInput(in: hosting)?.activeField
        window = panel
        return panel
    }
    func present() -> String? {
        let parent = NSApp.keyWindow ?? NSApp.mainWindow
        let panel = prepareWindow()
        if let parent, parent !== panel {
            panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                        y: parent.frame.midY - panel.frame.height / 2))
        } else { panel.center() }
        result = nil; presenting = true
        defer {
            presenting = false
            panel.endEditing(for: nil)
            passwordInput(in: panel.contentView)?.clearSensitiveText()
            model.password = ""
            panel.orderOut(nil); panel.delegate = nil; panel.close()
            window = nil; result = nil
        }
        panel.makeKeyAndOrderFront(nil)
        if let input = passwordInput(in: panel.contentView) { panel.makeFirstResponder(input.activeField) }
        NSApp.runModal(for: panel)
        return result
    }
    func cancel() { finish(nil) }
    private func finish(_ value: String?) {
        guard presenting, let window, NSApp.modalWindow === window else { return }
        result = value
        NSApp.stopModal(withCode: value == nil ? .cancel : .OK)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { cancel(); return false }
    private func passwordInput(in root: NSView?) -> PasswordInputView? {
        guard let root else { return nil }
        if let input = root as? PasswordInputView { return input }
        for child in root.subviews { if let input = passwordInput(in: child) { return input } }
        return nil
    }
}

struct BackupRestorePasswordView: View {
    @ObservedObject var model: BackupRestorePasswordModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield").font(.system(size: 22, weight: .medium)).foregroundStyle(Palette.blue)
                    .frame(width: 36, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.text("Restore encrypted backup", "恢复加密备份")).font(.system(size: 16, weight: .semibold))
                    Text(model.text("Enter the password used to create this backup.", "输入创建此备份时使用的密码。"))
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
                Button { model.onCancel?() } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle()).accessibilityLabel(model.text("Cancel restore", "取消恢复"))
                    .accessibilityIdentifier("axon-restore-password-close")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(model.text("Backup password", "备份密码")).font(.system(size: 12, weight: .medium))
                PreferencesSecureField(title: model.text("Enter backup password", "输入备份密码"), text: $model.password,
                                       identifier: "axon-restore-password", chinese: model.chinese, onSubmit: model.submit).appInput()
            }
            Group {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(Color(hex: "#C42B38"))
                        .accessibilityIdentifier("axon-restore-password-error")
                } else {
                    Text(model.text("Review and confirm the workspace after decryption.", "解密成功后，再确认恢复工作区。"))
                        .foregroundStyle(Palette.muted)
                }
            }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Spacer()
                PreferencesActionButton(title: model.text("Cancel", "取消"), identifier: "axon-restore-password-cancel", action: { model.onCancel?() })
                    .frame(width: 100, height: 38)
                PreferencesActionButton(title: model.text("Decrypt & continue", "解密并继续"), identifier: "axon-restore-password-submit",
                                        prominent: true, enabled: !model.password.isEmpty, action: model.submit)
                    .frame(width: 142, height: 38).disabled(model.password.isEmpty)
            }
        }.padding(24).frame(width: 440, height: 300).background(Palette.card).foregroundStyle(Palette.text)
            .onExitCommand { model.onCancel?() }
    }
}
