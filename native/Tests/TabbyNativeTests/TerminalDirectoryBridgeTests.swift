import XCTest
import SwiftTerm
import Combine
@testable import TabbyNative

final class TerminalDirectoryBridgeTests: XCTestCase {
    @MainActor func testSwiftTermOSC7CallbackCarriesURIAndDecodesIntoDirectory() async throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var host = TabbyNative.Host(); host.address = "server.example"; host.username = "user"
        let session = TerminalSession(host: host, store: store)
        let terminal = TerminalView(frame: .zero)
        terminal.terminalDelegate = session; session.terminal = terminal; session.connected = true
        let reported = expectation(description: "SwiftTerm OSC 7 directory callback")
        let observer = session.$currentDirectory.compactMap { $0 }.sink { path in
            XCTAssertEqual(path, "/var/log/app log"); reported.fulfill()
        }
        terminal.feed(text: "\u{1b}]7;file://server.example/var/log/app%20log\u{7}")
        await fulfillment(of: [reported], timeout: 2)
        withExtendedLifetime(observer) {}
    }

    func testOSC7DecodesPathsOnlyForTrustedAuthority() {
        let trusted: Set<String> = ["server.example", "2001:db8::1"]
        XCTAssertEqual(TerminalDirectoryBridge.currentDirectory("file://SERVER.example/var/log/%E4%B8%AD%E6%96%87%20app%23%3F", trustedHosts: trusted), "/var/log/中文 app#?")
        XCTAssertEqual(TerminalDirectoryBridge.currentDirectory("file://[2001:db8::1]/tmp", trustedHosts: trusted), "/tmp")
        for report in ["file://other.example/tmp", "file:///tmp", "https://server.example/tmp", "file://user@server.example/tmp", "file://server.example:22/tmp", "file://server.example/tmp?x=1", "file://server.example/tmp#frag", "file://server.example/tmp/%1B"] {
            XCTAssertNil(TerminalDirectoryBridge.currentDirectory(report, trustedHosts: trusted), report)
        }
    }

    func testSelectedPathsNeedTrustedDirectoryForRelativePaths() throws {
        XCTAssertEqual(try TerminalDirectoryBridge.selectedPath(" /var/log/app log ", directory: nil, trustedHosts: []), "/var/log/app log")
        XCTAssertEqual(try TerminalDirectoryBridge.selectedPath("../app.log", directory: "/var/log/nginx", trustedHosts: []), "/var/log/app.log")
        XCTAssertThrowsError(try TerminalDirectoryBridge.selectedPath("app.log", directory: nil, trustedHosts: []))
        XCTAssertThrowsError(try TerminalDirectoryBridge.selectedPath("file://wrong/tmp/log", directory: "/tmp", trustedHosts: ["right"]))
        XCTAssertThrowsError(try TerminalDirectoryBridge.selectedPath("/tmp/a\nb", directory: nil, trustedHosts: []))
    }

    @MainActor func testSessionUpdatesInvalidateUnknownHostAndClearOnDisconnect() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var host = TabbyNative.Host(); host.address = "outer.example"; host.username = "user"
        let session = TerminalSession(host: host, store: store)
        let terminal = TerminalView(frame: .zero); session.terminal = terminal; session.connected = true
        store.sessions = [session]; store.activeSession = session.id; store.section = "terminal"
        session.hostCurrentDirectoryUpdate(source: terminal, directory: "file://outer.example/var/log")
        XCTAssertEqual(session.currentDirectory, "/var/log")
        XCTAssertFalse(session.followDirectoryInFiles)
        XCTAssertNil(store.terminalFileRequest)
        session.followDirectoryInFiles = true
        session.hostCurrentDirectoryUpdate(source: terminal, directory: "file://outer.example/etc")
        XCTAssertEqual(store.terminalFileRequest?.path, "/etc")
        XCTAssertEqual(store.terminalFileRequest?.generation, session.generation)
        XCTAssertEqual(store.section, "terminal", "Automatic following must not switch views")
        let previousRequest = store.terminalFileRequest?.id
        session.hostCurrentDirectoryUpdate(source: terminal, directory: "file://nested.example/tmp")
        XCTAssertNil(session.currentDirectory)
        XCTAssertEqual(store.terminalFileRequest?.id, previousRequest)
        XCTAssertThrowsError(try store.openTerminalDirectoryInFiles(sessionID: session.id))
        session.hostCurrentDirectoryUpdate(source: terminal, directory: "file://outer.example/tmp")
        session.disconnect()
        XCTAssertNil(session.currentDirectory)
    }

    @MainActor func testChangedJumpRouteCannotOpenFilesOrReuseTerminal() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var jump = TabbyNative.Host(); jump.address = "jump.example"; jump.username = "user"
        var host = TabbyNative.Host(); host.address = "target.example"; host.username = "user"; host.jumpHostID = jump.id
        store.workspace.hosts = [host, jump]
        let session = TerminalSession(host: host, store: store); session.connected = true; session.terminal = TerminalView(frame: .zero)
        store.sessions = [session]
        XCTAssertFalse(session.matchesEndpoint(host), "No authenticated jump route exists for this session")
        XCTAssertThrowsError(try store.openTerminalDirectoryInFiles(sessionID: session.id, path: "/tmp"))
        XCTAssertNil(store.terminalFileRequest)
    }

    @MainActor func testReverseNavigationInsertsQuotedCommandWithoutReturn() throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let session = TerminalSession(host: nil, store: store)
        let terminal = TerminalView(frame: .zero), capture = DirectoryInputCapture()
        terminal.terminalDelegate = capture; session.terminal = terminal; session.connected = true; store.sessions = [session]
        let path = "/tmp/space ' quote $(whoami)"
        try store.insertChangeDirectory(path: path, host: nil)
        XCTAssertEqual(capture.received, [Array("cd -- '/tmp/space '\\'' quote $(whoami)'".utf8)])
        XCTAssertFalse(capture.received.joined().contains(13))
        XCTAssertEqual(store.activeSession, session.id)
        XCTAssertEqual(store.section, "terminal")
        XCTAssertThrowsError(try TerminalDirectoryBridge.safeChangeDirectoryCommand(path: "/tmp/\u{1b}bad"))
        XCTAssertThrowsError(try TerminalDirectoryBridge.safeChangeDirectoryCommand(path: "relative"))
    }
}

@MainActor private final class DirectoryInputCapture: TerminalViewDelegate {
    var received: [[UInt8]] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { received.append(Array(data)) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}
