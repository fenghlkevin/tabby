import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class ForwardRulePresentationTests: XCTestCase {
    func testAxonSelectorsAcrossForwardTypesAndLanguages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-forward-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "生产环境网关-production-gateway-with-a-long-host-name"; host.address = "gateway.example.invalid"
        store.workspace.hosts = [host]
        for language in ["zh-CN", "en-US"] {
            store.workspace.preferences.language = language
            for state in ["fresh", "local", "remote", "dynamic", "error"] {
                var rule = PortForwardRule()
                if state != "fresh" { rule.name = "数据库连接"; rule.hostID = host.id; rule.kind = state == "error" ? "dynamic" : state }
                if rule.isDynamic { rule.bindPort = 1080 }
                if state == "error" { rule.bindHost = "0.0.0.0" }
                let hosting = NSHostingView(rootView: ForwardRuleEditor(rule: rule).environmentObject(store).preferredColorScheme(.light).tint(Palette.accent)); hosting.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
                defer { window.close() }
                try await Task.sleep(for: .milliseconds(220)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
                for identifier in ["axon-forward-host", "axon-forward-type"] {
                    let field = try XCTUnwrap(find(SelectionFieldButton.self, in: hosting).first { $0.accessibilityIdentifier() == identifier })
                    XCTAssertEqual(field.bounds.height, 38, accuracy: 0.5)
                    XCTAssertTrue(field.hitTest(NSPoint(x: 2, y: 2)) === field)
                    XCTAssertTrue(field.hitTest(NSPoint(x: field.bounds.width - 2, y: field.bounds.height - 2)) === field)
                    let rect = field.convert(field.bounds, to: hosting)
                    XCTAssertGreaterThanOrEqual(rect.minX, 24); XCTAssertLessThanOrEqual(rect.maxX, 516)
                }
                XCTAssertTrue(find(NSPopUpButton.self, in: hosting).isEmpty)
                XCTAssertTrue(find(NSSegmentedControl.self, in: hosting).isEmpty)
                let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/ui-0.10.4")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("forward-\(state)-\(language).png"))
            }
        }
        XCTAssertTrue(store.workspace.forwards.isEmpty)
    }
    func testHostAndTypeMenusApplySelection() throws {
        _ = NSApplication.shared
        var kind = "local"
        let types = AxonChoiceField(selection: Binding(get: { kind }, set: { kind = $0 }), choices: [("local", "本地 → 远程"), ("remote", "远程 → 本地"), ("dynamic", "SOCKS5")], placeholder: "类型", symbol: "arrow.left.arrow.right", identifier: "axon-forward-type")
        let menu = types.makeMenu(width: 492)
        for index in [1, 2, 0] {
            let item = menu.items[index]
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(kind, ["local", "remote", "dynamic"][index])
        }
        var selected: UUID?; let id = UUID()
        let hosts = AxonChoiceField(selection: Binding(get: { selected }, set: { selected = $0 }), choices: [(nil, "选择主机"), (id, "生产网关")], placeholder: "SSH 主机", symbol: "server.rack", identifier: "axon-forward-host")
        let hostMenu = hosts.makeMenu(width: 492)
        for index in [1, 0] {
            let item = hostMenu.items[index]
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            XCTAssertEqual(selected, index == 1 ? id : nil)
        }
    }
    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) } }
}
