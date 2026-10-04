import XCTest
import AppKit
import SwiftUI
import Crypto
@testable import TabbyNative

final class ConnectionAuthenticationTests: XCTestCase {
    private func host() -> TabbyNative.Host {
        var host = TabbyNative.Host(); host.address = "example.invalid"; host.username = "root"
        return host
    }
    private func key(at root: URL, passphrase: String = "") throws -> (path: String, text: String) {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(UUID().uuidString)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-a", "4", "-N", passphrase, "-f", path.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AppFailure.message("Fixture key generation failed") }
        return (path.path, try String(contentsOf: path, encoding: .utf8))
    }
    private func assertNoSecrets(_ workspace: Workspace, values: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let text = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
        for value in values { XCTAssertFalse(text.contains(value), file: file, line: line) }
    }

    func testIdentitySwitchingRestoresUnsavedIndependentCredentialsAndReadFailuresAreAtomic() throws {
        let original = host()
        var workspace = Workspace()
        var credential = VaultCredential(); credential.name = "Production"; credential.username = "deploy"
        workspace.credentials = [credential]
        var draft = ConnectionAuthenticationDraft(host: original, material: .init())
        draft.host.username = "operator"; draft.secret = "unsaved-password"
        try draft.selectCredential(credential.id, workspace: workspace, chinese: false, read: { _ in .init(secret: "shared-password") })
        XCTAssertEqual(draft.host.credentialID, credential.id); XCTAssertEqual(draft.host.username, "deploy")
        XCTAssertEqual(draft.secret, "shared-password")
        try draft.selectCredential(nil, workspace: workspace, chinese: false)
        XCTAssertEqual(draft.host.username, "operator"); XCTAssertEqual(draft.secret, "unsaved-password")
        XCTAssertThrowsError(try draft.selectCredential(credential.id, workspace: workspace, chinese: false, read: { _ in throw AppFailure.message("fixture-read-error") }))
        XCTAssertNil(draft.host.credentialID); XCTAssertEqual(draft.host.username, "operator"); XCTAssertEqual(draft.secret, "unsaved-password")
        XCTAssertThrowsError(try draft.selectCredential(UUID(), workspace: workspace, chinese: false))
        XCTAssertNil(draft.host.credentialID)
        try assertNoSecrets(workspace, values: ["unsaved-password", "shared-password"])
    }

