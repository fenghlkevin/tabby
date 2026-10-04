import XCTest
import Combine
import SwiftTerm
@testable import TabbyNative

final class SessionTitleTests: XCTestCase {
    func testDuplicateTitlesUseCreationOrderDespiteTabOrder() {
        let a = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 1)
        let b = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 2)
        let c = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 3)
        let expected = [a.id: "root@production (1)", b.id: "root@production (2)", c.id: "root@production (3)"]
        XCTAssertEqual(SessionTitleCatalog.labels(for: [c, a, b]), expected)
        XCTAssertEqual(SessionTitleCatalog.labels(for: [b, c, a]), expected)
        XCTAssertEqual(SessionTitleCatalog.labels(for: [a, b, c]), expected)
    }
    func testClosingRenumbersRemainingByCreationOrderAndSingletonIsUnsuffixed() {
        let a = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 1)
        let b = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 2)
        let c = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 3)
        XCTAssertEqual(SessionTitleCatalog.labels(for: [c, a, b])[b.id], "root@production (2)")
        XCTAssertEqual(SessionTitleCatalog.labels(for: [c, b]), [b.id: "root@production (1)", c.id: "root@production (2)"])
        XCTAssertEqual(SessionTitleCatalog.labels(for: [c]), [c.id: "root@production"])
        XCTAssertTrue(SessionTitleCatalog.labels(for: []).isEmpty)
    }
    func testActualNumberedNamesRemainUnchangedAndGeneratedTitlesAreUnique() {
        let a = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 1)
        let b = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production", creationOrder: 2)
        let named = SessionTitleCatalog.Entry(id: UUID(), baseTitle: "root@production (1)", creationOrder: 3)
        let labels = SessionTitleCatalog.labels(for: [named, b, a])
        XCTAssertEqual(labels[named.id], "root@production (1)")
        XCTAssertEqual(labels[a.id], "root@production (2)")
        XCTAssertEqual(labels[b.id], "root@production (3)")
        XCTAssertEqual(Set(labels.values).count, 3)
        XCTAssertEqual(labels, SessionTitleCatalog.labels(for: [a, b, named]))
    }
    func testDistinctVisibleBasesDoNotGetSuffixes() {
        let values = ["root@production", "deploy@production", "root@staging"].enumerated().map {
            SessionTitleCatalog.Entry(id: UUID(), baseTitle: $0.element, creationOrder: UInt64($0.offset))
        }
        let labels = SessionTitleCatalog.labels(for: values)
        for value in values { XCTAssertEqual(labels[value.id], value.baseTitle) }
    }
    @MainActor func testSessionDisplayLabelsSurviveMovesAndCloseWithoutChangingBaseTitles() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var host = TabbyNative.Host(); host.name = "Production"; host.address = "192.0.2.10"; host.username = "root"
        let a = TerminalSession(host: host, store: store)
        let b = TerminalSession(host: host, store: store)
        let c = TerminalSession(host: host, store: store)
        store.sessions = [a, b, c]
        let expected = store.sessionTitles
        XCTAssertEqual(a.displayTitle, "root@Production (1)"); XCTAssertEqual(b.displayTitle, "root@Production (2)")
        XCTAssertLessThan(a.creationOrder, b.creationOrder); XCTAssertLessThan(b.creationOrder, c.creationOrder)
        store.moveSession(c.id, before: a.id)
        XCTAssertEqual(store.sessions.map(\.id), [c.id, a.id, b.id]); XCTAssertEqual(store.sessionTitles, expected)
        store.moveSessionToEnd(a.id)
        XCTAssertEqual(store.sessions.map(\.id), [c.id, b.id, a.id]); XCTAssertEqual(store.sessionTitles, expected)
        XCTAssertTrue(store.sessions.allSatisfy { $0.title == "root@Production" })
        store.close(a.id)
        XCTAssertEqual(b.displayTitle, "root@Production (1)"); XCTAssertEqual(c.displayTitle, "root@Production (2)")
        store.close(b.id)
        XCTAssertEqual(c.displayTitle, "root@Production")
    }
    @MainActor func testLocalOSCChangesRefreshAllStoreObserversAndDuplicateLabels() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let a = TerminalSession(host: nil, store: store)
        let b = TerminalSession(host: nil, store: store)
        store.sessions = [a, b]
        let base = a.title
        XCTAssertEqual(a.displayTitle, base + " (1)"); XCTAssertEqual(b.displayTitle, base + " (2)")
        var notifications = 0
        let token = store.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        let view = TerminalView(frame: .zero)
        a.setTerminalTitle(source: view, title: "Local editor")
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertEqual(a.displayTitle, "Local editor"); XCTAssertEqual(b.displayTitle, base)
        a.setTerminalTitle(source: view, title: base)
        XCTAssertEqual(a.displayTitle, base + " (1)"); XCTAssertEqual(b.displayTitle, base + " (2)")
    }
    @MainActor func testRemoteOSCDoesNotChangeConfiguredTitleOrDuplicateGroup() async throws {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var identity = VaultCredential(); identity.name = "fixture"; identity.username = "deploy"
        store.workspace.credentials = [identity]
        var host = TabbyNative.Host(); host.name = "Production"; host.address = "192.0.2.10"; host.username = "root"; host.credentialID = identity.id
        let a = TerminalSession(host: host, store: store); let b = TerminalSession(host: host, store: store)
        store.sessions = [a, b]
        let view = TerminalView(frame: .zero); view.terminalDelegate = a
        view.feed(text: "\u{1b}]0;root@internal:~\u{7}")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(a.title, "deploy@Production")
        XCTAssertEqual(a.displayTitle, "deploy@Production (1)"); XCTAssertEqual(b.displayTitle, "deploy@Production (2)")
    }
}
