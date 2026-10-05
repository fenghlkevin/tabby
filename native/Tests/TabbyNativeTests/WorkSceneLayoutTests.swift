import AppKit
import SwiftUI
import SwiftTerm
import XCTest
@testable import TabbyNative

@MainActor final class WorkSceneLayoutTests: XCTestCase {
    @MainActor private struct Fixture {
        let directory: URL
        let store: AppStore
        @MainActor func close() {
            store.sceneTasks.values.forEach { $0.cancel() }
            store.forwardTasks.values.forEach { $0.cancel() }
            store.forwardEngines.values.forEach { $0.stop() }
            store.logViewers.forEach { $0.close() }
            store.sessions.forEach { $0.disconnect() }
            store.monitoring.stop()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("axon-scene-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        store.workspace.preferences.fontSize = 13
        store.workspace.preferences.localDirectory = directory.path
        return Fixture(directory: directory, store: store)
    }

    private func cachedSession(_ host: TabbyNative.Host? = nil, store: AppStore, text: String = "") -> TerminalSession {
        let session = TerminalSession(host: host, store: store)
        // makeView() returns this surface without opening a process or network
        // connection. It is still the actual SwiftTerm NSView in MainView.
        let terminal = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        terminal.terminalDelegate = session
        TerminalAppearance.apply(store.workspace.preferences, to: terminal)
        if !text.isEmpty { terminal.feed(text: text) }
        session.terminal = terminal
        return session
    }

    private func runtime(name: String, sessions: [TerminalSession], store: AppStore, rules: [UUID] = [], startRules: Bool = false) -> OpenWorkScene {
        let definition = WorkScene(name: name, terminals: sessions.map { WorkSceneTerminal(hostID: $0.host?.id) }, forwardIDs: rules, startForwards: startRules)
        return OpenWorkScene(definition: definition, sessionIDs: sessions.map(\.id), store: store)
    }

    func testSharedForwardTransportSurvivesClosingItsOriginalScene() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "Shared transport"; host.address = "fixture.invalid"; host.username = "fixture"
        store.workspace.hosts = [host]
        let transport = cachedSession(host, store: store), second = cachedSession(host, store: store)
        var rule = PortForwardRule(); rule.name = "Shared proxy"; rule.kind = "dynamic"; rule.bindPort = 1080; rule.hostID = host.id
        store.workspace.forwards = [rule]
        let firstScene = runtime(name: "First", sessions: [transport], store: store, rules: [rule.id], startRules: true)
        let secondScene = runtime(name: "Second", sessions: [second], store: store, rules: [rule.id], startRules: true)
        store.sessions = [transport, second]; store.openScenes = [firstScene, secondScene]
        store.forwardSessionIDs[rule.id] = transport.id
        store.sceneManagedForwardIDs.insert(rule.id)
        store.forwardTasks[rule.id] = Task { try? await Task.sleep(for: .seconds(60)) }
        store.showScene(firstScene)
        let generation = transport.generation
        store.closeScene(firstScene.id)
        XCTAssertEqual(store.openScenes.map(\.id), [secondScene.id])
        XCTAssertTrue(store.sessions.contains { $0 === transport })
        XCTAssertEqual(store.standaloneSessions.map(\.id), [transport.id], "The shared rule's transport becomes an independently accessible tab")
        XCTAssertEqual(transport.generation, generation, "Closing the first scene must not disconnect a shared transport")
        XCTAssertEqual(store.forwardSessionIDs[rule.id], transport.id)
        XCTAssertNotNil(store.forwardTasks[rule.id])
        XCTAssertEqual(store.activeSceneID, secondScene.id)
        store.closeScene(secondScene.id)
        XCTAssertNil(store.forwardSessionIDs[rule.id], "The last scene releases its owned forwarding rule")
        XCTAssertFalse(store.sceneManagedForwardIDs.contains(rule.id))
    }

