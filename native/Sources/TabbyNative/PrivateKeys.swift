import AppKit
import SwiftUI
import Citadel
import Crypto

enum PrivateKeys {
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func authentication(_ text: String, passphrase: String, username: String, chinese: Bool) throws -> SSHAuthenticationMethod {
        let key = normalize(text)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure.message(chinese ? "请粘贴完整的私钥文本" : "Paste the complete private key text")
        }
        guard key.utf8.count <= 128 * 1024 else {
            throw AppFailure.message(chinese ? "私钥文本不能超过 128 KB" : "Private key text must be smaller than 128 KB")
        }
        let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        do {
            switch try SSHKeyDetection.detectPrivateKeyType(from: key) {
            case .ed25519: return .ed25519(username: username, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: key, decryptionKey: decryptionKey))
            case .rsa: return .rsa(username: username, privateKey: try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryptionKey))
            default: throw AppFailure.message(chinese ? "请使用 OpenSSH Ed25519 或 RSA 私钥" : "Use an OpenSSH Ed25519 or RSA private key")
            }
        } catch let error as AppFailure { throw error }
        catch {
            // Parser failures must never include the submitted key or its passphrase.
            throw AppFailure.message(chinese ? "私钥格式无效或口令不正确。请粘贴完整的 OpenSSH Ed25519 或 RSA 私钥。" : "Invalid private key or incorrect passphrase. Paste a complete OpenSSH Ed25519 or RSA private key.")
        }
    }
}

struct PrivateKeyInput: View {
    @EnvironmentObject var store: AppStore
    @Binding var source: String?
    @Binding var path: String
    @Binding var text: String
    var savedInKeychain = true
    var editorHeight: CGFloat = 150
    var compact = false
    private var selection: Binding<String> { Binding(get: { source ?? "file" }, set: { source = $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            BinaryChoiceControl(selection: selection, firstValue: "text", firstTitle: store.text("Paste text", "粘贴文本"),
                                secondValue: "file", secondTitle: store.text("Choose file", "选择文件"))
                .frame(height: BinaryChoiceView.controlHeight)
            if source == "text" {
                ZStack(alignment: .topLeading) {
                    PrivateKeyTextEditor(text: $text, label: store.text("Private key text", "私钥文本"))
                    if text.isEmpty {
                        Text(store.text("Paste the complete private key, including BEGIN and END lines", "粘贴完整私钥，包含 BEGIN 和 END 行"))
                            .font(.system(size: 12)).foregroundStyle(Palette.muted).padding(10).allowsHitTesting(false)
                    }
                }.frame(height: editorHeight).background(Palette.field).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.border, lineWidth: 1))
                Text(savedInKeychain ? store.text("OpenSSH Ed25519 / RSA · Saved in macOS Keychain", "OpenSSH Ed25519 / RSA · 保存到 macOS 钥匙串") : "OpenSSH Ed25519 / RSA")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                HStack {
                    TextField(store.text("Private key path", "私钥路径"), text: $path).appInput()
                    Button(store.text("Choose", "选择")) {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK { path = panel.url?.path ?? "" }
                    }.buttonStyle(ChromeButtonStyle())
                }
            }
        }
    }
}

private struct PrivateKeyTextEditor: NSViewRepresentable {
    @Binding var text: String
    var label: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.isRichText = false; editor.importsGraphics = false; editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false; editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false; editor.isAutomaticLinkDetectionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.textColor = NSColor(hex: "#171A2A"); editor.backgroundColor = NSColor(hex: "#E5EBEF")
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.delegate = context.coordinator
        scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = true
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scroll.documentView as! NSTextView
        editor.isEditable = enabled; editor.isSelectable = enabled; editor.setAccessibilityLabel(label)
        if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PrivateKeyTextEditor
        init(_ parent: PrivateKeyTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { parent.text = editor.string }
        }
    }
}
