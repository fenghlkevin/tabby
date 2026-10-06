import AppKit
import SwiftTerm
import XCTest
@testable import TabbyNative

final class TerminalTitleTests: XCTestCase {
    @MainActor func testRemoteOSCUpdatesPreserveConfiguredNameAndCredentialUsername() async throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var identity = VaultCredential(); identity.username = "deploy"
        store.workspace.credentials = [identity]
        var host = TabbyNative.Host(); host.name = "生产 API"; host.address = "192.0.2.10"; host.username = "old-user"; host.credentialID = identity.id
        store.workspace.hosts = [host]
        let session = TerminalSession(host: host, store: store)
        let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = session
        XCTAssertEqual(session.title, "deploy@生产 API")
        // Feed real OSC title sequences through the terminal parser.
        for title in ["root@internal-host:~", "vim /opt/config", ""] {
            view.feed(text: "\u{1B}]0;\(title)\u{7}")
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(session.title, "deploy@生产 API")
        }
        // Editing an identity does not relabel an already-open connection.
        store.workspace.credentials[0].username = "next-user"
        view.feed(text: "\u{1B}]2;root@internal-host:/opt\u{7}")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.title, "deploy@生产 API")
        XCTAssertEqual(TerminalSession(host: host, store: store).title, "next-user@生产 API")
        XCTAssertEqual(store.workspace.hosts, [host])
    }

    @MainActor func testUnnamedRemoteFallsBackToAddressAndLocalOSCStillChangesTitle() async throws {
        _ = NSApplication.shared
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var host = TabbyNative.Host(); host.name = " \n "; host.address = "192.0.2.11"; host.username = "root"
        XCTAssertEqual(TerminalSession(host: host, store: store).title, "root@192.0.2.11")
        host.username = ""
        XCTAssertEqual(TerminalSession(host: host, store: store).title, "192.0.2.11")
        let local = TerminalSession(host: nil, store: store)
        let view = LocalTerminal(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions())
        view.terminalDelegate = local
        view.feed(text: "\u{1B}]0;Local editor\u{7}")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(local.title, "Local editor")
        view.feed(text: "\u{1B}]0;\u{7}")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(local.title, "Local editor")
    }
}
