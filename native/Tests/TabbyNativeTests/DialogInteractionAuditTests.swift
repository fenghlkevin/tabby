import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class DialogInteractionAuditTests: XCTestCase {
    private func buttons(_ view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }
    private func click(_ button: NSButton, in window: NSWindow) {
        let point = button.convert(NSPoint(x: 5, y: button.bounds.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true); window.sendEvent(down)
    }
    private func key(_ code: UInt16, chars: String, in window: NSWindow) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
    }
    private func capture(_ window: NSWindow, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"], let view = window.contentView else { return }
        let directory = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    private func operate(_ alert: AppModalAlert, action: @escaping (NSWindow) throws -> Void) -> NSApplication.ModalResponse {
        var operated = false
        let operation = Timer(timeInterval: 0.05, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let window = NSApp.modalWindow else { return }; timer.invalidate()
                do { try action(window); operated = true } catch { XCTFail("Dialog interaction failed: \(error)"); NSApp.stopModal(withCode: .abort) }
            }
        }
        let watchdog = Timer(timeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { XCTFail("Dialog action failed to finish"); NSApp.stopModal(withCode: .abort) } }
        RunLoop.main.add(operation, forMode: .modalPanel); RunLoop.main.add(watchdog, forMode: .modalPanel)
        defer { operation.invalidate(); watchdog.invalidate() }
        let response = alert.runModal(); XCTAssertTrue(operated); XCTAssertNil(NSApp.modalWindow)
        return response
    }
    func testGenericInputReturnCommitsEditedFieldAndEscapeCancels() throws {
        for cancel in [false, true] {
            let alert = AppModalAlert(); alert.messageText = cancel ? "重命名" : "新建文件夹"
            let field = NSTextField(string: "old-name"); field.frame.size = NSSize(width: 320, height: 34); alert.accessoryView = field
            alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
            let response = operate(alert) { window in
                XCTAssertTrue(window.firstResponder is NSTextView)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.selectAll(nil); editor.insertText("folder-中文", replacementRange: editor.selectedRange())
                try self.capture(window, name: "modal-input-edited")
                self.key(cancel ? 53 : 36, chars: cancel ? "\u{1b}" : "\r", in: window)
            }
            XCTAssertEqual(response, cancel ? .alertSecondButtonReturn : .alertFirstButtonReturn)
            XCTAssertEqual(field.stringValue, "folder-中文")
        }
    }
    func testThreeChoiceReplaceDialogMapsEveryButtonAndEscapeToCancelTransfer() throws {
        for choice in [0, 1, 2, 3, 4] {
            let alert = AppModalAlert(); alert.messageText = "Replace report.txt?"; alert.informativeText = "/private/tmp/dialog-audit/report.txt"
            alert.destructive = true; alert.cancelButtonIndex = 2; alert.defaultButtonIndex = 1
            for title in ["Replace", "Skip", "Cancel transfer"] { alert.addButton(withTitle: title) }
            let response = operate(alert) { window in
                let root = try XCTUnwrap(window.contentView)
                if choice >= 3 { self.key(choice == 3 ? 53 : 36, chars: choice == 3 ? "\u{1b}" : "\r", in: window) }
                else {
                    let button = try XCTUnwrap(self.buttons(root).first { $0.identifier?.rawValue == "axon-modal-action-\(choice)" })
                    XCTAssertTrue(button.isEnabled); try self.capture(window, name: "modal-replace-three-actions"); self.click(button, in: window)
                }
            }
            XCTAssertEqual(response.rawValue, NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + (choice == 3 ? 2 : choice == 4 ? 1 : choice))
        }
    }
    func testDestructiveReturnAndEscapeCancelWithoutConfirmation() {
        for code: UInt16 in [36, 53] {
            let alert = AppModalAlert(); alert.destructive = true; alert.messageText = "删除文件？"
            alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
            let response = operate(alert) { self.key(code, chars: code == 36 ? "\r" : "\u{1b}", in: $0) }
            XCTAssertEqual(response, .alertSecondButtonReturn)
        }
    }

    func testEditingSheetsCancelInvalidSubmissionAndSavePrivateFixtures() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        for kind in ["snippet", "forward", "scene", "credential", "quick", "compose", "send", "tags", "diagnostics", "file", "template", "comparison"] {
            for save in [false, true] {
                if save && !["snippet", "forward", "scene", "file", "template"].contains(kind) { continue }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
                var host = TabbyNative.Host(); host.name = "测试主机 · 长名称"; host.address = "example.invalid"; store.workspace.hosts = [host]
                var snippet = CommandSnippet(); if save { snippet.name = "弹框保存测试"; snippet.body = "pwd" }
                var rule = PortForwardRule(); if save { rule.name = "测试转发"; rule.hostID = host.id }
                var template = BatchTemplate(); if save { template.name = "测试模板"; template.command = "pwd" }
                var scene = WorkScene(); if save { scene.name = "测试场景"; scene.terminals = [WorkSceneTerminal()] }
                let model = AlertAuditModel()
                let file = directory.appendingPathComponent("editor-fixture.txt")
                let backend = LocalFiles()
                if kind == "file" { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try Data("original\n".utf8).write(to: file) }
                let editor: AnyView
                switch kind {
                case "snippet": editor = AnyView(SnippetEditor(value: snippet))
                case "forward": editor = AnyView(ForwardRuleEditor(rule: rule))
                case "scene": editor = AnyView(WorkSceneEditor(value: scene))
                case "credential": editor = AnyView(CredentialEditor(value: VaultCredential()))
                case "quick": editor = AnyView(QuickConnectView(initial: nil))
                case "compose": editor = AnyView(TerminalComposeSheet())
                case "tags": editor = AnyView(TagsManagementView())
                case "diagnostics": editor = AnyView(SSHDiagnosticsSheet(host: host))
                case "template": editor = AnyView(BatchTemplateEditor(value: template) { value in store.workspace.batchTemplates.append(value); store.save(); model.presented = false })
                case "comparison":
                    let source = directory.appendingPathComponent("source"), target = directory.appendingPathComponent("target")
                    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    editor = AnyView(DirectoryComparisonSheet(model: DirectoryComparisonModel(source: FilePane(path: source.path, backend: backend), target: FilePane(path: target.path, backend: backend), queue: TransferQueue(), direction: "copy")))
                case "file": editor = AnyView(FileEditor(entry: try await backend.stat(file.path), backend: backend, refresh: {}))
                default: var sendSnippet = CommandSnippet(); sendSnippet.name = "发送测试"; sendSnippet.body = "pwd"; editor = AnyView(SnippetSendSheet(snippet: sendSnippet))
                }
                let hosting = NSHostingView(rootView: EditorAuditFixture(model: model, editor: AnyView(editor.environmentObject(store))))
                let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: save ? 1400 : 1050, height: 860), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                parent.isReleasedWhenClosed = false; parent.contentView = hosting; parent.makeKeyAndOrderFront(nil)
                defer { model.presented = false; parent.attachedSheet?.orderOut(nil); parent.close() }
                try await Task.sleep(for: .milliseconds(100)); model.presented = true
                for _ in 0..<40 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
                let sheet = try XCTUnwrap(parent.attachedSheet); let root = try XCTUnwrap(sheet.contentView)
                try await Task.sleep(for: .milliseconds(200))
                if kind == "file", save {
                    func textViews(_ view: NSView) -> [NSTextView] { ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap(textViews) }
                    let text = try XCTUnwrap(textViews(root).first { $0.isEditable })
                    sheet.makeFirstResponder(text); text.selectAll(nil); text.insertText("modified-中文\n", replacementRange: text.selectedRange())
                    try await Task.sleep(for: .milliseconds(100))
                }
                try capture(sheet, name: "editor-\(kind)-\(save ? "valid" : "fresh")")
                let title = kind == "scene" ? "保存场景" : kind == "template" ? "保存模板" : kind == "quick" ? "连接" : "保存"
                if ["snippet", "forward", "credential", "quick", "template"].contains(kind), !save {
                    let submit = try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == title })
                    XCTAssertEqual(submit.read("isAccessibilityEnabled") as? Bool, false, kind + " invalid input must disable submit")
                    click(submit, in: sheet); XCTAssertTrue(model.presented); XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
                }
                if kind == "scene", !save {
                    click(try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "保存场景" }), in: sheet)
                    XCTAssertTrue(model.presented); XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
                }
                let action = ["tags", "diagnostics"].contains(kind) ? "完成" : kind == "comparison" ? "关闭" : save ? title : "取消"
                click(try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == action }), in: sheet)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(model.presented, kind + " action must close its sheet")
                if kind == "file" {
                    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), save ? "modified-中文\n" : "original\n")
                    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
                } else if save {
                    let persisted = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: store.fileURL))
                    if kind == "snippet" { XCTAssertEqual(persisted.snippets.first?.name, snippet.name) }
                    if kind == "forward" { XCTAssertEqual(persisted.forwards.first?.name, rule.name) }
                    if kind == "scene" { XCTAssertEqual(persisted.workScenes.first?.name, scene.name) }
                    if kind == "template" { XCTAssertEqual(persisted.batchTemplates.first?.name, template.name) }
                } else { XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path)) }
            }
        }
    }

    func testDataBoundConfirmationUsesTargetBeforeClearingPresentation() async throws {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        _ = NSApplication.shared
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }

        _ = NSApplication.shared
        let model = AlertAuditModel()
        let hosting = NSHostingView(rootView: DataBoundAlertAuditFixture(model: model))
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.contentView = hosting; parent.makeKeyAndOrderFront(nil)
        defer { model.target = nil; parent.attachedSheet?.orderOut(nil); parent.close() }
        try await Task.sleep(for: .milliseconds(150)); model.target = "fixture-only-target"
        for _ in 0..<40 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
        let sheet = try XCTUnwrap(parent.attachedSheet); let root = try XCTUnwrap(sheet.contentView)
        try await Task.sleep(for: .milliseconds(150))
        click(try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "删除" }), in: sheet)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.result, "fixture-only-target"); XCTAssertNil(model.target)
    }

    func testProcessAndContainerDetailsOpenAndCloseFromRealRows() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute); NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "zh-CN"
        var snapshot = MonitoringSnapshot(timestamp: Date(), os: "Linux", availability: ["processes": "Available", "containerStats": "Available"])
        snapshot.processes = [MonitoringProcess(pid: 123, user: "fixture", threads: 2, state: "running", cpuPercent: 3, memoryBytes: 4096, command: "fixture-process", arguments: "--fixture")]
        snapshot.containers = [MonitoringContainer(id: "fixture-container", name: "fixture-container", image: "fixture/image", state: "running", status: "running", health: nil, restartCount: nil, pid: nil, startedAt: nil, cpuPercent: nil, memoryUsedBytes: nil, memoryLimitBytes: nil, memoryPercent: nil, networkReceivedBytes: nil, networkTransmittedBytes: nil, blockReadBytes: nil, blockWrittenBytes: nil, pids: nil)]
        for kind in ["process", "container"] {
            let view = kind == "process" ? AnyView(MonitoringProcessesView(snapshot: snapshot)) : AnyView(MonitoringDockerView(snapshot: snapshot))
            let hosting = NSHostingView(rootView: view.environmentObject(store))
            let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 680), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.contentView = hosting; parent.makeKeyAndOrderFront(nil)
            defer { parent.attachedSheet?.orderOut(nil); parent.close() }
            try await Task.sleep(for: .milliseconds(150))
            click(try XCTUnwrap(nodes(hosting).first { $0.isButton && $0.title.contains("fixture-" + kind) }), in: parent)
            for _ in 0..<40 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
            let sheet = try XCTUnwrap(parent.attachedSheet); let root = try XCTUnwrap(sheet.contentView)
            try await Task.sleep(for: .milliseconds(150)); try capture(sheet, name: "monitor-detail-" + kind)
            click(try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "关闭" }), in: sheet)
            try await Task.sleep(for: .milliseconds(250)); XCTAssertNil(parent.attachedSheet)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var title: String { ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read($0) as? String }.first { !$0.isEmpty } ?? "" }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        var isButton: Bool { read("accessibilityRole") as? String == NSAccessibility.Role.button.rawValue }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { view.subviews.forEach { visit($0, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }
    private func click(_ node: Node, in window: NSWindow) {
        // SwiftUI uses accessibility elements rather than NSButton tracking.
        // Exercise its actual press action, without synthetic hardware state.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard node.object.responds(to: selector) else { XCTFail("Button has no press action"); return }
        let press = unsafeBitCast(node.object.method(for: selector), to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        _ = press(node.object, selector)
    }
    func testSharedSheetButtonsDisabledStateAndEscapeActuallyDismiss() async throws {
        _ = NSApplication.shared
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        defer { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
        for action in ["保存", "取消", "escape"] {
            let model = AlertAuditModel()
            let hosting = NSHostingView(rootView: AlertAuditFixture(model: model))
            let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1050, height: 680), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false; parent.contentView = hosting; parent.makeKeyAndOrderFront(nil)
            defer { model.presented = false; parent.attachedSheet?.orderOut(nil); parent.close() }
            try await Task.sleep(for: .milliseconds(150)); model.presented = true
            for _ in 0..<40 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(25)) }
            let sheet = try XCTUnwrap(parent.attachedSheet); let root = try XCTUnwrap(sheet.contentView)
            try await Task.sleep(for: .milliseconds(150))
            let disabled = try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "保存" })
            XCTAssertEqual(disabled.read("isAccessibilityEnabled") as? Bool, false)
            click(disabled, in: sheet); try await Task.sleep(for: .milliseconds(100))
            XCTAssertNil(model.result); XCTAssertTrue(model.presented)
            model.valid = true; try await Task.sleep(for: .milliseconds(100))
            let save = try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "保存" })
            let cancel = try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == "取消" })
            XCTAssertGreaterThan(save.frame.width, 0)
            XCTAssertGreaterThan(cancel.frame.width, 0)
            XCTAssertEqual(save.frame.midY, cancel.frame.midY, accuracy: 1, "Footer buttons must share one row")
            XCTAssertFalse(save.frame.intersects(cancel.frame), "Footer buttons must not overlap")
            try capture(sheet, name: "shared-alert-sheet-\(action)")
            if action == "escape" { key(53, chars: "\u{1b}", in: sheet) }
            else { click(try XCTUnwrap(nodes(root).first { $0.isButton && $0.title == action }), in: sheet) }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(model.presented, action + " must dismiss the shared sheet"); XCTAssertEqual(model.result, action == "escape" ? "取消" : action)
        }
    }

}