    func testManuallyRestartedForwardOutlivesItsPreviousScenes() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "Shared transport"; host.address = "fixture.invalid"; host.username = "fixture"
        store.workspace.hosts = [host]
        let transport = cachedSession(host, store: store), second = cachedSession(store: store)
        // A cached view and pending task exercise forwarding's wait/cancel path
        // without opening SSH or starting a local shell.
        transport.task = Task { try? await Task.sleep(for: .seconds(60)) }
        var rule = PortForwardRule(); rule.kind = "dynamic"; rule.name = "Shared proxy"; rule.hostID = host.id; rule.bindPort = 1080
        store.workspace.forwards = [rule]
        let firstScene = runtime(name: "First", sessions: [transport], store: store, rules: [rule.id], startRules: true)
        let secondScene = runtime(name: "Second", sessions: [second], store: store, rules: [rule.id], startRules: true)
        store.sessions = [transport, second]; store.openScenes = [firstScene, secondScene]
        store.showScene(firstScene)
        store.startForward(rule, origin: .scene)
        try await waitForForwardTransport(rule.id, store: store)
        XCTAssertTrue(store.sceneManagedForwardIDs.contains(rule.id))
        // Another scene asking to start an existing rule keeps its ownership.
        store.startForward(rule, origin: .scene)
        XCTAssertTrue(store.sceneManagedForwardIDs.contains(rule.id))
        let previous = try XCTUnwrap(store.forwardTasks[rule.id])
        store.stopForward(rule.id)
        XCTAssertFalse(store.sceneManagedForwardIDs.contains(rule.id))
        XCTAssertEqual(secondScene.definition.forwardIDs, [rule.id])
        await previous.value
        XCTAssertNil(store.forwardTasks[rule.id])
        store.startForward(rule)
        try await waitForForwardTransport(rule.id, store: store)
        XCTAssertFalse(store.sceneManagedForwardIDs.contains(rule.id))
        store.closeScene(firstScene.id); store.closeScene(secondScene.id)
        XCTAssertNotNil(store.forwardTasks[rule.id], "Closing former owner scenes must preserve a manually restarted rule")
        XCTAssertEqual(store.forwardSessionIDs[rule.id], transport.id)
        XCTAssertEqual(store.standaloneSessions.map(\.id), [transport.id])
        let manual = try XCTUnwrap(store.forwardTasks[rule.id])
        store.stopForward(rule.id)
        await manual.value
        XCTAssertNil(store.forwardSessionIDs[rule.id])
    }