    func testValidationSupportsPasswordTextAndFileKeyWithoutChangingEndpointOrJumpRoute() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = try key(at: root, passphrase: "fixture-passphrase")
        var jump = host(); jump.address = "jump.invalid"
        var original = host(); original.jumpHostID = jump.id
        var workspace = Workspace(); workspace.hosts = [original, jump]
        var draft = ConnectionAuthenticationDraft(host: original, material: .init())
        XCTAssertFalse(draft.remember)
        XCTAssertThrowsError(try draft.validatedResult(workspace: workspace, chinese: false))
        draft.secret = "fixture-password"
        XCTAssertNoThrow(try draft.validatedResult(workspace: workspace, chinese: false))
        draft.host.address = "must-not-connect.invalid"; draft.host.port = 2222; draft.host.jumpHostID = nil
        draft.host.auth = "key"; draft.host.keySource = "text"; draft.privateKey = generated.text; draft.secret = "wrong"
        XCTAssertThrowsError(try draft.validatedResult(workspace: workspace, chinese: true)) { error in
            XCTAssertFalse(error.localizedDescription.contains("BEGIN OPENSSH")); XCTAssertFalse(error.localizedDescription.contains("wrong"))
        }
        draft.secret = "fixture-passphrase"
        let text = try draft.validatedResult(workspace: workspace, chinese: false)
        XCTAssertEqual(text.host.address, original.address); XCTAssertEqual(text.host.port, original.port)
        XCTAssertEqual(text.host.jumpHostID, jump.id); XCTAssertEqual(text.host.auth, "key")
        XCTAssertFalse(text.remember); XCTAssertFalse(text.privateKey.isEmpty)
        draft.host.keySource = "file"; draft.host.keyPath = generated.path
        let file = try draft.validatedResult(workspace: workspace, chinese: false)
        XCTAssertEqual(file.host.keyPath, generated.path); XCTAssertTrue(file.keychainValue.privateKey.isEmpty)
        try assertNoSecrets(workspace, values: ["fixture-password", "fixture-passphrase", "BEGIN OPENSSH"])
    }

    @MainActor func testRememberedPastedKeyUpdatesAuthenticationMetadataAndNeverWritesKeyToJSON() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let generated = try key(at: root, passphrase: "fixture-passphrase")
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var original = host(); original.name = "Server"; original.group = "Production"; original.favorite = true
        defer { try? Secrets.saveCredential(.init(), id: original.id) }
        try store.upsert(original, secret: "")
        var draft = ConnectionAuthenticationDraft(host: original, material: .init())
        draft.host.auth = "key"; draft.host.keySource = "text"; draft.privateKey = generated.text
        draft.secret = "fixture-passphrase"; draft.remember = true
        let result = try draft.validatedResult(workspace: store.workspace, chinese: false)
        try store.rememberConnectionAuthentication(result)
        let saved = try XCTUnwrap(store.workspace.hosts.first)
        XCTAssertEqual(saved.auth, "key"); XCTAssertEqual(saved.keySource, "text"); XCTAssertEqual(saved.name, "Server")
        XCTAssertEqual(saved.group, "Production"); XCTAssertTrue(saved.favorite)
        XCTAssertEqual(try Secrets.readChecked(saved.id), "fixture-passphrase")
        XCTAssertTrue(SHA256.hash(data: Data(try Secrets.readPrivateKey(saved.id).utf8)) == SHA256.hash(data: Data(result.privateKey.utf8)))
        let reloaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(reloaded.workspace.hosts.first, saved)
        try assertNoSecrets(reloaded.workspace, values: ["fixture-passphrase", "BEGIN OPENSSH"])
        for url in [store.fileURL, store.fileURL.appendingPathExtension("backup")] {
            let json = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(json.contains("fixture-passphrase")); XCTAssertFalse(json.contains("BEGIN OPENSSH"))
        }
        // Remembering changed auth must be picked up by an existing session snapshot.
        let session = TerminalSession(host: original, store: reloaded)
        XCTAssertNoThrow(try session.settings(for: original, authenticationPrompt: { _ in
            XCTFail("Saved valid text keys should not prompt")
            throw CancellationError()
        }))
    }

    @MainActor func testSharedSecretAndHostAssociationRollbackTogetherWhenWorkspaceSaveFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked"); try Data().write(to: blocked)
        let store = AppStore(fileURL: blocked.appendingPathComponent("workspace.json"))
        let original = host()
        var credential = VaultCredential(); credential.name = "Shared"; credential.username = "deploy"
        store.workspace.hosts = [original]; store.workspace.credentials = [credential]
        defer { try? Secrets.saveCredential(.init(), id: original.id); try? Secrets.saveCredential(.init(), id: credential.id) }
        try Secrets.save("previous-shared-secret", id: credential.id)
        var draft = ConnectionAuthenticationDraft(host: original, material: .init())
        try draft.selectCredential(credential.id, workspace: store.workspace, chinese: false)
        draft.secret = "new-shared-secret"; draft.remember = true
        let result = try draft.validatedResult(workspace: store.workspace, chinese: false)
        XCTAssertThrowsError(try store.rememberConnectionAuthentication(result))
        XCTAssertEqual(store.workspace.hosts, [original]); XCTAssertEqual(store.workspace.credentials, [credential])
        XCTAssertEqual(try Secrets.readChecked(credential.id), "previous-shared-secret")
        XCTAssertTrue(try Secrets.readChecked(original.id).isEmpty)
    }

    @MainActor func testTemporaryAuthenticationIsReusedOnRetryAndNeverPersisted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = host()
        let generated = try key(at: root)
        defer { try? Secrets.saveCredential(.init(), id: original.id) }
        try store.upsert(original, secret: "")
        let before = try Data(contentsOf: store.fileURL)
        let session = TerminalSession(host: original, store: store)
        var prompts = 0
        _ = try session.settings(for: original, authenticationPrompt: { initial in
            prompts += 1
            var draft = initial; draft.host.username = "deploy"; draft.host.auth = "key"; draft.host.keySource = "text"
            draft.privateKey = generated.text
            return try draft.validatedResult(workspace: store.workspace, chinese: false)
        })
        XCTAssertEqual(session.settingsUsername(for: original), "deploy")
        session.disconnect()
        _ = try session.settings(for: original, authenticationPrompt: { _ in
            XCTFail("The temporary session identity should survive reconnect")
            throw CancellationError()
        })
        XCTAssertEqual(prompts, 1); XCTAssertEqual(store.workspace.hosts, [original])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertTrue(try Secrets.readChecked(original.id).isEmpty); XCTAssertTrue(try Secrets.readPrivateKey(original.id).isEmpty)
        // A genuine saved-credential edit invalidates the temporary identity.
        try store.upsert(original, secret: "new-saved-password")
        _ = try session.settings(for: original, authenticationPrompt: { _ in
            XCTFail("A saved valid password should not prompt")
            throw CancellationError()
        })
        XCTAssertEqual(session.settingsUsername(for: original), "root")
    }

    @MainActor func testCancelNeverMutatesCredentialsAndNextAttemptCanPromptAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = host()
        defer { try? Secrets.saveCredential(.init(), id: original.id) }
        let session = TerminalSession(host: original, store: store)
        for _ in 0..<2 {
            XCTAssertThrowsError(try session.settings(for: original, authenticationPrompt: { _ in throw CancellationError() })) { error in
                XCTAssertTrue(error is CancellationError)
            }
        }
        XCTAssertTrue(store.workspace.hosts.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(try Secrets.readChecked(original.id).isEmpty)
    }

    @MainActor func testTemporarySharedChoiceUsesLatestMetadataAndSecretsWithoutPromptingAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = host()
        var credential = VaultCredential(); credential.name = "Shared"; credential.username = "deploy"
        defer { try? Secrets.saveCredential(.init(), id: original.id); try? Secrets.saveCredential(.init(), id: credential.id) }
        try store.upsert(original, secret: "")
        try store.saveCredential(credential, secret: "shared-password")
        let session = TerminalSession(host: original, store: store)
        _ = try session.settings(for: original, authenticationPrompt: { initial in
            var draft = initial
            try draft.selectCredential(credential.id, workspace: store.workspace, chinese: false)
            return try draft.validatedResult(workspace: store.workspace, chinese: false)
        })
        XCTAssertEqual(session.settingsUsername(for: original), "deploy")
        credential.username = "operator"
        try store.saveCredential(credential, secret: "updated-shared-password")
        _ = try session.settings(for: original, authenticationPrompt: { _ in
            XCTFail("The chosen shared identity should refresh automatically when its saved values remain valid")
            throw CancellationError()
        })
        XCTAssertEqual(session.settingsUsername(for: original), "operator")
        XCTAssertNil(store.workspace.hosts.first?.credentialID)
        XCTAssertEqual(store.workspace.hosts.first?.username, "root")
        try store.saveCredential(credential, secret: "")
        var prompted = false
        XCTAssertThrowsError(try session.settings(for: original, authenticationPrompt: { draft in
            prompted = true
            XCTAssertEqual(draft.host.credentialID, credential.id)
            XCTAssertEqual(draft.host.username, "operator")
            XCTAssertTrue(draft.secret.isEmpty)
            throw CancellationError()
        })) { error in XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(prompted)
    }

    @MainActor func testSubmissionKeepsValidationInlineAndOnlyConnectsAfterValidInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = host()
        let model = ConnectionAuthenticationModel(draft: .init(host: original, material: .init()), store: store)
        var connected = false
        model.onConnect = { _ in connected = true }
        model.submit()
        XCTAssertFalse(connected); XCTAssertFalse(model.error.isEmpty)
        model.draft.secret = "temporary-password"
        model.submit()
        XCTAssertTrue(connected); XCTAssertTrue(model.error.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertTrue(try Secrets.readChecked(original.id).isEmpty)
    }

    @MainActor func testConnectionPickerHasNoUnavailableCreationAction() throws {
        _ = NSApplication.shared
        let button = CredentialPickerButton()
        var shared = VaultCredential(); shared.name = "Shared"
        button.configure(selectedID: nil, credentials: [shared], chinese: false, enabled: true, allowsCreation: false)
        let menu = button.makeMenu()
        XCTAssertEqual(menu.items.count, 2)
        XCTAssertFalse(menu.items.contains { $0.isSeparatorItem || $0.title.contains("New shared") })
    }

    @MainActor func testScopedModalCancelsFromWindowCloseAndCancelActionWithoutLeavingModalState() throws {
        _ = NSApplication.shared
        XCTAssertNil(NSApp.modalWindow)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let original = host()
        for closeWindow in [true, false] {
            let controller = ConnectionAuthenticationWindowController(draft: .init(host: original, material: .init()), store: store)
            var fired = false
            let cancel = Timer(timeInterval: 0.03, repeats: true) { timer in
                guard let window = controller.window, NSApp.modalWindow === window else { return }
                fired = true
                timer.invalidate()
                if closeWindow { window.performClose(nil) }
                else { controller.model.onCancel?() }
            }
            // Keep the test bounded if a window close action ever stops reaching
            // its delegate. This watchdog cancels the same scoped modal window.
            let watchdog = Timer(timeInterval: 3, repeats: false) { _ in
                XCTFail("Authentication modal did not finish after cancellation")
                controller.cancel()
            }
            RunLoop.main.add(cancel, forMode: .modalPanel)
            RunLoop.main.add(watchdog, forMode: .modalPanel)
            defer { cancel.invalidate(); watchdog.invalidate() }
            XCTAssertThrowsError(try controller.present()) { error in XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(fired)
            XCTAssertNil(controller.window); XCTAssertNil(NSApp.modalWindow)
            XCTAssertTrue(store.workspace.hosts.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
            XCTAssertTrue(try Secrets.readChecked(original.id).isEmpty)
        }
    }

    @MainActor func testHostedAuthenticationPresentationAndOptionalCaptures() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        let original = host(); store.workspace.hosts = [original]
        var shared = VaultCredential(); shared.name = "运维共享凭据"; shared.username = "deploy"
        store.workspace.credentials = [shared]
        let model = ConnectionAuthenticationModel(draft: .init(host: original, material: .init()), store: store)
        let hosting = NSHostingView(rootView: ConnectionAuthenticationView(model: model).environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 610), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting; window.orderFront(nil)
        defer { window.close() }
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.layoutSubtreeIfNeeded()
        }
        func capture(_ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"] else { return }
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent(name))
        }
        settle()
        XCTAssertEqual(hosting.bounds.width, 480); XCTAssertEqual(hosting.bounds.height, 610)
        try capture("connection-auth-password.png")
        model.draft.host.auth = "key"; model.draft.host.keySource = "text"
        settle(); try capture("connection-auth-private-key-text.png")
        model.draft.host.keySource = "file"
        settle(); try capture("connection-auth-private-key-file.png")
        model.error = "私钥格式无效或口令不正确。请粘贴完整的 OpenSSH Ed25519 或 RSA 私钥。"
        settle(); try capture("connection-auth-validation.png")
    }
}
