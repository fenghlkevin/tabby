import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative
@MainActor final class SFTPConnectingUITests: XCTestCase {
    func testConnectingPanelRender() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            try await Task.sleep(for: .seconds(2))
            throw AppFailure.message("Fixture connection failure")
        })
        var host = TabbyNative.Host(); host.name = "生产服务器"; host.address = "fixture.invalid"; host.username = "root"
        let connecting = Task { await model.selectHost(host) }
        await Task.yield()
        XCTAssertTrue(model.opening)
        let view = NSHostingView(rootView: SFTPHostPicker(model: model).environmentObject(store).preferredColorScheme(.light))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil); defer { connecting.cancel(); window.close(); model.close() }
        try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-sftp-connecting.png"))
    }
}
