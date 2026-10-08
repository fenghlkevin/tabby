import AppKit
import SwiftUI

struct AIComposer: NSViewRepresentable {
    @Binding var text: String
    var send: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let editor = AIComposerTextView(); editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 13); editor.textColor = NSColor(Palette.text); editor.insertionPointColor = NSColor(Palette.text)
        editor.textContainerInset = NSSize(width: 10, height: 10); editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.delegate = context.coordinator; editor.onSend = send; editor.string = text
        editor.setAccessibilityIdentifier("axon-ai-question"); editor.setAccessibilityLabel("Message / 消息 · Enter 发送，Shift+Enter 换行")
        scroll.documentView = editor; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? AIComposerTextView else { return }
        editor.onSend = send; if editor.string != text { editor.string = text }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AIComposer; init(_ parent: AIComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let editor = notification.object as? NSTextView { parent.text = editor.string } }
    }
}
final class AIComposerTextView: NSTextView {
    var onSend: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if [36,76].contains(event.keyCode), !hasMarkedText() {
            if event.modifierFlags.contains(.shift) { insertNewlineIgnoringFieldEditor(nil) }
            else { onSend() }
        } else { super.keyDown(with: event) }
    }
}