    func testFailedSceneForwardReleasesOwnershipAndTransport() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "Unconnected"; host.address = "fixture.invalid"; host.username = "fixture"
        store.workspace.hosts = [host]
        let transport = cachedSession(host, store: store)
        transport.task = Task { try? await Task.sleep(for: .seconds(60)) }
        store.sessions = [transport]
        var rule = PortForwardRule(); rule.kind = "dynamic"; rule.name = "Unconnected proxy"; rule.hostID = host.id
        store.workspace.forwards = [rule]
        store.startForward(rule, origin: .scene)
        try await waitForForwardTransport(rule.id, store: store)
        let running = try XCTUnwrap(store.forwardTasks[rule.id])
        transport.task?.cancel(); transport.task = nil
        await running.value
        XCTAssertNil(store.forwardTasks[rule.id])
        XCTAssertNil(store.forwardSessionIDs[rule.id])
        XCTAssertFalse(store.sceneManagedForwardIDs.contains(rule.id))
        XCTAssertEqual(store.forwardStatus[rule.id], "SSH connection unavailable")
        // Validation failure also cannot leave a scene ownership marker.
        store.sceneManagedForwardIDs.insert(rule.id)
        rule.bindHost = "0.0.0.0"
        store.startForward(rule, origin: .scene)
        XCTAssertFalse(store.sceneManagedForwardIDs.contains(rule.id))
        XCTAssertNil(store.forwardTasks[rule.id])
    }

    func testLastSceneSessionEndingNeverSelectsAnotherSceneSession() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        let first = cachedSession(store: store), other = cachedSession(store: store), independent = cachedSession(store: store)
        let current = runtime(name: "Current", sessions: [first], store: store)
        let unrelated = runtime(name: "Other", sessions: [other], store: store)
        store.sessions = [first, other, independent]; store.openScenes = [current, unrelated]
        store.showScene(current)
        store.close(first.id)
        XCTAssertTrue(current.sessionIDs.isEmpty)
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(store.activeSceneID, current.id)
        XCTAssertEqual(store.section, "scene")
        XCTAssertEqual(store.sessions.map(\.id), [other.id, independent.id])
    }

    func testCapturingIndependentTabIgnoresPreviouslySelectedScene() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "Saved host"; host.address = "fixture.invalid"
        store.workspace.hosts = [host]
        let sceneSession = cachedSession(host, store: store), independent = cachedSession(store: store)
        let previous = runtime(name: "Previous scene", sessions: [sceneSession], store: store)
        store.sessions = [sceneSession, independent]; store.openScenes = [previous]
        store.showScene(previous)
        store.activeSession = independent.id; store.section = "terminal"
        let captured = store.captureScene()
        XCTAssertNotEqual(captured.id, previous.id)
        XCTAssertEqual(captured.terminals.count, 1)
        XCTAssertNil(captured.terminals[0].hostID)
        XCTAssertEqual(captured.selectedIndex, 0)
        XCTAssertNoThrow(try captured.validated(workspace: store.workspace))
    }

    func testCapturingQuickConnectionReindexesOnlySavedSessions() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let store = fixture.store
        var saved = TabbyNative.Host(); saved.name = "Saved"; saved.address = "saved.invalid"
        var quick = TabbyNative.Host(); quick.name = "Unsaved"; quick.address = "quick.invalid"
        store.workspace.hosts = [saved]
        let savedSession = cachedSession(saved, store: store), quickSession = cachedSession(quick, store: store)
        store.sessions = [savedSession, quickSession]; store.activeSession = quickSession.id; store.section = "terminal"
        let captured = store.captureScene()
        XCTAssertEqual(captured.terminals.map(\.hostID), [saved.id])
        XCTAssertEqual(captured.selectedIndex, 0)
        XCTAssertNoThrow(try captured.validated(workspace: store.workspace))
    }

    func testRealSceneTerminalAndLogViewsFit1100WidthAndExposeEntrances() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let restore = enableAccessibility(); defer { restore() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "App production"; host.address = "fixture.invalid"; host.username = "fixture"
        store.workspace.hosts = [host]
        let first = cachedSession(host, store: store, text: "fixture@app-production:~$ uptime\r\n 10:21:00 up 5 days, load average: 0.15, 0.22, 0.19\r\nfixture@app-production:~$ ")
        let second = cachedSession(store: store, text: "local$ printf 'workspace ready\\n'\r\nworkspace ready\r\nlocal$ ")
        let scene = runtime(name: "Application troubleshooting", sessions: [first, second], store: store)
        scene.definition.split = true
        let logURL = fixture.directory.appendingPathComponent("application.log")
        try Data("2026-10-05 10:20:00 INFO service ready\n2026-10-05 10:20:01 ERROR sample upstream timeout\n2026-10-05 10:20:02 INFO request recovered\n".utf8).write(to: logURL)
        let backend = LocalFiles()
        let entry = try await backend.stat(logURL.path)
        let pane = FilePane(path: fixture.directory.path, backend: backend)
        scene.definition.logFiles = [WorkSceneLocation(path: logURL.path)]
        store.sessions = [first, second]; store.openScenes = [scene]
        store.splitPartners = [first.id: second.id, second.id: first.id]
        store.showScene(scene)
        let viewer = store.openLogViewer(pane: pane, entry: entry, sceneID: scene.id)
        await viewer.pollOnce()
        scene.mode = "terminal"; store.activeSession = first.id
        let hosting = NSHostingView(rootView: MainView().environmentObject(store).preferredColorScheme(.light).frame(minWidth: 1050, minHeight: 680))
        let window = show(hosting, size: NSSize(width: 1100, height: 760)); defer { window.close() }
        try await settle(hosting)
        XCTAssertEqual(hosting.bounds.width, 1100, accuracy: 1)
        for label in ["Save layout", "Terminal", "Logs", "SFTP"] { try assertAccessible(label, in: hosting) }
        XCTAssertNotNil(nodes(hosting).first { $0.identifier == "axon-workarea-tab-Application troubleshooting" })
        XCTAssertTrue(first.terminal?.superview != nil, "MainView hosts the cached native terminal")
        try captureAndAudit(hosting, name: "scene-terminal-1100")
        let modes = try XCTUnwrap(views(NSSegmentedControl.self, in: hosting).first { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" } == ["Terminal", "SFTP", "Logs"]
        })
        XCTAssertEqual(scene.mode, "terminal")
        XCTAssertEqual(modes.selectedSegment, 0)
        XCTAssertTrue(modes.isEnabled && modes.isEnabled(forSegment: 2))
        // The virtual SwiftUI AX child executed its press but returned false.
        // Dispatch the backing AppKit control's action and verify the binding.
        store.activeLogViewer = UUID()
        modes.selectedSegment = 2
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(modes.action), to: modes.target, from: modes))
        try await settle(hosting)
        XCTAssertEqual(scene.mode, "logs")
        for label in ["Follow", "Latest", "Export loaded", "Errors only"] { try assertAccessible(label, in: hosting) }
        XCTAssertTrue(nodes(hosting).contains { $0.text.contains("sample upstream timeout") })
        XCTAssertEqual(store.activeLogViewer, viewer.id)
        try captureAndAudit(hosting, name: "scene-logs-1100")
    }

    func testSceneEditorSaveFooterStaysReachableWhileLongFormScrolls() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let restore = enableAccessibility(); defer { restore() }
        let store = fixture.store
        var host = TabbyNative.Host(); host.name = "Application host"; host.address = "fixture.invalid"
        store.workspace.hosts = [host]
        var rule = PortForwardRule(); rule.name = "Browser SOCKS5"; rule.kind = "dynamic"; rule.hostID = host.id; rule.bindPort = 1080
        store.workspace.forwards = [rule]
        let definition = WorkScene(name: "Application troubleshooting", terminals: (0..<8).map { WorkSceneTerminal(hostID: $0 == 0 ? host.id : nil, directory: "/tmp/workspace-\($0)") }, split: true, directories: [WorkSceneLocation(hostID: host.id, path: "/var/log")], logFiles: [WorkSceneLocation(hostID: host.id, path: "/var/log/application.log")], forwardIDs: [rule.id], startForwards: true)
        let hosting = NSHostingView(rootView: WorkSceneEditor(value: definition).environmentObject(store).preferredColorScheme(.light).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background))
        let window = show(hosting, size: NSSize(width: 1100, height: 760)); defer { window.close() }
        try await settle(hosting)
        let save = try visibleButton("Save scene", in: hosting), cancel = try visibleButton("Cancel", in: hosting)
        let originalSaveFrame = save.frame, originalCancelFrame = cancel.frame
        XCTAssertLessThanOrEqual(hosting.bounds.width, 1101)
        try captureAndAudit(hosting, name: "scene-editor-top-1100")
        let scroll = try XCTUnwrap(views(NSScrollView.self, in: hosting).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 10 })
        let document = try XCTUnwrap(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(hosting)
        let afterSave = try visibleButton("Save scene", in: hosting), afterCancel = try visibleButton("Cancel", in: hosting)
        XCTAssertEqual(afterSave.frame.minY, originalSaveFrame.minY, accuracy: 1)
        XCTAssertEqual(afterSave.frame.minX, originalSaveFrame.minX, accuracy: 1)
        XCTAssertEqual(afterCancel.frame.minY, originalCancelFrame.minY, accuracy: 1)
        try assertAccessible("Start selected rules when opening", in: hosting)
        try captureAndAudit(hosting, name: "scene-editor-bottom-1100")
    }

    func testComparisonParameterSnippetAndSOCKSEditorEntrancesFit1100Width() async throws {
        let fixture = try fixture(); defer { fixture.close() }
        let restore = enableAccessibility(); defer { restore() }
        let store = fixture.store
        let source = fixture.directory.appendingPathComponent("source"), target = fixture.directory.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("sample service configuration\n".utf8).write(to: source.appendingPathComponent("application.conf"))
        let comparison = DirectoryComparisonModel(source: FilePane(path: source.path, backend: LocalFiles()), target: FilePane(path: target.path, backend: LocalFiles()), queue: TransferQueue(), direction: "copy")
        defer { comparison.close() }
        comparison.start()
        for _ in 0..<100 where comparison.scanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(comparison.complete, comparison.error)
        XCTAssertEqual(comparison.selectedRows.map(\.relativePath), ["application.conf"])
        try await renderSheet(DirectoryComparisonSheet(model: comparison), store: store, name: "directory-comparison-1100", labels: ["Compare directories", "Include hidden files", "Compare", "Select differences", "Close", "Copy selected"])

        let terminal = cachedSession(store: store)
        store.sessions = [terminal]; store.activeSession = terminal.id; terminal.connected = true
        var snippet = CommandSnippet(); snippet.name = "Inspect application log"; snippet.body = "tail -n {{lines}} {{file}}"
        snippet.parameters = [SnippetParameter(name: "lines", type: .number, defaultValue: "200"), SnippetParameter(name: "file", type: .path, defaultValue: "/var/log/application latest.log")]
        try await renderSheet(SnippetSendSheet(snippet: snippet, preferredSessionID: terminal.id), store: store, name: "parameter-snippet-1100", labels: ["lines *", "file *", "Command preview", "Connected terminals", "Cancel", "Copy", "Insert", "Run"])

        var host = TabbyNative.Host(); host.name = "Browser proxy host"; host.address = "fixture.invalid"; host.username = "fixture"
        store.workspace.hosts = [host]
        var rule = PortForwardRule(); rule.name = "Browser SOCKS5"; rule.kind = "dynamic"; rule.hostID = host.id; rule.bindPort = 1080
        try await renderSheet(ForwardRuleEditor(rule: rule), store: store, name: "socks-editor-1100", labels: ["TCP forwarding rule", "SOCKS5", "Listening address / port", "Cancel", "Save"])
    }

    private func renderSheet<V: View>(_ view: V, store: AppStore, name: String, labels: [String]) async throws {
        let hosting = NSHostingView(rootView: view.environmentObject(store).preferredColorScheme(.light).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background))
        let window = show(hosting, size: NSSize(width: 1100, height: 760)); defer { window.close() }
        try await settle(hosting)
        XCTAssertEqual(hosting.bounds.width, 1100, accuracy: 1)
        for label in labels { try assertAccessible(label, in: hosting) }
        try captureAndAudit(hosting, name: name)
    }

    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var text: String { ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { read($0) as? String }.first { !$0.isEmpty } ?? "" }
        var identifier: String { read("accessibilityIdentifier") as? String ?? "" }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var result: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0)
        return result
    }
    private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    private func waitForForwardTransport(_ id: UUID, store: AppStore) async throws {
        for _ in 0..<50 {
            if store.forwardSessionIDs[id] != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The forwarding task did not select its cached transport")
    }
    private func enableAccessibility() -> () -> Void {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(attribute) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(attribute)
        NSApp.accessibilitySetValue(true, forAttribute: attribute)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: attribute) }
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        return window
    }
    private func settle(_ hosting: NSView) async throws {
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded()
    }
    private func viewport(_ hosting: NSView) throws -> NSRect {
        try XCTUnwrap(hosting.window).convertToScreen(hosting.convert(hosting.bounds, to: nil))
    }
    private func assertAccessible(_ label: String, in hosting: NSView) throws {
        let bounds = try viewport(hosting)
        XCTAssertTrue(nodes(hosting).contains { $0.text.contains(label) && $0.frame.width > 0 && $0.frame.height > 0 && bounds.insetBy(dx: -1, dy: -1).contains($0.frame) }, "\(label) must be present inside the visible content bounds")
    }
    private func visibleButton(_ title: String, in hosting: NSView) throws -> Node {
        let bounds = try viewport(hosting)
        return try XCTUnwrap(nodes(hosting).first { $0.role == .button && $0.text == title && bounds.insetBy(dx: -1, dy: -1).contains($0.frame) })
    }
    private func captureAndAudit(_ hosting: NSView, name: String) throws {
        let bounds = try viewport(hosting)
        let content = nodes(hosting)
        for node in content where [.button, .checkBox, .radioButton, .popUpButton, .textField].contains(node.role ?? .unknown) {
            guard node.frame.width > 0, node.frame.height > 0, node.frame.intersects(bounds) else { continue }
            XCTAssertGreaterThanOrEqual(node.frame.minX, bounds.minX - 1, "\(name): \(node.text) overflows left")
            XCTAssertLessThanOrEqual(node.frame.maxX, bounds.maxX + 1, "\(name): \(node.text) overflows right")
        }
        let output = URL(fileURLWithPath: "/private/tmp/axon-workflows-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        let records = content.map { ["text": $0.text, "identifier": $0.identifier, "role": $0.role?.rawValue ?? "", "frame": NSStringFromRect($0.frame)] }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + ".json"))
    }
}
