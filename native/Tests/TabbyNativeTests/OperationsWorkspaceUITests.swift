import XCTest
import AppKit
import SwiftUI
import SwiftTerm
@testable import TabbyNative

@MainActor final class OperationsWorkspaceUITests: XCTestCase {
    func testRenderedHistoryTemplatesDiagnosticsLogsAndFourPaneWorkspace() async throws {
        _ = NSApplication.shared
        let axKey = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let oldAX = NSApp.accessibilityAttributeValue(axKey); NSApp.accessibilitySetValue(true, forAttribute: axKey)
        defer { NSApp.accessibilitySetValue(oldAX ?? false, forAttribute: axKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-operations-ui-" + UUID().uuidString)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        defer { for id in store.sessions.map(\.id) { store.close(id) }; try? FileManager.default.removeItem(at: root) }
        store.workspace.preferences.language = "zh-CN"
        var host = TabbyNative.Host(); host.name = "production-api-east-01-生产环境应用服务器"; host.address = "192.0.2.10"; host.username = "deploy"
        store.workspace.hosts = [host]
        var success = BatchResult(hostID: host.id, hostName: host.name); success.state = "success"; success.exitCode = 0; success.output = "prod-api-01\nload average: 0.42 0.30 0.21\n磁盘使用率：42%"; success.finished = Date()
        var failed = success; failed.id = UUID(); failed.hostName = "production-worker-02"; failed.state = "failed"; failed.exitCode = 1; failed.error = "Permission denied: /opt/app/logs/service.log"; failed.output = ""
        var run = BatchRun(title: "生产环境健康检查", command: "hostname && uptime && df -h", concurrency: 3, timeout: 60, targets: [BatchTargetSnapshot(host, workspace: store.workspace)], results: [success, failed]); run.finished = Date()
        try store.batchTasks.archive.save(run)
        let template = BatchTemplate(name: "应用日志巡检", notes: "检查最新应用日志，执行前选择目标并填写日志路径。", command: "tail -n {{count}} {{path}}", hostIDs: [host.id], concurrency: 3, timeout: 90, parameters: [.init(name: "count", type: .number, defaultValue: "30"), .init(name: "path", type: .path, defaultValue: "/opt/app/logs/service.log")])
        store.workspace.batchTemplates = [template]
        for (width, language): (CGFloat, String) in [(1050, "zh-CN"), (1400, "en-US")] {
            store.workspace.preferences.language = language
            try await render(BatchLibraryView(center: store.batchTasks, mode: "history", load: { _ in }, edit: { _ in }).environmentObject(store).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.background), size: CGSize(width: width - 240, height: 950), name: "history-\(Int(width))") { hosting in
                XCTAssertTrue(self.all(SelectionFieldButton.self, in: hosting).contains { $0.accessibilityIdentifier() == "axon-history-filter" })
            }
            try await render(BatchLibraryView(center: store.batchTasks, mode: "templates", load: { _ in }, edit: { _ in }).environmentObject(store).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.background), size: CGSize(width: width - 240, height: 650), name: "templates-\(Int(width))")
        }
        store.workspace.preferences.language = "zh-CN"
        store.section = "batchTasks"
        for mode in ["history", "templates"] {
            try await render(MainView().environmentObject(store), size: CGSize(width: 1050, height: 950), name: "workspace-" + mode) { view in
                try self.press("axon-batch-library-" + mode, in: view)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertTrue(self.all(SelectionFieldButton.self, in: view).contains { $0.accessibilityIdentifier() == "axon-history-filter" } || mode == "templates")
            }
        }
        var savedTemplate: BatchTemplate?
        try await render(BatchTemplateEditor(value: template, save: { savedTemplate = $0 }).environmentObject(store), size: CGSize(width: 720, height: 700), name: "template-editor") { view in
            XCTAssertEqual(self.all(SelectionFieldButton.self, in: view).count, 3)
            XCTAssertFalse(self.all(NSPopUpButton.self, in: view).contains { $0.isEnabled })
            try self.press("axon-template-save", in: view)
            XCTAssertEqual(savedTemplate?.parameters.map(\.name), ["count", "path"])
        }
        try await render(SSHDiagnosticsSheet(host: host).environmentObject(store), size: CGSize(width: 720, height: 700), name: "ssh-diagnostics")
        var agentHost = host; agentHost.auth = "agent"; agentHost.agentSocketPath = "/tmp/axon-unavailable-agent.sock"
        try await render(SSHAgentHostFields(host: .constant(agentHost)).environmentObject(store).padding(20).background(Palette.card), size: CGSize(width: 430, height: 330), name: "agent-fields")
        var certificateHost = host; certificateHost.auth = "key"; certificateHost.certificatePath = "/fixtures/deploy-cert.pub"; certificateHost.certificateAuthorityPath = "/fixtures/company-ca.pub"; certificateHost.forwardAgent = true; certificateHost.agentFingerprint = "SHA256:fixture-selected-identity"
        try await render(SSHCompatibilityFields(host: .constant(certificateHost)).environmentObject(store).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.card), size: CGSize(width: 360, height: 800), name: "certificate-forwarding-controls")
        let sessions = (0..<4).map { i in var item = host; item.id = UUID(); item.name = "prod-api-0\(i + 1)"; return TerminalSession(host: item, store: store) }
        store.sessions = sessions; store.activeSession = sessions[0].id; store.terminalPaneGroups[sessions[0].id] = sessions.map(\.id); store.section = "terminal"
        let privateHistory = CommandHistoryStore(fileURL: root.appendingPathComponent("commands.json"))
        for (i, session) in sessions.enumerated() {
            session.connected = true; session.commandHistoryStore = privateHistory
            let view = RemoteTerminal(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: TerminalOptions())
            view.store = store; view.sessionID = session.id; view.terminalDelegate = session; session.terminal = view
            TerminalAppearance.apply(store.workspace.preferences, to: view)
            view.feed(text: "\u{1b}[32mdeploy@prod-0\(i + 1)\u{1b}[0m ~ $ uptime\r\n 10:42 up 12 days, load average: 0.42\r\n$ ")
        }
        store.synchronizedTargets = Set(sessions.prefix(3).map(\.id)); store.synchronizationEnabled = true
        for width: CGFloat in [1050, 1400] {
            try await render(MainView().environmentObject(store), size: CGSize(width: width, height: 850), name: "four-panes-\(Int(width))") { view in
                let terminals = self.all(TerminalView.self, in: view).filter { candidate in sessions.contains { $0.terminal === candidate } }
                XCTAssertEqual(terminals.count, 4)
                let layout = terminals.map { NSStringFromRect($0.frame) + " bounds=" + NSStringFromRect($0.bounds) + " host=" + NSStringFromRect($0.convert($0.bounds, to: view)) + " cols=" + String($0.terminalStateSnapshot().dimensions.cols) }
                try layout.joined(separator: "\n").write(to: URL(fileURLWithPath: "/private/tmp/axon-pane-layout-\(Int(width)).txt"), atomically: true, encoding: .utf8)
                XCTAssertTrue(terminals.allSatisfy { $0.bounds.width > 300 && $0.bounds.height > 250 })
                for (i, terminal) in terminals.enumerated() { terminal.feed(text: "\u{1b}[2J\u{1b}[Hdeploy@prod-0\(i+1) $ uptime\r\nload: 0.42 0.30 0.21\r\n$ ") }
                try await Task.sleep(for: .milliseconds(150))
                let terminal = try XCTUnwrap(terminals.first)
                let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds)); terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/axon-pane-direct.png"))
            }
        }
        try await render(TerminalComposeSheet().environmentObject(store), size: CGSize(width: 660, height: 730), name: "synchronized-input") { view in
            try self.press("axon-sync-target-" + sessions[3].id.uuidString, in: view)
            try await Task.sleep(for: .milliseconds(150))
            try self.press("axon-sync-apply", in: view)
            XCTAssertEqual(store.synchronizedTargets.count, 4); XCTAssertTrue(store.synchronizationReady)
        }
        let logger = store.sessionLogs, logID = try logger.begin(session: sessions[0])
        let command = ExecutedCommand(hostID: host.id, hostName: host.name, sessionID: sessions[0].id, command: "systemctl status app")
        logger.append(Array("deploy@production-api-east-01\n$ systemctl status app\n● app.service - Application service\n   Active: active (running) since 2026-10-06 09:30:00\n   Main PID: 1324 (java)\n2026-10-06 10:42:00 INFO 服务运行正常\n2026-10-06 10:42:01 WARN Request duration exceeded 500ms\n".utf8), id: logID)
        logger.marker(command, report: "", id: logID); logger.stop(logID); logger.selectedID = logID
        for width: CGFloat in [810, 1160] {
            try await render(SessionLogsView(logs: logger).environmentObject(store), size: CGSize(width: width, height: 750), name: "session-logs-\(Int(width))") { view in
                let output = try XCTUnwrap(self.all(NSTextView.self, in: view).first { $0.accessibilityIdentifier() == "axon-transcript-output" })
                XCTAssertTrue(output.isSelectable); XCTAssertFalse(output.isEditable); XCTAssertTrue(output.string.contains("服务运行正常"))
            }
        }
    }
    func testPaneFontControlsAdjustOnlyTheirTerminal() async throws {
        _ = NSApplication.shared
        let axKey = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let oldAX = NSApp.accessibilityAttributeValue(axKey); NSApp.accessibilitySetValue(true, forAttribute: axKey)
        defer { NSApp.accessibilitySetValue(oldAX ?? false, forAttribute: axKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        store.workspace.preferences.fontSize = 19
        let sessions = (0..<4).map { i -> TerminalSession in
            var host = TabbyNative.Host(); host.name = "字号验收服务器-\(i + 1)"; host.address = "fixture.invalid"
            return TerminalSession(host: host, store: store)
        }
        store.sessions = sessions; store.activeSession = sessions[0].id
        store.terminalPaneGroups[sessions[0].id] = sessions.map(\.id); store.section = "terminal"
        for session in sessions {
            let terminal = RemoteTerminal(frame: .zero)
            terminal.store = store; terminal.sessionID = session.id; terminal.ownerSession = session
            terminal.terminalDelegate = session; session.terminal = terminal
            session.applyFontSize()
        }
        for width: CGFloat in [1050, 1400] {
            try await render(MainView().environmentObject(store), size: CGSize(width: width, height: 850), name: "pane-font-\(Int(width))") { view in
                let session = sessions[2]
                session.setFontSize(nil)
                for _ in 0..<6 { try self.press("axon-font-decrease-" + session.id.uuidString, in: view); try await Task.sleep(for: .milliseconds(30)) }
                XCTAssertEqual(session.terminal?.font.pointSize, 13)
                XCTAssertEqual(sessions[0].terminal?.font.pointSize, 19)
                try self.press("axon-font-increase-" + session.id.uuidString, in: view)
                XCTAssertEqual(session.effectiveFontSize, 14)
                try self.press("axon-font-reset-" + session.id.uuidString, in: view)
                XCTAssertEqual(session.effectiveFontSize, 19)
                session.setFontSize(13)
                let window = try XCTUnwrap(view.window)
                window.makeFirstResponder(sessions[1].terminal)
                store.activeSession = sessions[1].id
                let dispatcher = ApplicationShortcutDispatcher { _ in store }
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "-", charactersIgnoringModifiers: "-", isARepeat: false, keyCode: 27))
                XCTAssertTrue(dispatcher.handle(event))
                XCTAssertEqual(sessions[1].effectiveFontSize, 18)
                XCTAssertEqual(sessions[2].effectiveFontSize, 13)
                for item in sessions { item.terminal?.feed(text: "root@server ~ # ls -l\r\n日志 logs  配置 config  备份 backup\r\nroot@server ~ # ") }
            }
            sessions[1].setFontSize(nil)
        }
        try await render(MainView().environmentObject(store), size: CGSize(width: 1050, height: 850), name: "last-pane-font-reset") { view in
            for index in [3, 1, 0] {
                try self.press("axon-close-pane-" + sessions[index].id.uuidString, in: view)
                try await Task.sleep(for: .milliseconds(150))
            }
            XCTAssertEqual(store.sessions.map(\.id), [sessions[2].id])
            XCTAssertEqual(sessions[2].terminal?.font.pointSize, 19)
            XCTAssertNil(sessions[2].fontSizeOverride)
        }
    }

    func testLauncherSearchShowsMatchingGroupedHostsDirectly() async throws {
        _ = NSApplication.shared
        let axKey = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let oldAX = NSApp.accessibilityAttributeValue(axKey); NSApp.accessibilitySetValue(true, forAttribute: axKey)
        defer { NSApp.accessibilitySetValue(oldAX ?? false, forAttribute: axKey) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "zh-CN"
        var first = TabbyNative.Host(); first.name = "172.27.199.160"; first.address = first.name; first.group = "company"
        var second = first; second.id = UUID(); second.name = "匹配服务器 160 — 长名称验收"; second.address = "172.26.148.160"; second.group = "Imported"
        var other = first; other.id = UUID(); other.name = "不匹配服务器"; other.address = "172.27.199.202"
        store.workspace.hosts = [first, second, other]
        for width: CGFloat in [1050, 1400] {
            try await render(LauncherView().environmentObject(store).background(Palette.background), size: CGSize(width: width, height: 850), name: "launcher-host-search-\(Int(width))") { view in
                let field = try XCTUnwrap(self.all(NSTextField.self, in: view).first { $0.isEditable })
                let window = try XCTUnwrap(view.window)
                window.makeFirstResponder(field)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.selectAll(nil); editor.insertText("160", replacementRange: editor.selectedRange())
                try await Task.sleep(for: .milliseconds(150))
                try self.press("axon-launcher-clear-search", in: view)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(field.stringValue, "")
                window.makeFirstResponder(field)
                let nextEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                nextEditor.insertText("160", replacementRange: nextEditor.selectedRange())
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(field.stringValue, "160")
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String, check: (NSView) async throws -> Void = { _ in }) async throws {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(.light).tint(Palette.accent)); hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); defer { window.close() }
        try await Task.sleep(for: .milliseconds(350)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded(); try await Task.sleep(for: .milliseconds(150))
        try await check(hosting)
        try await Task.sleep(for: .milliseconds(150))
        for field in all(SelectionFieldButton.self, in: hosting) {
            XCTAssertNotNil(field.hitTest(NSPoint(x: 2, y: 2)), name)
            XCTAssertNotNil(field.hitTest(NSPoint(x: field.bounds.width - 2, y: field.bounds.height - 2)), name)
            let frame = field.convert(field.bounds, to: hosting)
            XCTAssertGreaterThanOrEqual(frame.minX, -1, name); XCTAssertLessThanOrEqual(frame.maxX, size.width + 1, name)
        }
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let destination = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("dist/ui-0.10.1")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination.appendingPathComponent(name + ".png"))
    }
    private func press(_ identifier: String, in root: NSView) throws {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 60, seen.insert(ObjectIdentifier(object)).inserted else { return nil }
            func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
            if read("accessibilityIdentifier") as? String == identifier, read("accessibilityRole") as? String == "AXButton" { return object }
            for child in read("accessibilityChildren") as? [NSObject] ?? [] { if let found = visit(child, depth: depth + 1) { return found } }
            if let view = object as? NSView { for child in view.subviews { if let found = visit(child, depth: depth + 1) { return found } } }
            return nil
        }
        let object = try XCTUnwrap(visit(root, depth: 0), identifier)
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(object.method(for: selector))
        let perform = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        XCTAssertTrue(perform(object, selector), identifier)
    }
    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { all(type, in: $0) } }
}
