import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class TerminalToolsResizeTests: XCTestCase {
    func testActualDragReopenPersistenceAndWindowBounds() async throws {
        _ = NSApplication.shared
        let key = "axon.terminalToolsWidth", previous = UserDefaults.standard.object(forKey: "axon.terminalToolsWidth")
        UserDefaults.standard.removeObject(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        store.workspace.preferences.localShell = "/bin/sh"; store.workspace.preferences.localLoginShell = false; store.connect()
        defer { store.monitoring.stop(); store.sessions.forEach { $0.disconnect() }; try? FileManager.default.removeItem(at: root) }
        store.ai.answer = "已查看磁盘空间：系统盘 40 GB，已用 16 GB，剩余 22 GB。\n当前磁盘空间充足。"; store.ai.question = "看一下硬盘还有多少空间"
        let output = URL(fileURLWithPath: "/tmp/axon-0159-ui"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for width in [1400, 1050] {
            let host = NSHostingView(rootView: MainView().environmentObject(store)); host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 850), styleMask: [.titled, .resizable], backing: .buffered, defer: false); window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(250)); store.aiTerminalRequest = UUID(); try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
            let handle = try XCTUnwrap(find(TerminalToolsResizeView.self, host).first)
            XCTAssertEqual(handle.panelWidth, width == 1400 ? 320 : 690, accuracy: 1)
            let terminal = try XCTUnwrap(store.sessions.first?.terminal), frame = window.frame
            if width == 1400 {
                func event(_ type: NSEvent.EventType, _ x: CGFloat) -> NSEvent { NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 300), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)! }
                handle.mouseDown(with: event(.leftMouseDown, 1080)); handle.mouseDragged(with: event(.leftMouseDragged, 400)); handle.mouseUp(with: event(.leftMouseUp, 400))
                try await Task.sleep(for: .milliseconds(200)); XCTAssertEqual(handle.panelWidth, 931, accuracy: 1); XCTAssertEqual(UserDefaults.standard.double(forKey: key), 931)
            }
            store.ai.answer = "已查看磁盘空间：系统盘 40 GB，已用 16 GB，剩余 22 GB。\n\n当前磁盘空间充足。\n\n检查命令：\n```sh\ndf -h\n```"
            store.ai.answerSessionID = store.sessions.first?.id
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(store.sessions.first?.terminal === terminal); XCTAssertEqual(window.frame, frame)
            host.layoutSubtreeIfNeeded(); let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: rep); try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("resize-\(width).png"))
            window.close()
        }
        XCTAssertEqual(TerminalToolsPanel.allocatedWidth(selection: "ai", workspace: 1050, preferred: 800), 690)
        XCTAssertEqual(TerminalToolsPanel.allocatedWidth(selection: "ai", workspace: 1400, preferred: 900), 900)
        XCTAssertEqual(TerminalToolsPanel.allocatedWidth(selection: "ai", workspace: 1400, preferred: -1), 320)
        XCTAssertEqual(UserDefaults.standard.double(forKey: key), 931)
    }
    private func find<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] { (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { find(type, $0) } }
}
