import XCTest
@testable import TabbyNative

final class LauncherTests: XCTestCase {
    private func host(_ name: String, group: String = "", address: String = "example.invalid", tags: String = "") -> TabbyNative.Host {
        var value = TabbyNative.Host(); value.name = name; value.group = group; value.address = address; value.username = "root"; value.tags = tags
        return value
    }
    func testRootShowsGroupsAndOnlyUngroupedHosts() {
        let production = host("production", group: "Production")
        let development = host("dev", group: "Development")
        let ungrouped = host("personal")
        let catalog = LauncherCatalog(hosts: [production, development, ungrouped], groups: ["Empty", "Production"], query: "", selectedGroup: nil)
        XCTAssertEqual(catalog.visibleGroups, ["Development", "Empty", "Production"])
        XCTAssertEqual(catalog.visibleHosts.map(\.id), [ungrouped.id])
        XCTAssertEqual(catalog.count(in: "Production"), 1)
        let selected = LauncherCatalog(hosts: catalog.hosts, groups: catalog.groups, query: "", selectedGroup: "Production")
        XCTAssertTrue(selected.visibleGroups.isEmpty)
        XCTAssertEqual(selected.visibleHosts.map(\.id), [production.id])
        let empty = LauncherCatalog(hosts: catalog.hosts, groups: catalog.groups, query: "", selectedGroup: "Empty")
        XCTAssertTrue(empty.visibleHosts.isEmpty)
    }
    func testHostLibraryRootHidesGroupedHostsWhileFiltersStillFindThem() {
        var production = host("api", group: "Production", address: "192.0.2.10", tags: "backend")
        production.favorite = true
        let development = host("dev", group: "Development", tags: "backend")
        let ungrouped = host("personal")
        let values = [production, development, ungrouped]
        let root = HostLibraryCatalog(hosts: values)
        XCTAssertTrue(root.isRootBrowse)
        XCTAssertEqual(root.visibleHosts.map(\.id), [ungrouped.id])
        XCTAssertEqual(HostLibraryCatalog(hosts: values, query: " \n ").visibleHosts.map(\.id), [ungrouped.id])
        XCTAssertEqual(HostLibraryCatalog(hosts: values, group: "Production").visibleHosts.map(\.id), [production.id])
        XCTAssertEqual(HostLibraryCatalog(hosts: values, query: "192.0.2.10").visibleHosts.map(\.id), [production.id])
        XCTAssertEqual(HostLibraryCatalog(hosts: values, query: " production ").visibleHosts.map(\.id), [production.id])
        XCTAssertEqual(Set(HostLibraryCatalog(hosts: values, tag: "backend").visibleHosts.map(\.id)), Set([production.id, development.id]))
        XCTAssertEqual(HostLibraryCatalog(hosts: values, favoritesOnly: true).visibleHosts.map(\.id), [production.id])
        XCTAssertTrue(HostLibraryCatalog(hosts: values, group: "Development", favoritesOnly: true).visibleHosts.isEmpty)
        XCTAssertTrue(HostLibraryCatalog(hosts: values, group: "Production", query: "personal").visibleHosts.isEmpty)
    }
    func testSearchListsHostsByAddressTagsAndGroupNameWithoutFolders() {
        let first = host("api", group: "Production", address: "192.0.2.10", tags: "backend")
        let second = host("db", group: "Production", address: "192.0.2.11", tags: "database")
        let personal = host("other", tags: "backend")
        let values = [first, second, personal]
        let byTag = LauncherCatalog(hosts: values, groups: [], query: "backend", selectedGroup: nil)
        XCTAssertTrue(byTag.visibleGroups.isEmpty)
        XCTAssertEqual(Set(byTag.visibleHosts.map(\.id)), Set([first.id, personal.id]))
        let withinGroup = LauncherCatalog(hosts: values, groups: [], query: "192.0.2.11", selectedGroup: "Production")
        XCTAssertEqual(withinGroup.visibleHosts.map(\.id), [second.id])
        let byName = LauncherCatalog(hosts: values, groups: [], query: " production ", selectedGroup: "Production")
        XCTAssertEqual(Set(byName.visibleHosts.map(\.id)), Set([first.id, second.id]))
        let rootGroupSearch = LauncherCatalog(hosts: values, groups: [], query: "production", selectedGroup: nil)
        XCTAssertTrue(rootGroupSearch.visibleGroups.isEmpty)
        XCTAssertEqual(Set(rootGroupSearch.visibleHosts.map(\.id)), Set([first.id, second.id]))
        let addressSearch = LauncherCatalog(hosts: values, groups: [], query: "192.0.2.11", selectedGroup: nil)
        XCTAssertEqual(addressSearch.visibleHosts.map(\.id), [second.id])
        let missing = LauncherCatalog(hosts: values, groups: [], query: "missing", selectedGroup: nil)
        XCTAssertTrue(missing.visibleGroups.isEmpty); XCTAssertTrue(missing.visibleHosts.isEmpty)
    }
    func testQuickTargetsAcceptAddressesAndRejectCommandOptions() {
        XCTAssertEqual(parseLauncherQuickHost("test@example.invalid -p 2222")?.port, 2222)
        XCTAssertEqual(parseLauncherQuickHost("ssh test@example.invalid")?.username, "test")
        XCTAssertEqual(parseLauncherQuickHost("192.0.2.10")?.username, "root")
        XCTAssertEqual(parseLauncherQuickHost("ssh internal-host -p 2200")?.address, "internal-host")
        XCTAssertEqual(parseLauncherQuickHost("::1")?.address, "::1")
        XCTAssertEqual(parseLauncherQuickHost("localhost")?.address, "localhost")
        for query in ["Production", "api hosts", "ssh localhost -o ProxyCommand=anything", "ssh root@example.invalid -p 0", "ssh root@example.invalid -p 99999", "root@host/path", "root@host;command", "https://example.invalid", "-example.invalid"] { XCTAssertNil(parseLauncherQuickHost(query), query) }
    }
    @MainActor func testQuickConnectionReusesSavedCredentialsWithoutAddingHosts() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var credential = VaultCredential(); credential.username = "current-user"
        var saved = host("saved"); saved.credentialID = credential.id; saved.username = "old-user"; saved.port = 2222
        store.workspace.hosts = [saved]; store.workspace.credentials = [credential]
        var request = host("temporary", address: "EXAMPLE.INVALID"); request.username = "current-user"; request.port = 2222
        XCTAssertEqual(store.quickConnectionHost(request).id, saved.id)
        store.connectQuick(request)
        XCTAssertEqual(store.sessions.first?.host?.id, saved.id)
        XCTAssertEqual(store.workspace.hosts, [saved])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        request.port = 22
        XCTAssertEqual(store.quickConnectionHost(request).id, request.id)
        request.port = 2222; request.credentialID = UUID()
        XCTAssertEqual(store.quickConnectionHost(request).credentialID, request.credentialID)
    }
    @MainActor func testOpeningLauncherKeepsExistingSessionAndCanRequestFocusAgain() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.connect()
        let id = store.activeSession
        store.openLauncher()
        XCTAssertEqual(store.section, "launcher"); XCTAssertEqual(store.launcherRequest, 1)
        store.openLauncher()
        XCTAssertEqual(store.launcherRequest, 2); XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.activeSession, id)
    }
    @MainActor func testOpeningTerminalConsumesLauncherButSwitchingPagesKeepsIt() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.openLauncher()
        XCTAssertTrue(store.newTabOpen)
        store.section = "hosts"
        XCTAssertTrue(store.newTabOpen)
        store.openLauncher()
        var host = TabbyNative.Host(); host.name = "Launcher fixture"; host.address = "fixture.invalid"
        store.connect(host)
        XCTAssertFalse(store.newTabOpen)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.sessions.last?.host?.id, host.id)
        store.openLauncher()
        store.connect()
        XCTAssertFalse(store.newTabOpen)
        XCTAssertEqual(store.sessions.count, 2)
        XCTAssertNil(store.sessions.last?.host)
    }

    @MainActor func testReorderingTabsPreservesSessionAndSplitIdentity() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.connect(); let first = store.sessions[0]
        store.split(); let second = store.sessions[1]
        store.connect(); let third = store.sessions[2]
        let split = store.splitPartners
        store.moveSession(third.id, before: first.id)
        XCTAssertEqual(store.sessions.map(\.id), [third.id, first.id, second.id])
        XCTAssertTrue(store.sessions[1] === first)
        XCTAssertEqual(store.activeSession, third.id)
        XCTAssertEqual(store.splitPartners, split)
        store.moveSessionToEnd(first.id)
        XCTAssertEqual(store.sessions.map(\.id), [third.id, second.id, first.id])
        store.moveSession(first.id, before: second.id)
        store.moveSession(first.id, before: UUID())
        store.moveSession(first.id, before: first.id)
        XCTAssertEqual(store.sessions.map(\.id), [third.id, first.id, second.id])
    }
}
