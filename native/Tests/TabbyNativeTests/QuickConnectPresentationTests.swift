import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class QuickConnectPresentationTests: XCTestCase {
    func testQuickConnectionUsesAxonFieldForFreshErrorAndSharedIdentityStates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-quick-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var identity = VaultCredential(); identity.name = "生产部署身份-production-deployment-with-long-name"; identity.username = "deploy"
        store.workspace.credentials = [identity]
        for language in ["zh-CN", "en-US"] {
            store.workspace.preferences.language = language
            var invalid = TabbyNative.Host(); invalid.address = "https://example.invalid"; invalid.username = "root"
            var shared = TabbyNative.Host(); shared.address = "production-api.example.invalid"; shared.username = "deploy"; shared.credentialID = identity.id
            for (name, host): (String, TabbyNative.Host?) in [("fresh", nil), ("error", invalid), ("shared", shared)] {
                let view = QuickConnectView(initial: host).environmentObject(store).preferredColorScheme(.light).tint(Palette.accent)
                let hosting = NSHostingView(rootView: view); hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(220)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
                let field = try XCTUnwrap(find(SelectionFieldButton.self, in: hosting).first { $0.accessibilityIdentifier() == "axon-quick-identity" })
                XCTAssertEqual(field.bounds.height, 38, accuracy: 0.5)
                XCTAssertTrue(find(NSPopUpButton.self, in: hosting).isEmpty, "Quick connect must use Axon's selection field")
                XCTAssertTrue(field.hitTest(NSPoint(x: 2, y: 2)) === field)
                XCTAssertTrue(field.hitTest(NSPoint(x: field.bounds.width - 2, y: field.bounds.height - 2)) === field)
                XCTAssertEqual(field.title, name == "shared" ? identity.name : store.text("Enter password on connect", "连接时输入密码"))
                let rect = field.convert(field.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(rect.minX, 24); XCTAssertLessThanOrEqual(rect.maxX, 416)
                let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/ui-0.10.2")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("quick-\(name)-\(language).png"))
            }
        }
        XCTAssertTrue(store.sessions.isEmpty); XCTAssertTrue(store.workspace.hosts.isEmpty)
    }
    func testIdentityMenuRetainsSelectionAndCanReturnToPassword() throws {
        _ = NSApplication.shared
        var selected: UUID?; let id = UUID()
        let field = AxonChoiceField(selection: Binding(get: { selected }, set: { selected = $0 }), choices: [(nil, "连接时输入密码"), (id, "部署身份")], placeholder: "选择凭据", symbol: "key", identifier: "axon-quick-identity")
        let menu = field.makeMenu(width: 392)
        XCTAssertEqual(menu.minimumWidth, 392); XCTAssertEqual(menu.items[0].state, .on)
        for index in [1, 0] {
            let item = menu.items[index]
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(selected, index == 1 ? id : nil)
        }
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
}
