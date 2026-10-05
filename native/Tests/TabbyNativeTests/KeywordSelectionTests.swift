import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

@MainActor final class KeywordSelectionTests: XCTestCase {
    func testStandardScopeGroupAndHostFieldsRenderAndSelect() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.preferences.keywordRules = [KeywordRule.presets[0]]
        store.workspace.groups = ["生产", "测试"]
        var host = TabbyNative.Host(); host.name = "生产服务器"; host.address = "fixture.invalid"
        store.workspace.hosts = [host]
        let draft = Binding(get: { store.workspace.preferences }, set: { store.workspace.preferences = $0 })
        let scope = Binding(get: { store.workspace.preferences.keywordRules[0].scope }, set: { store.workspace.preferences.keywordRules[0].scope = $0 })
        let picker = AxonChoiceField(selection: scope, choices: [("global", "全局"), ("group", "分组"), ("host", "主机")], placeholder: "作用范围", symbol: "scope", identifier: "test-scope")
        for width: CGFloat in [840, 600] {
            let hosting = NSHostingView(rootView: KeywordRulesPane(draft: draft).environmentObject(store).padding(24).background(Palette.background).preferredColorScheme(.light))
            hosting.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); defer { window.close() }
            for (index, expected) in ["全局", "分组", "主机"].enumerated() {
                let menu = picker.makeMenu(width: 124)
                let item = menu.items[index]
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
                let fields = find(SelectionFieldButton.self, in: hosting)
                XCTAssertEqual(fields.count, index == 0 ? 1 : 2)
                XCTAssertTrue(fields.contains { $0.title == expected })
                XCTAssertTrue(find(NSPopUpButton.self, in: hosting).isEmpty)
                for field in fields {
                    let frame = field.convert(field.bounds, to: hosting)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0); XCTAssertLessThanOrEqual(frame.maxX, width)
                    XCTAssertEqual(field.bounds.height, 38, accuracy: 1)
                    let content = try XCTUnwrap(window.contentView)
                    for point in [NSPoint(x: 2, y: 2), NSPoint(x: field.bounds.width - 2, y: 36)] {
                        XCTAssertTrue(content.hitTest(field.convert(point, to: content.superview)) === field)
                    }
                }
                try capture(hosting, path: "/private/tmp/axon-keyword-choice-\(Int(width))-\(index).png")
            }
        }
        let group = Binding(get: { store.workspace.preferences.keywordRules[0].group }, set: { store.workspace.preferences.keywordRules[0].group = $0 })
        let groupPicker = AxonChoiceField(selection: group, choices: [("", "选择分组"), ("生产", "生产")], placeholder: "分组", symbol: "folder", identifier: "test-group")
        let groupItem = groupPicker.makeMenu(width: 170).items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(groupItem.action), to: groupItem.target, from: groupItem))
        XCTAssertEqual(group.wrappedValue, "生产")
        let hostBinding = Binding(get: { store.workspace.preferences.keywordRules[0].hostID }, set: { store.workspace.preferences.keywordRules[0].hostID = $0 })
        let hostPicker = AxonChoiceField(selection: hostBinding, choices: [(nil as UUID?, "选择主机"), (Optional(host.id), host.name)], placeholder: "主机", symbol: "server.rack", identifier: "test-host")
        let hostItem = hostPicker.makeMenu(width: 190).items[1]
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(hostItem.action), to: hostItem.target, from: hostItem))
        XCTAssertEqual(hostBinding.wrappedValue, host.id)
    }
    private func find<T: NSView>(_ type: T.Type, in root: NSView) -> [T] { ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { find(type, in: $0) } }
    private func capture(_ view: NSView, path: String) throws {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
