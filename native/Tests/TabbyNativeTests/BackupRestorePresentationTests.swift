import AppKit
import XCTest
@testable import TabbyNative

@MainActor final class BackupRestorePresentationTests: XCTestCase {
    private let password = "restore-password-fixture"

    private func workspace() -> Workspace {
        var host = TabbyNative.Host()
        host.name = "Restore fixture"
        host.address = "restore.example.invalid"
        host.username = "fixture"
        var value = Workspace()
        value.hosts = [host]
        return value
    }

    private func mutateJSON(_ data: Data, _ mutation: (inout [String: Any]) -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutation(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    func testPlainBackupRestoresWithoutRequestingAnyPassword() throws {
        let original = workspace()
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: nil)
        var requests = 0
        let restored = try XCTUnwrap(BackupPresentation.decodeForRestore(data, chinese: true) { _ in
            requests += 1
            return "unused-password-fixture"
        })
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(restored.workspace.hosts, original.hosts)
        XCTAssertNil(restored.secrets)
    }

    func testEachEncryptedRestoreRequestsItsOwnPasswordAndReturnsIncludedCredentials() throws {
        let original = workspace()
        let id = original.hosts[0].id
        let secrets = [id: Secrets.Value(secret: "host-password-fixture", privateKey: "pasted-private-key-fixture")]
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: password, secrets: secrets)
        var requests = 0
        for chinese in [true, false] {
            let restored = try XCTUnwrap(BackupPresentation.decodeForRestore(data, chinese: chinese) { error in
                requests += 1
                XCTAssertNil(error, "Every new restore starts with a fresh prompt")
                return self.password
            })
            XCTAssertEqual(restored.workspace.hosts, original.hosts)
            XCTAssertEqual(restored.secrets?[id.uuidString], ArchiveSecret(secret: "host-password-fixture", privateKey: "pasted-private-key-fixture"))
        }
        XCTAssertEqual(requests, 2, "A completed restore must not cache or reuse its password for the next restore")
    }

    func testEmptyAndWrongPasswordsRetryWithTheirErrorBeforeCorrectPasswordSucceeds() throws {
        let original = workspace()
        let data = try WorkspaceArchiveCodec.encode(workspace: original, password: password)
        let answers = ["", "wrong-password-fixture", password]
        var failures: [String?] = []
        let restored = try XCTUnwrap(BackupPresentation.decodeForRestore(data, chinese: true) { failure in
            failures.append(failure)
            guard failures.count <= answers.count else { XCTFail("Unexpected extra retry"); return nil }
            return answers[failures.count - 1]
        })
        XCTAssertEqual(failures.count, 3)
        XCTAssertNil(failures[0])
        XCTAssertEqual(failures[1], WorkspaceArchiveError.passwordRequired.localizedDescription)
        XCTAssertEqual(failures[2], WorkspaceArchiveError.authenticationFailed.localizedDescription)
        XCTAssertEqual(restored.workspace.hosts, original.hosts)
        XCTAssertTrue(restored.secrets?.isEmpty == true, "Encryption by itself does not include credentials")
        XCTAssertFalse(failures.compactMap { $0 }.contains { $0.contains(password) || $0.contains("wrong-password-fixture") })
    }

    func testCancelInitiallyOrAfterWrongPasswordReturnsNoArchive() throws {
        let data = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: password)
        var firstRequests = 0
        let initiallyCancelled = try BackupPresentation.decodeForRestore(data, chinese: false) { error in
            firstRequests += 1
            XCTAssertNil(error)
            return nil
        }
        XCTAssertNil(initiallyCancelled)
        XCTAssertEqual(firstRequests, 1)