@MainActor private final class AlertAuditModel: ObservableObject {
    @Published var presented = false
    @Published var valid = false
    @Published var result: String?
    @Published var name = "共享确认框"
    @Published var target: String?
}
private struct AlertAuditFixture: View {
    @ObservedObject var model: AlertAuditModel
    var body: some View {
        Text("弹框交互验收").frame(maxWidth: .infinity, maxHeight: .infinity)
            .appAlert("确认操作", isPresented: $model.presented) {
                AppAlertButton("保存") { model.result = "保存" }.disabled(!model.valid)
                AppAlertButton("取消", role: .cancel) { model.result = "取消" }
            } message: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("仅使用私有测试数据，确认、取消与禁用状态。")
                    TextField("名称", text: $model.name).appInput()
                }
            }
    }
}

private struct EditorAuditFixture: View {
    @ObservedObject var model: AlertAuditModel
    let editor: AnyView
    var body: some View { Text("编辑弹框验收").frame(maxWidth: .infinity, maxHeight: .infinity).sheet(isPresented: $model.presented) { editor } }
}

private struct DataBoundAlertAuditFixture: View {
    @ObservedObject var model: AlertAuditModel
    var body: some View {
        Text("绑定目标确认验收").frame(maxWidth: .infinity, maxHeight: .infinity)
            .appAlert("删除测试目标？", isPresented: Binding(get: { model.target != nil }, set: { if !$0 { model.target = nil } })) {
                AppAlertButton("删除", role: .destructive) { model.result = model.target }
                AppAlertButton("取消", role: .cancel) {}
            }
    }
}
