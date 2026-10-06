import SwiftUI
import AppKit

/// Keep the existing string storage readable while using individual tokens in the UI.
enum TagTokens {
    static func parse(_ value: String) -> [String] {
        unique(value.split(whereSeparator: { $0.isWhitespace || ",，;；".contains($0) }).map(String.init))
    }
    static func unique(_ values: [String]) -> [String] {
        CatalogNames.unique(values)
    }
    static func serialized(_ values: [String]) -> String { unique(values).joined(separator: ", ") }
    static func committing(_ tags: String, draft: String) -> String { serialized(parse(tags) + parse(draft)) }
    static func removing(_ tag: String, from value: String) -> String {
        serialized(parse(value).filter { $0.caseInsensitiveCompare(tag) != .orderedSame })
    }
    /// A comma commits only the completed tokens; text after the last comma remains editable.
    static func consuming(_ tags: String, draft: String) -> (tags: String, pending: String) {
        guard let last = draft.lastIndex(where: { ",，;；\n\r".contains($0) }) else { return (tags, draft) }
        return (committing(tags, draft: String(draft[...last])), String(draft[draft.index(after: last)...]))
    }
}

struct TagsEditor: View {
    @Binding var tags: String
    @Binding var pending: String
    let suggestions: [String]
    let chinese: Bool
    private var tokens: [String] { TagTokens.parse(tags) }
    private var available: [String] {
        let query = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        return TagTokens.unique(suggestions).filter {
            !CatalogNames.contains(tokens, $0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }
    }
    private func text(_ english: String, _ chinese: String) -> String { self.chinese ? chinese : english }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !tokens.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(tokens, id: \.self) { tag in
                        HStack(spacing: 5) {
                            Image(systemName: "tag.fill").font(.system(size: 9))
                            Text(tag).font(.system(size: 12)).lineLimit(1)
                            Button { tags = TagTokens.removing(tag, from: tags) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 22)
                            }.buttonStyle(AxonSurfaceButtonStyle()).accessibilityLabel(text("Remove tag \(tag)", "移除标签 \(tag)"))
                        }.foregroundStyle(Palette.blue).padding(.leading, 9).padding(.trailing, 3)
                            .background(Palette.selected).clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 8) {
                TagEntryInput(value: $pending, placeholder: text("Enter a tag", "输入标签"),
                              label: text("New tag", "新标签"), onInput: consume, onSubmit: commit)
                    .appInput().accessibilityIdentifier("axon-tag-input")
                Button(action: commit) { Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 38) }
                    .buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.accent).background(Palette.field)
                    .clipShape(RoundedRectangle(cornerRadius: 8)).disabled(TagTokens.parse(pending).isEmpty)
                    .accessibilityLabel(text("Add tag", "添加标签")).help(text("Add tag", "添加标签"))
            }
            Text(text("Press Return or enter a comma to add a tag.", "按回车或输入逗号添加标签。"))
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            if !available.isEmpty {
                TagFlowLayout(spacing: 6) {
                    ForEach(Array(available.prefix(8)), id: \.self) { tag in
                        Button { tags = TagTokens.committing(tags, draft: tag); pending = "" } label: {
                            Label(tag, systemImage: "plus").font(.system(size: 11)).padding(.horizontal, 8).frame(height: 24)
                        }.buttonStyle(AxonSurfaceButtonStyle()).foregroundStyle(Palette.muted)
                            .background(Palette.field).clipShape(Capsule())
                            .accessibilityLabel(text("Add existing tag \(tag)", "添加已有标签 \(tag)"))
                    }
                }
            }
        }
    }
    private func commit() { tags = TagTokens.committing(tags, draft: pending); pending = "" }
    private func consume(_ value: String) -> String {
        let result = TagTokens.consuming(tags, draft: value)
        tags = result.tags; pending = result.pending
        return result.pending
    }
}

/// Consume Return in the text editor so it adds a chip without invoking another form button.
struct TagEntryInput: NSViewRepresentable {
    @Binding var value: String
    let placeholder: String
    let label: String
    let onInput: (String) -> String
    let onSubmit: () -> Void
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> TagEntryDelegate { TagEntryDelegate() }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.textColor = NSColor(Palette.text)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onDraft = { input in value = input }
        field.placeholderString = placeholder; field.isEnabled = enabled
        field.setAccessibilityLabel(label); field.setAccessibilityIdentifier("axon-tag-input")
        if field.stringValue != value { field.stringValue = value }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 220, height: 17)
    }
}

final class TagEntryDelegate: NSObject, NSTextFieldDelegate {
    var onInput: (String) -> String = { $0 }
    var onDraft: (String) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field.isEnabled else { return }
        if (field.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            // Punctuation in a Chinese/Japanese candidate is still provisional.
            onDraft(field.stringValue)
            return
        }
        let remaining = onInput(field.stringValue)
        if remaining != field.stringValue { replace(field, with: remaining) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), control.isEnabled, !textView.hasMarkedText() else { return false }
        if let field = control as? NSTextField { _ = onInput(field.stringValue) }
        onSubmit()
        if let field = control as? NSTextField { replace(field, with: "") }
        return true
    }
    private func replace(_ field: NSTextField, with value: String) {
        field.stringValue = value
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = value; editor.setSelectedRange(NSRange(location: (value as NSString).length, length: 0))
        }
    }
}

struct TagFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = positions(width: proposal.width ?? 300, subviews: subviews)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (index, position) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                                 anchor: .topLeading, proposal: ProposedViewSize(result.sizes[index]))
        }
    }
    private func positions(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var origins: [CGPoint] = [], sizes: [CGSize] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, measuredWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: max(0, width), height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y)); sizes.append(size)
            measuredWidth = max(measuredWidth, x + size.width)
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (origins, sizes, measuredWidth, y + rowHeight)
    }
}