        var retryRequests = 0
        let retryCancelled = try BackupPresentation.decodeForRestore(data, chinese: true) { error in
            retryRequests += 1
            if retryRequests == 1 { XCTAssertNil(error); return "wrong-password-fixture" }
            XCTAssertEqual(error, WorkspaceArchiveError.authenticationFailed.localizedDescription)
            return nil
        }
        XCTAssertNil(retryCancelled)
        XCTAssertEqual(retryRequests, 2)
    }

    func testMalformedOrUnsupportedBackupErrorsPropagateWithoutPasswordRetry() throws {
        let encrypted = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: password)
        let plain = try WorkspaceArchiveCodec.encode(workspace: workspace(), password: nil)
        let fixtures: [(data: Data, expected: WorkspaceArchiveError, passwordRequests: Int)] = [
            (Data("not-a-backup-fixture".utf8), .invalidArchive, 0),
            (try mutateJSON(plain) { $0["version"] = 2 }, .unsupportedVersion, 0),
            (try mutateJSON(encrypted) { $0["version"] = 2 }, .unsupportedVersion, 1),
            (try mutateJSON(encrypted) { $0["salt"] = Data([1, 2, 3]).base64EncodedString() }, .invalidArchive, 1),
            (try mutateJSON(encrypted) { $0.removeValue(forKey: "sealed") }, .invalidArchive, 1),
            (Data(repeating: 0, count: WorkspaceArchiveCodec.maximumBytes + 1), .tooLarge, 0),
        ]
        for fixture in fixtures {
            var requests = 0
            XCTAssertThrowsError(try BackupPresentation.decodeForRestore(fixture.data, chinese: false) { error in
                requests += 1
                XCTAssertNil(error)
                if requests > 1 { XCTFail("Invalid formats must propagate instead of retrying the password"); return nil }
                return self.password
            }) { error in
                XCTAssertEqual(error.localizedDescription, fixture.expected.localizedDescription)
            }
            XCTAssertEqual(requests, fixture.passwordRequests)
        }
    }

    func testFreshPasswordPanelIsCompactUsesAppPaletteAndFocusesEmptySecureField() async throws {
        _ = NSApplication.shared
        let first = BackupRestorePasswordWindowController(chinese: true, error: nil)
        let firstWindow = first.prepareWindow()
        defer { firstWindow.delegate = nil; firstWindow.close() }
        let firstRoot = try XCTUnwrap(firstWindow.contentView)
        try await settle(firstRoot)
        let firstField = try secureField(in: firstRoot)
        XCTAssertTrue(firstWindow is NSPanel)
        XCTAssertEqual(firstWindow.identifier?.rawValue, "axon-backup-password-dialog")
        XCTAssertTrue(firstWindow.styleMask.contains(.titled))
        XCTAssertTrue(firstWindow.styleMask.contains(.closable))
        XCTAssertFalse(firstWindow.styleMask.contains(.resizable))
        XCTAssertEqual(firstWindow.frame.width, 440, accuracy: 1)
        XCTAssertLessThanOrEqual(firstWindow.frame.height, 340)
        XCTAssertEqual(firstWindow.backgroundColor, NSColor(Palette.card))
        XCTAssertEqual(firstWindow.titleVisibility, .hidden)
        XCTAssertTrue(firstWindow.initialFirstResponder === firstField)
        XCTAssertTrue(firstField.cell is NSSecureTextFieldCell)
        XCTAssertEqual(firstField.stringValue, "")
        XCTAssertEqual(first.model.password, "")
        XCTAssertNil(first.model.error)
        XCTAssertEqual(firstField.identifier?.rawValue, "axon-restore-password")
        XCTAssertEqual(firstField.accessibilityIdentifier(), "axon-restore-password")
        XCTAssertEqual(firstField.accessibilityLabel(), "输入备份密码")
        XCTAssertEqual(try actionButton("axon-restore-password-submit", in: firstRoot).title, "解密并继续")
        XCTAssertEqual(try actionButton("axon-restore-password-cancel", in: firstRoot).title, "取消")
        for image in find(NSImageView.self, in: firstRoot) {
            XCTAssertLessThanOrEqual(image.frame.width, 48, "The restore panel must not contain a large application icon")
            XCTAssertLessThanOrEqual(image.frame.height, 48)
        }
        first.model.password = "previous-attempt-password-fixture"

        let error = WorkspaceArchiveError.authenticationFailed.localizedDescription
        let retry = BackupRestorePasswordWindowController(chinese: false, error: error)
        let retryWindow = retry.prepareWindow()
        defer { retryWindow.delegate = nil; retryWindow.close() }
        let retryRoot = try XCTUnwrap(retryWindow.contentView)
        try await settle(retryRoot)
        let retryField = try secureField(in: retryRoot)
        XCTAssertFalse(firstField === retryField)
        XCTAssertEqual(retryField.stringValue, "", "A retry must not prefill a previously entered password")
        XCTAssertEqual(retry.model.password, "")
        XCTAssertEqual(retry.model.error, error.components(separatedBy: " / ").first)
        XCTAssertTrue(retryWindow.initialFirstResponder === retryField)
        XCTAssertEqual(retryField.accessibilityIdentifier(), "axon-restore-password")
        XCTAssertEqual(retryField.accessibilityLabel(), "Enter backup password")
        XCTAssertEqual(try actionButton("axon-restore-password-submit", in: retryRoot).title, "Decrypt & continue")
        XCTAssertEqual(try actionButton("axon-restore-password-cancel", in: retryRoot).title, "Cancel")
        XCTAssertFalse(firstWindow.isVisible)
        XCTAssertFalse(retryWindow.isVisible)
    }

    func testPasswordModelRejectsEmptySubmissionAndLocalizesRetryErrors() {
        let error = WorkspaceArchiveError.authenticationFailed.localizedDescription
        let english = BackupRestorePasswordModel(chinese: false, error: error)
        let chinese = BackupRestorePasswordModel(chinese: true, error: error)
        XCTAssertEqual(english.error, error.components(separatedBy: " / ").first)
        XCTAssertEqual(chinese.error, error.components(separatedBy: " / ").last)
        var submitted: [String] = []
        english.onSubmit = { submitted.append($0) }
        english.submit()
        XCTAssertTrue(submitted.isEmpty)
        english.password = "a"
        english.submit()
        XCTAssertEqual(submitted, ["a"], "Restore submission requires a nonempty password and leaves verification to the archive codec")
        english.password = ""
        english.submit()
        XCTAssertEqual(submitted, ["a"])
    }

    func testLocalizedInitialAndErrorPanelsRenderWithinCompactBounds() async throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        let directory = URL(fileURLWithPath: "/private/tmp/axon-0.7.2-ui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for chinese in [true, false] {
            for error in [nil, WorkspaceArchiveError.authenticationFailed.localizedDescription] as [String?] {
                let controller = BackupRestorePasswordWindowController(chinese: chinese, error: error)
                let window = controller.prepareWindow()
                defer { window.delegate = nil; window.close() }
                window.center()
                window.makeKeyAndOrderFront(nil)
                let root = try XCTUnwrap(window.contentView)
                try await settle(root)
                window.displayIfNeeded()
                let name = "backup-restore-" + (chinese ? "zh" : "en") + (error == nil ? "-initial" : "-error")
                try renderAndAudit(root, window: window, directory: directory, name: name)
            }
        }
    }

    func testActualSecureFieldEditsAndClearingImmediatelyUpdateSubmitState() async throws {
        _ = NSApplication.shared
        let controller = BackupRestorePasswordWindowController(chinese: false, error: nil)
        let window = controller.prepareWindow()
        defer { window.delegate = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        let root = try XCTUnwrap(window.contentView)
        try await settle(root)
        let field = try secureField(in: root)
        let submit = try actionButton("axon-restore-password-submit", in: root)
        var submitted: [String] = []
        controller.model.onSubmit = { submitted.append($0) }
        try assertSubmitEnabled(false, button: submit, submitted: submitted)
        let editor = try beginEditing(field, in: window)
        editor.insertText(password, replacementRange: editor.selectedRange())
        try await settle(root)
        XCTAssertEqual(field.stringValue, password)
        XCTAssertEqual(controller.model.password, password)
        try assertSubmitEnabled(true, button: submit, submitted: submitted)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        try await settle(root)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(controller.model.password, "")
        try assertSubmitEnabled(false, button: submit, submitted: submitted)
        XCTAssertTrue(submitted.isEmpty)
        editor.insertText("another-password-fixture", replacementRange: editor.selectedRange())
        try await settle(root)
        try assertSubmitEnabled(true, button: submit, submitted: submitted)
        submit.performClick(nil)
        XCTAssertEqual(submitted, ["another-password-fixture"])
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(root)
        XCTAssertEqual(controller.model.password, "")
        try assertSubmitEnabled(false, button: submit, submitted: submitted)
        XCTAssertEqual(submitted, ["another-password-fixture"])
    }

    func testModalSubmitReturnsPasswordAndClearsModelAndNativeField() throws {
        _ = NSApplication.shared
        XCTAssertNil(NSApp.modalWindow)
        let controller = BackupRestorePasswordWindowController(chinese: false, error: nil)
        var field: NSSecureTextField?
        var inserted = false
        var submitted = false
        let submit = Timer(timeInterval: 0.03, repeats: true) { timer in
            guard let window = controller.window, NSApp.modalWindow === window, let root = window.contentView else { return }
            do {
                if !inserted {
                    let secure = try self.secureField(in: root)
                    field = secure
                    let editor = try self.beginEditing(secure, in: window)
                    editor.insertText(self.password, replacementRange: editor.selectedRange())
                    inserted = true
                    return
                }
                root.layoutSubtreeIfNeeded()
                let button = try self.actionButton("axon-restore-password-submit", in: root)
                guard button.isEnabled else { return }
                submitted = true
                timer.invalidate()
                button.performClick(nil)
            } catch {
                XCTFail("Could not submit the actual restore panel: \(error.localizedDescription)")
                timer.invalidate()
                controller.cancel()
            }
        }
        let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
            XCTFail("Restore password modal did not finish after submission")
            controller.cancel()
        }
        RunLoop.main.add(submit, forMode: .modalPanel)
        RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { submit.invalidate(); watchdog.invalidate() }
        XCTAssertEqual(controller.present(), password)
        XCTAssertTrue(inserted)
        XCTAssertTrue(submitted)
        XCTAssertEqual(controller.model.password, "")
        XCTAssertEqual(try XCTUnwrap(field).stringValue, "")
        XCTAssertNil(controller.window)
        XCTAssertNil(NSApp.modalWindow)
    }

    func testModalCancelAndWindowCloseClearPasswordAndLeaveUnrelatedWindowOpen() throws {
        _ = NSApplication.shared
        let restoreAccessibility = enableAccessibility()
        defer { restoreAccessibility() }
        XCTAssertNil(NSApp.modalWindow)
        let unrelated = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false
        unrelated.orderFront(nil)
        defer { unrelated.close() }
        for cancellation in ["window", "button", "close"] {
            let controller = BackupRestorePasswordWindowController(chinese: true, error: nil)
            let otherController = BackupRestorePasswordWindowController(chinese: false, error: nil)
            let otherWindow = otherController.prepareWindow()
            defer { otherWindow.delegate = nil; otherWindow.close() }
            var field: NSSecureTextField?
            var cancelled = false
            let cancel = Timer(timeInterval: 0.03, repeats: true) { timer in
                guard let window = controller.window, NSApp.modalWindow === window, let root = window.contentView else { return }
                do {
                    let secure = try self.secureField(in: root)
                    field = secure
                    let editor = try self.beginEditing(secure, in: window)
                    editor.insertText("cancelled-password-fixture", replacementRange: editor.selectedRange())
                    otherController.cancel()
                    XCTAssertTrue(NSApp.modalWindow === window, "Cancelling another controller must not stop this dialog's modal session")
                    cancelled = true
                    timer.invalidate()
                    if cancellation == "window" { window.performClose(nil) }
                    else if cancellation == "button" { try self.actionButton("axon-restore-password-cancel", in: root).performClick(nil) }
                    else { try self.pressClose(in: root) }
                } catch {
                    XCTFail("Could not cancel the actual restore panel: \(error.localizedDescription)")
                    timer.invalidate()
                    controller.cancel()
                }
            }
            let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
                XCTFail("Restore password modal did not finish after cancellation")
                controller.cancel()
            }
            RunLoop.main.add(cancel, forMode: .modalPanel)
            RunLoop.main.add(watchdog, forMode: .modalPanel)
            defer { cancel.invalidate(); watchdog.invalidate() }
            XCTAssertNil(controller.present())
            XCTAssertTrue(cancelled)
            XCTAssertEqual(controller.model.password, "")
            XCTAssertEqual(try XCTUnwrap(field).stringValue, "")
            XCTAssertNil(controller.window)
            XCTAssertNil(NSApp.modalWindow)
            XCTAssertTrue(unrelated.isVisible)
        }
    }

    func testCredentialCountsDistinguishPasswordsPrivateKeysAndMetadataOnlyBackups() {
        var archive = WorkspaceArchive(workspace: workspace())
        XCTAssertEqual(BackupPresentation.credentialCounts(archive).passwords, 0)
        XCTAssertEqual(BackupPresentation.credentialCounts(archive).privateKeys, 0)
        archive.secrets = [:]
        XCTAssertEqual(BackupPresentation.credentialCounts(archive).passwords, 0)
        XCTAssertEqual(BackupPresentation.credentialCounts(archive).privateKeys, 0)
        archive.secrets = [
            UUID().uuidString: ArchiveSecret(secret: "password-fixture", privateKey: ""),
            UUID().uuidString: ArchiveSecret(secret: "", privateKey: "key-fixture"),
            UUID().uuidString: ArchiveSecret(secret: "passphrase-fixture", privateKey: "protected-key-fixture"),
            UUID().uuidString: ArchiveSecret(secret: "", privateKey: ""),
        ]
        let counts = BackupPresentation.credentialCounts(archive)
        XCTAssertEqual(counts.passwords, 2)
        XCTAssertEqual(counts.privateKeys, 2)
    }

    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) }
    }
    private func secureField(in root: NSView) throws -> NSSecureTextField {
        try XCTUnwrap(find(NSSecureTextField.self, in: root).first { $0.identifier?.rawValue == "axon-restore-password" })
    }
    private func actionButton(_ identifier: String, in root: NSView) throws -> PreferencesRectNativeButton {
        try XCTUnwrap(find(PreferencesRectNativeButton.self, in: root).first { $0.identifier?.rawValue == identifier })
    }
    private func renderAndAudit(_ root: NSView, window: NSWindow, directory: URL, name: String) throws {
        // A full-size-content panel can include the transparent native titlebar
        // in its hosting bounds. Audit and render the actual 440 × 300 SwiftUI
        // card centered inside those bounds rather than a desktop thumbnail.
        let card = NSRect(x: root.bounds.midX - 220, y: root.bounds.midY - 150, width: 440, height: 300)
        XCTAssertTrue(root.bounds.insetBy(dx: -1, dy: -1).contains(card), "\(name): hosting bounds must contain the complete compact card")
        let field = try secureField(in: root)
        let cancel = try actionButton("axon-restore-password-cancel", in: root)
        let submit = try actionButton("axon-restore-password-submit", in: root)
        let controls: [(String, NSView)] = [("password", field), ("cancel", cancel), ("submit", submit)]
        let frames = controls.map { ($0.0, $0.1.convert($0.1.bounds, to: root)) }
        for (identifier, frame) in frames {
            XCTAssertGreaterThan(frame.width, 40, "\(name): \(identifier) must have a real laid-out width")
            XCTAssertGreaterThan(frame.height, 12, "\(name): \(identifier) must have a real laid-out height")
            XCTAssertTrue(card.insetBy(dx: -1, dy: -1).contains(frame), "\(name): \(identifier) \(frame) exceeds the 440 × 300 card \(card)")
        }
        XCTAssertFalse(frames[0].1.intersects(frames[1].1), "\(name): password field overlaps Cancel")
        XCTAssertFalse(frames[0].1.intersects(frames[2].1), "\(name): password field overlaps Submit")
        XCTAssertFalse(frames[1].1.intersects(frames[2].1), "\(name): action buttons overlap")
        let screenCard = window.convertToScreen(root.convert(card, to: nil))
        let roles: Set<String> = [NSAccessibility.Role.staticText.rawValue, NSAccessibility.Role.button.rawValue,
                                  NSAccessibility.Role.textField.rawValue]
        var audit = ["window=\(window.frame)", "hosting=\(root.bounds)", "card=\(card)"]
        audit += frames.map { "native:\($0.0)\t\($0.1)" }
        var auditedLeaves = 0
        for object in accessibilityObjects(root) {
            guard let role = read(object, "accessibilityRole") as? String, roles.contains(role),
                  let value = read(object, "accessibilityFrame") as? NSValue else { continue }
            let frame = value.rectValue
            guard frame.width > 0, frame.height > 0 else { continue }
            let identifier = read(object, "accessibilityIdentifier") as? String ?? ""
            let text = [read(object, "accessibilityLabel") as? String, read(object, "accessibilityValue") as? String]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
            audit.append("\(role)\t\(identifier)\t\(frame)\t\(text)")
            XCTAssertTrue(screenCard.insetBy(dx: -1, dy: -1).contains(frame), "\(name): \(identifier.isEmpty ? text : identifier) exceeds compact panel bounds")
            auditedLeaves += 1
        }
        XCTAssertGreaterThanOrEqual(auditedLeaves, 6, "The audit must include the actual labels and controls")
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: card))
        root.cacheDisplay(in: card, to: bitmap)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 440)
        XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 300)
        if let data = bitmap.bitmapData {
            let bytes = UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            XCTAssertGreaterThan(Set(bytes).count, 8, "\(name): a flat white thumbnail is not visual evidence of the rendered dialog")
        } else { XCTFail("\(name): the rendered native bitmap has no pixel storage") }
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
        try audit.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-layout.txt"), atomically: true, encoding: .utf8)
    }
    private func pressClose(in root: NSView) throws {
        let button = try XCTUnwrap(accessibilityObjects(root).first {
            read($0, "accessibilityIdentifier") as? String == "axon-restore-password-close"
                && read($0, "accessibilityRole") as? String == NSAccessibility.Role.button.rawValue
        }, "The panel must expose its own close action")
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(button.responds(to: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
    }
    private func beginEditing(_ field: NSSecureTextField, in window: NSWindow) throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field))
        field.selectText(nil)
        return try XCTUnwrap(field.currentEditor() as? NSTextView, "The native password input must use its real field editor")
    }
    private func assertSubmitEnabled(_ enabled: Bool, button: PreferencesRectNativeButton, submitted: [String]) throws {
        XCTAssertEqual(button.isEnabled, enabled)
        XCTAssertEqual(button.isAccessibilityEnabled(), enabled)
        if !enabled {
            XCTAssertFalse(button.accessibilityPerformPress())
            button.performClick(nil)
        }
    }
    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }
    private func read(_ element: NSObject, _ key: String) -> Any? {
        element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil
    }
    private func accessibilityObjects(_ root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ value: Any) {
            guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            for child in read(object, "accessibilityChildren") as? [Any] ?? [] { visit(child) }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(root)
        return result
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key)
        NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
}
