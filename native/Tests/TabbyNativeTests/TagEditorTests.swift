import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

final class TagEditorTests: XCTestCase {
    func testLegacyAndUnicodeDelimitersAreTrimmedAndDeduplicated() {
        XCTAssertEqual(TagTokens.parse("  Prod, prod，数据库;test test；  \n"), ["Prod", "数据库", "test"])
        XCTAssertEqual(TagTokens.committing("Prod, db", draft: " prod，New "), "Prod, db, New")
        XCTAssertEqual(TagTokens.removing("pRoD", from: "Prod db PROD New"), "db, New")
        XCTAssertEqual(TagTokens.committing("", draft: " pending "), "pending")
    }

    func testCommaAddsCompletedTagsAndRetainsUnfinishedDraftUntilReturnOrSave() {
        var result = TagTokens.consuming("Old", draft: "new, next， unfinished")
        XCTAssertEqual(result.tags, "Old, new, next")
        XCTAssertEqual(result.pending, " unfinished")
        XCTAssertEqual(TagTokens.committing(result.tags, draft: result.pending), "Old, new, next, unfinished")
        result = TagTokens.consuming(result.tags, draft: "Old,")
        XCTAssertEqual(result.tags, "Old, new, next")
        XCTAssertEqual(result.pending, "")
        result = TagTokens.consuming("Old", draft: "typing")
        XCTAssertEqual(result.tags, "Old")
        XCTAssertEqual(result.pending, "typing")
    }

    @MainActor func testNativeReturnAddsLatestTextAndConsumesCommandWithoutFormSubmission() {
        _ = NSApplication.shared
        let field = NSTextField()
        let delegate = TagEntryDelegate()
        var tags = "existing", pending = "", submitted = 0
        delegate.onInput = { value in
            let result = TagTokens.consuming(tags, draft: value)
            tags = result.tags; pending = result.pending
            return result.pending
        }
        delegate.onSubmit = { tags = TagTokens.committing(tags, draft: pending); pending = ""; submitted += 1 }
        field.stringValue = "new"
        // Return also reconciles the native field's final text before invoking submission.
        XCTAssertTrue(delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(tags, "existing, new")
        XCTAssertEqual(pending, "")
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(submitted, 1)
        XCTAssertFalse(delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(submitted, 1)
        field.isEnabled = false
        field.stringValue = "disabled"
        XCTAssertFalse(delegate.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, 1)
    }

    @MainActor func testNativeCommaCommitsTokensAndKeepsTypingFieldInSync() {
        _ = NSApplication.shared
        let field = NSTextField()
        let delegate = TagEntryDelegate()
        var tags = "", pending = ""
        delegate.onInput = { value in
            let result = TagTokens.consuming(tags, draft: value)
            tags = result.tags; pending = result.pending
            return result.pending
        }
        field.stringValue = "database，test"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(tags, "database")
        XCTAssertEqual(pending, "test")
        XCTAssertEqual(field.stringValue, "test")
        field.stringValue = "test,"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(tags, "database, test")
        XCTAssertEqual(pending, "")
        XCTAssertEqual(field.stringValue, "")
        field.isEnabled = false
        field.stringValue = "ignored,"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(tags, "database, test")
    }

    @MainActor func testChineseIMEKeepsMarkedTextUntilCompositionCommits() {
        _ = NSApplication.shared
        let editor = NSTextView()
        let field = MarkedTagTestField()
        field.editor = editor
        let delegate = TagEntryDelegate()
        var submitted = 0, consumed = 0, pending = ""
        delegate.onDraft = { pending = $0 }
        delegate.onInput = { value in consumed += 1; return value }
        delegate.onSubmit = { submitted += 1 }
        editor.setMarkedText("数据库，", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        field.stringValue = "数据库，"
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(consumed, 0)
        XCTAssertEqual(pending, "数据库，")
        XCTAssertEqual(field.stringValue, "数据库，")
        XCTAssertFalse(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, 0)
        editor.unmarkText()
        delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(consumed, 1)
        XCTAssertTrue(delegate.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, 1)
    }

    @MainActor func testCatalogAndTagEditorRenderWhenCaptureRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.groups = ["公司服务器", "personal", "Imported"]
        store.workspace.tags = ["database", "backend", "生产环境", "test", "frontend"]
        var host = TabbyNative.Host(); host.group = "公司服务器"; host.tags = "database, backend"; host.address = "fixture.invalid"
        store.workspace.hosts = [host]
        try await capture(AnyView(TagsManagementView().environmentObject(store)), size: NSSize(width: 570, height: 560),
                          url: directory.appendingPathComponent("catalog-tags.png"))
        try await capture(AnyView(TagEditorFixture()), size: NSSize(width: 320, height: 260), url: directory.appendingPathComponent("tag-editor.png"))
    }

    @MainActor private func capture(_ view: AnyView, size: NSSize, url: URL) async throws {
        let hosting = NSHostingView(rootView: view); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}

private final class MarkedTagTestField: NSTextField {
    var editor: NSTextView?
    override func currentEditor() -> NSText? { editor }
}

private struct TagEditorFixture: View {
    @State private var tags = "database, backend, 生产环境"
    @State private var pending = "new"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("标签").font(.system(size: 13)).foregroundStyle(Palette.muted)
            TagsEditor(tags: $tags, pending: $pending, suggestions: ["database", "test", "frontend", "local"], chinese: true)
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.sidebar)
    }
}
