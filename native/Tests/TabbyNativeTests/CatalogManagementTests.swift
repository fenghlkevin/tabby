import XCTest
@testable import TabbyNative

final class CatalogManagementTests: XCTestCase {
    func testLegacyWorkspaceWithoutTagCatalogKeepsHostTags() throws {
        var workspace = Workspace()
        var host = TabbyNative.Host(); host.address = "fixture.invalid"; host.tags = "Production database, test"
        workspace.hosts = [host]
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        legacy.removeValue(forKey: "tags")
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertEqual(decoded.hosts, [host])
        XCTAssertEqual(TagTokens.parse(decoded.hosts[0].tags), ["Production", "database", "test"])
    }

    @MainActor func testEmptyGroupsAndTagsPersistAndNamesAreUniqueIgnoringCase() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        try store.addGroup("  Production  ")
        try store.createTag("  数据库  ")
        try store.createTag("Backend")
        XCTAssertThrowsError(try store.addGroup("production"))
        XCTAssertThrowsError(try store.createTag("backend"))
        for invalid in ["", " ", "two tags", "a,b", "a，b", "a\nb"] { XCTAssertThrowsError(try store.createTag(invalid)) }
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.groups, ["Production"])
        XCTAssertEqual(Set(loaded.tags), Set(["数据库", "Backend"]))
        XCTAssertTrue(loaded.workspace.hosts.isEmpty)
    }

    @MainActor func testRenameAndDeleteGroupUpdateAllHostsAndKeepTheirData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var first = TabbyNative.Host(); first.address = "first.invalid"; first.group = "Production"; first.tags = "database"; first.favorite = true
        var second = TabbyNative.Host(); second.address = "second.invalid"; second.group = "production"; second.auth = "key"; second.keyPath = "/fixture/key"
        var unrelated = TabbyNative.Host(); unrelated.address = "other.invalid"; unrelated.group = "Personal"
        store.workspace.hosts = [first, second, unrelated]
        store.workspace.groups = ["Production", "production", "Empty"]
        store.group = "Production"
        try store.renameGroup("production", to: "Servers")
        first.group = "Servers"; second.group = "Servers"
        XCTAssertEqual(store.workspace.hosts, [first, second, unrelated])
        XCTAssertEqual(store.group, "Servers")
        XCTAssertEqual(store.catalogHostCount("servers", section: .groups), 2)
        XCTAssertThrowsError(try store.renameGroup("Servers", to: " personal "))
        try store.removeGroup("SERVERS")
        first.group = ""; second.group = ""
        XCTAssertEqual(store.workspace.hosts, [first, second, unrelated])
        XCTAssertEqual(store.group, "")
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.workspace.hosts, [first, second, unrelated])
        XCTAssertEqual(Set(loaded.groups), Set(["Personal", "Empty"]))
    }

    @MainActor func testTagRenameAndDeleteGloballyHandleLegacyTokensAndPreserveHosts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var first = TabbyNative.Host(); first.address = "first.invalid"; first.tags = "Prod, db test"; first.favorite = true
        var second = TabbyNative.Host(); second.address = "second.invalid"; second.tags = "prod，Prod，frontend"; second.credentialID = UUID()
        store.workspace.hosts = [first, second]
        store.workspace.tags = ["Orphan"]
        XCTAssertEqual(store.catalogHostCount("PROD", section: .tags), 2)
        try store.renameTag("prod", to: "  Production  ")
        first.tags = "Production, db, test"; second.tags = "Production, frontend"
        XCTAssertEqual(store.workspace.hosts, [first, second])
        XCTAssertTrue(store.tags.contains("Orphan"))
        XCTAssertFalse(store.tags.contains("Prod"))
        XCTAssertThrowsError(try store.renameTag("Production", to: "DB"))
        try store.deleteTag("PRODUCTION")
        first.tags = "db, test"; second.tags = "frontend"
        XCTAssertEqual(store.workspace.hosts, [first, second])
        let loaded = AppStore(fileURL: store.fileURL)
        XCTAssertEqual(loaded.workspace.hosts, [first, second])
        XCTAssertEqual(Set(loaded.tags), Set(["Orphan", "db", "test", "frontend"]))
        try store.deleteTag("Orphan")
        XCTAssertFalse(AppStore(fileURL: store.fileURL).tags.contains("Orphan"))
    }

    @MainActor func testFailedPersistenceRollsBackCatalogHostsAndSelectedGroup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("kept".utf8).write(to: blocker)
        let store = AppStore(fileURL: blocker.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.address = "fixture.invalid"; host.group = "Group"; host.tags = "Tag, Other"
        store.workspace.hosts = [host]; store.workspace.groups = ["Group"]; store.workspace.tags = ["Tag", "Other"]
        store.group = "Group"
        let original = store.workspace
        for mutate in [
            { try store.addGroup("New") },
            { try store.renameGroup("Group", to: "Renamed") },
            { try store.removeGroup("Group") },
            { try store.createTag("New") },
            { try store.renameTag("Tag", to: "Renamed") },
            { try store.deleteTag("Tag") },
        ] {
            XCTAssertThrowsError(try mutate())
            XCTAssertEqual(store.workspace.hosts, original.hosts)
            XCTAssertEqual(store.workspace.groups, original.groups)
            XCTAssertEqual(store.workspace.tags, original.tags)
            XCTAssertEqual(store.group, "Group")
        }
        store.dissolveGroup("Group")
        XCTAssertEqual(store.workspace.hosts, original.hosts)
        XCTAssertEqual(store.group, "Group")
        XCTAssertNotNil(store.error)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("kept".utf8))
    }

    @MainActor func testUnreadableWorkspaceCannotBeOverwrittenByCatalogChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("workspace.json")
        let original = Data("unreadable original".utf8)
        try original.write(to: url)
        let store = AppStore(fileURL: url)
        XCTAssertThrowsError(try store.addGroup("New"))
        XCTAssertThrowsError(try store.createTag("New"))
        XCTAssertTrue(store.workspace.groups.isEmpty)
        XCTAssertTrue(store.workspace.tags.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
