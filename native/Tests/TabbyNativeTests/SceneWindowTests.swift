import XCTest
import AppKit
@testable import TabbyNative

final class SceneWindowTests: XCTestCase {
    func testSharedConfigurationMergePreservesSiblingChangesAndSceneOrder() throws {
        var base = Workspace(); var host = TabbyNative.Host(); host.name = "original"; base.hosts = [host]
        var scene = WorkScene(name: "test", terminals: [WorkSceneTerminal(), WorkSceneTerminal()]); base.workScenes = [scene]
        var live = base; live.hosts[0].address = "changed.invalid"; live.tags = ["other-window"]
        var edited = base; edited.hosts[0].name = "new-name"; scene.terminals.reverse(); edited.workScenes = [scene]; edited.bookmarks["local"] = ["/tmp"]
        let merged = try SceneWorkspaceMerge.apply(base: base, edited: edited, current: live)
        XCTAssertEqual(merged.hosts[0].name, "new-name"); XCTAssertEqual(merged.hosts[0].address, "changed.invalid")
        XCTAssertEqual(merged.tags, ["other-window"]); XCTAssertEqual(merged.bookmarks["local"], ["/tmp"])
        XCTAssertEqual(merged.workScenes[0].terminals.map(\.id), scene.terminals.map(\.id))
    }
    @MainActor func testCaptureIncludesStandaloneLogAndFileTabsExposeSavedLocations() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-scene-tabs-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let session = TerminalSession(host: nil, store: store); store.sessions = [session]; store.activeSession = session.id
        let entry = FileEntry(name: "service.log", path: "/tmp/service.log", directory: false)
        let pane = FilePane(path: "/tmp", backend: LocalFiles())
        let viewer = store.openLogViewer(pane: pane, entry: entry)
        defer { viewer.close() }
        XCTAssertEqual(store.captureScene().logFiles.map(\.path), [entry.path])
        var definition = WorkScene(name: "Files", terminals: [WorkSceneTerminal()])
        definition.directories = [WorkSceneLocation(path: "/tmp")]
        store.sceneWindowID = definition.id
        let runtime = OpenWorkScene(definition: definition, sessionIDs: [session.id], store: store)
        store.openScenes = [runtime]; store.activeSceneID = definition.id
        XCTAssertEqual(store.sceneFileSessions.map(\.id), [session.id])
        let sceneViewer = store.openLogViewer(pane: pane, entry: entry)
        defer { sceneViewer.close() }
        XCTAssertEqual(store.section, "logviewer")
        XCTAssertTrue(store.standaloneLogViewers.contains { $0.id == sceneViewer.id })
        XCTAssertEqual(runtime.logIDs, [sceneViewer.id])
        XCTAssertFalse(store.captureScene().logFiles.isEmpty)
    }
    @MainActor func testWindowReusesSceneAndOwnsSeparateRuntimeAndClosesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-scene-window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let definition = WorkScene(name: "Separate window", terminals: [WorkSceneTerminal()])
        owner.workspace.workScenes = [definition]
        let controller = try SceneWindowController.open(definition, owner: owner)
        defer { controller.close() }
        XCTAssertTrue(owner.sessions.isEmpty); XCTAssertTrue(owner.openScenes.isEmpty)
        XCTAssertFalse(controller.store === owner); XCTAssertEqual(controller.store.sessions.count, 1)
        XCTAssertEqual(controller.store.currentScene?.id, definition.id)
        XCTAssertEqual(controller.store.section, "terminal")
        XCTAssertEqual(controller.store.terminalTabs.count, 1)
        controller.store.showFileSection(); XCTAssertEqual(controller.store.section, "sftp")
        controller.store.showTerminalSection(); XCTAssertEqual(controller.store.section, "terminal")
        XCTAssertEqual(controller.store.captureScene().id, definition.id)
        let secondDefinition = WorkScene(name: "Other window", terminals: [WorkSceneTerminal()])
        let second = try SceneWindowController.open(secondDefinition, owner: owner)
        defer { second.close() }
        let secondActive = second.store.activeSession
        controller.store.connect()
        XCTAssertEqual(controller.store.currentScene?.sessionIDs.count, 2)
        let pair = controller.store.sessions.map(\.id)
        controller.store.pairSessions(pair[0], with: pair[1])
        XCTAssertEqual(controller.store.splitPartners[pair[0]], pair[1])
        XCTAssertEqual(controller.store.terminalTabs.count, 1)
        XCTAssertTrue(controller.store.captureScene().split)
        controller.store.separateSession(pair[0])
        XCTAssertEqual(controller.store.terminalTabs.count, 2)
        XCTAssertEqual(second.store.sessions.count, 1)
        XCTAssertEqual(second.store.activeSession, secondActive)
        let same = try SceneWindowController.open(definition, owner: controller.store)
        XCTAssertTrue(same === controller)
        controller.store.workspace.bookmarks["local"] = ["/tmp/window"]
        XCTAssertTrue(controller.store.save()); XCTAssertEqual(owner.workspace.bookmarks["local"], ["/tmp/window"])
        controller.close()
        XCTAssertTrue(controller.store.sessions.isEmpty); XCTAssertTrue(controller.store.openScenes.isEmpty)
        XCTAssertTrue(owner.sessions.isEmpty)
        XCTAssertEqual(second.store.sessions.count, 1)
    }
}
