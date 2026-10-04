import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class BackupPasswordPreferencesTests: XCTestCase {
    func testCloudFolderSaveFollowsEveryPasswordEditIncludingClearingAndFocusLoss() async throws {
        _ = NSApplication.shared
        let fixture = makeStore(); defer { fixture.store.monitoring.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let hosting = NSHostingView(rootView: ScrollView { CloudBackupPreferencesPane().padding(24) }
            .environmentObject(fixture.store).preferredColorScheme(.light))
        let window = show(hosting); defer { window.close() }
        try await settle(hosting)

        let password = try secureField("axon-cloud-password", in: hosting)
        try await exercisePasswordEdits(password, in: window, hosting: hosting) { valid in
            try self.assertEnabled(valid, identifier: "axon-cloud-folder-save", in: hosting)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudConnectionPersistence.url(workspaceURL: fixture.store.fileURL).path))
    }

    func testS3UploadRequiresCurrentPasswordAndClearingSecretDisablesAllConnectionActions() async throws {
        _ = NSApplication.shared
        let fixture = makeStore(); defer { fixture.store.monitoring.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let hosting = NSHostingView(rootView: ScrollView { CloudBackupPreferencesPane().padding(24) }
            .environmentObject(fixture.store).preferredColorScheme(.light))
        let window = show(hosting); defer { window.close() }
        try await settle(hosting)

        let password = try secureField("axon-cloud-password", in: hosting)
        let secret = try secureField("axon-cloud-secret", in: hosting)
        for identifier in ["axon-cloud-save", "axon-cloud-upload", "axon-cloud-download"] {
            try assertEnabled(false, identifier: identifier, in: hosting)
        }
        try edit(secret, replacingWith: "fixture-secret", in: window)
        try await settle(hosting)
        try await exercisePasswordEdits(password, in: window, hosting: hosting) { valid in
            try self.assertEnabled(valid, identifier: "axon-cloud-upload", in: hosting)
            try self.assertEnabled(true, identifier: "axon-cloud-save", in: hosting)
            try self.assertEnabled(true, identifier: "axon-cloud-download", in: hosting)
        }
        try edit(password, replacingWith: "12345678", in: window)
        try await settle(hosting)
        try assertEnabled(true, identifier: "axon-cloud-upload", in: hosting)
        try edit(secret, replacingWith: "", in: window)
        try await settle(hosting)
        XCTAssertEqual(secret.stringValue, "")
        for identifier in ["axon-cloud-save", "axon-cloud-upload", "axon-cloud-download"] {
            try assertEnabled(false, identifier: identifier, in: hosting)
        }
        // Enabled actions are never pressed: editing does not upload, download,
        // or persist the fixture Secret Access Key in Keychain.
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CloudConnectionPersistence.url(workspaceURL: fixture.store.fileURL).path))
    }

    func testLocalEncryptedBackupSaveFollowsPasswordEditsAndEncryptionToggle() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility(); defer { restoreAccessibility() }
        let fixture = makeStore(); defer { fixture.store.monitoring.stop(); try? FileManager.default.removeItem(at: fixture.directory) }
        let hosting = NSHostingView(rootView: ScrollView { ImportPreferencesPane().padding(24) }
            .environmentObject(fixture.store).preferredColorScheme(.light))
        let window = show(hosting); defer { window.close() }
        try await settle(hosting)

        try assertEnabled(true, identifier: "axon-backup-export", in: hosting)
        try pressEncryptionToggle(in: hosting)
        try await settle(hosting)
        let password = try secureField("axon-backup-password", in: hosting)
        try await exercisePasswordEdits(password, in: window, hosting: hosting) { valid in
            try self.assertEnabled(valid, identifier: "axon-backup-export", in: hosting)
        }
        try pressEncryptionToggle(in: hosting)
        try await settle(hosting)
        try assertEnabled(true, identifier: "axon-backup-export", in: hosting)
        try pressEncryptionToggle(in: hosting)
        try await settle(hosting)
        try assertEnabled(false, identifier: "axon-backup-export", in: hosting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    func testPreferencesActionHonorsAncestorDisabledAcrossTransitionsAndRejectsNativeAndAXPresses() async throws {
        _ = NSApplication.shared
        let state = ActionState()
        let hosting = NSHostingView(rootView: ActionFixture(state: state))
        let window = show(hosting, size: NSSize(width: 260, height: 80)); defer { window.close() }
        try await settle(hosting)
        let button = try actionButton("axon-disabled-fixture", in: hosting)

        try assertEnabled(false, identifier: "axon-disabled-fixture", in: hosting)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        XCTAssertEqual(state.activations, 0)
        state.disabled = false
        try await settle(hosting)
        try assertEnabled(true, identifier: "axon-disabled-fixture", in: hosting)
        XCTAssertTrue(button.accessibilityPerformPress())
        button.performClick(nil)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        XCTAssertEqual(state.activations, 3)

        state.disabled = true
        try await settle(hosting)
        try assertEnabled(false, identifier: "axon-disabled-fixture", in: hosting)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        XCTAssertEqual(state.activations, 3)
        state.disabled = false; state.explicitlyEnabled = false
        try await settle(hosting)
        try assertEnabled(false, identifier: "axon-disabled-fixture", in: hosting)
        XCTAssertEqual(state.activations, 3, "An enabled ancestor cannot override the button's explicit disabled state")
    }

    // Use the real field editor rather than assigning stringValue or manually
    // calling the delegate, so insertion, deletion and focus loss take the
    // same NSTextField notification path as interactive editing.
    private func exercisePasswordEdits(_ field: NSSecureTextField, in window: NSWindow,
                                       hosting: NSView, verify: (Bool) throws -> Void) async throws {
        XCTAssertEqual(field.stringValue, "")
        try verify(false)
        var editor = try beginEditing(field, in: window)
        editor.insertText("12345678", replacementRange: editor.selectedRange())
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, "12345678"); try verify(true)

        editor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, "1234567"); try verify(false)
        editor.selectAll(nil); editor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, ""); try verify(false)

        editor.insertText("abcdefgh", replacementRange: editor.selectedRange())
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, "abcdefgh"); try verify(true)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, "abcdefgh"); try verify(true)

        editor = try beginEditing(field, in: window)
        editor.selectAll(nil); editor.deleteBackward(nil)
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, ""); try verify(false)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(hosting)
        XCTAssertEqual(field.stringValue, ""); try verify(false)
    }

    private func edit(_ field: NSSecureTextField, replacingWith value: String, in window: NSWindow) throws {
        let editor = try beginEditing(field, in: window)
        editor.selectAll(nil); editor.deleteBackward(nil)
        if !value.isEmpty { editor.insertText(value, replacementRange: editor.selectedRange()) }
    }
    private func beginEditing(_ field: NSSecureTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(field.isEnabled)
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        return try XCTUnwrap(field.currentEditor() as? NSTextView, "The hosted secure field must provide its real editor")
    }
    private func assertEnabled(_ enabled: Bool, identifier: String, in root: NSView,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let button = try actionButton(identifier, in: root)
        XCTAssertEqual(button.isEnabled, enabled, identifier, file: file, line: line)
        XCTAssertEqual(button.isAccessibilityEnabled(), enabled, identifier, file: file, line: line)
        if !enabled && !button.isEnabled {
            XCTAssertFalse(button.accessibilityPerformPress(), identifier, file: file, line: line)
            button.performClick(nil)
        }
    }
    private func actionButton(_ identifier: String, in root: NSView) throws -> PreferencesRectNativeButton {
        try XCTUnwrap(find(PreferencesRectNativeButton.self, in: root).first { $0.identifier?.rawValue == identifier })
    }
    private func secureField(_ identifier: String, in root: NSView) throws -> NSSecureTextField {
        try XCTUnwrap(find(NSSecureTextField.self, in: root).first { $0.identifier?.rawValue == identifier })
    }
    private func pressEncryptionToggle(in root: NSView) throws {
        let toggle = try XCTUnwrap(accessibilityObjects(root).first {
            read($0, "accessibilityIdentifier") as? String == "axon-backup-encryption"
                && read($0, "accessibilityRole") as? String == NSAccessibility.Role.checkBox.rawValue
        }, "The actual backup pane must expose its encryption checkbox")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(toggle.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(toggle.method(for: selector), to: Press.self)(toggle, selector))
    }
    private func makeStore() -> (directory: URL, store: AppStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-backup-password-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        return (directory, store)
    }
    private final class ActionState: ObservableObject {
        @Published var disabled = true
        @Published var explicitlyEnabled = true
        var activations = 0
    }
    private struct ActionFixture: View {
        @ObservedObject var state: ActionState
        var body: some View {
            VStack {
                PreferencesActionButton(title: "Fixture action", identifier: "axon-disabled-fixture", enabled: state.explicitlyEnabled) {
                    state.activations += 1
                }.frame(width: 180, height: 38)
            }.disabled(state.disabled)
        }
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize = NSSize(width: 900, height: 1400)) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
    private func read(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }
    private func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in read(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root); return result
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key)
        NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
}
