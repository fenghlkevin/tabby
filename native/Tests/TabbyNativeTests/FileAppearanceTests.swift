import AppKit
import XCTest
import SwiftUI
@testable import TabbyNative

final class FileAppearanceTests: XCTestCase {
    func testPermissionsPreserveFileKindAndSpecialExecuteBits() {
        let folder = FileEntry(name: "folder", path: "/folder", directory: true, permissions: 0o755)
        let privateFile = FileEntry(name: "private", path: "/private", directory: false, permissions: 0o600)
        let link = FileEntry(name: "link", path: "/link", directory: false, symlink: true, permissions: 0o777)
        let setUID = FileEntry(name: "command", path: "/command", directory: false, permissions: 0o4750)
        let stickyWithoutExecute = FileEntry(name: "shared", path: "/shared", directory: true, permissions: 0o1666)
        XCTAssertEqual(folder.permissionDescription, "drwxr-xr-x")
        XCTAssertEqual(privateFile.permissionDescription, "-rw-------")
        XCTAssertEqual(link.permissionDescription, "lrwxrwxrwx")
        XCTAssertEqual(setUID.permissionDescription, "-rwsr-x---")
        XCTAssertEqual(stickyWithoutExecute.permissionDescription, "drw-rw-rwT")
    }

    func testBreadcrumbsNavigateExactAncestorsIncludingSpaces() {
        XCTAssertEqual(fileBreadcrumbs("/"), [])
        XCTAssertEqual(fileBreadcrumbs("/Users/Test User/My files"), [
            FileBreadcrumb(name: "Users", path: "/Users"),
            FileBreadcrumb(name: "Test User", path: "/Users/Test User"),
            FileBreadcrumb(name: "My files", path: "/Users/Test User/My files"),
        ])
    }

    func testSplitWidthsStayInsideContainerAtNarrowWidthsAndDragLimits() {
        for width: CGFloat in [0, 4, 320, 600, 900, 1600] {
            for fraction: CGFloat in [-2, 0, 0.15, 0.5, 0.9, 1, 3] {
                let metrics = FileSplitMetrics(width: width, fraction: fraction)
                XCTAssertGreaterThanOrEqual(metrics.leftWidth, 0)
                XCTAssertGreaterThanOrEqual(metrics.rightWidth, 0)
                XCTAssertEqual(metrics.leftWidth + metrics.dividerWidth + metrics.rightWidth, width, accuracy: 0.001)
                if width >= 607 {
                    XCTAssertGreaterThanOrEqual(metrics.leftWidth, 300)
                    XCTAssertGreaterThanOrEqual(metrics.rightWidth, 300)
                } else {
                    XCTAssertEqual(metrics.leftWidth, metrics.rightWidth, accuracy: 0.001)
                }
            }
        }
        let dragged = FileSplitMetrics(width: 1200, fraction: 0.65)
        XCTAssertEqual(dragged.leftWidth, (1200 - 7) * 0.65, accuracy: 0.001)
        XCTAssertLessThan(dragged.rightWidth, dragged.leftWidth)
    }

    @MainActor func testActualFileViewportsRemainBoundedDuringPickerAndEndpointChanges() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let entry = FileEntry(name: "a very long filename that must not enlarge its file pane", path: "/remote/long", directory: true)
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            FileEndpointLease(pane: FilePane(path: "/remote", backend: DropEndpoint([entry])))
        })
        defer { model.close() }
        model.local = FilePane(path: root.path, backend: LocalFiles())
        let hosting = NSHostingView(rootView: FilesView(model: model).environmentObject(store))
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func tables(in view: NSView) -> [NSScrollView] {
            let own = (view as? NSScrollView).flatMap { $0.documentView is FileNativeTable ? $0 : nil }.map { [$0] } ?? []
            return own + view.subviews.flatMap { tables(in: $0) }
        }
        func assertBounds(width: CGFloat, count: Int) async throws {
            window.setContentSize(NSSize(width: width, height: 640))
            // SwiftUI observation and the AppKit viewport layout complete on separate turns.
            for _ in 0..<50 {
                hosting.layoutSubtreeIfNeeded()
                if tables(in: hosting).count == count { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            try await Task.sleep(for: .milliseconds(30))
            hosting.layoutSubtreeIfNeeded()
            let frames = tables(in: hosting).map { $0.convert($0.bounds, to: hosting) }.sorted { $0.minX < $1.minX }
            XCTAssertEqual(frames.count, count)
            for frame in frames {
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
            }
            let metrics = FileSplitMetrics(width: width, fraction: 0.5)
            if let left = frames.first { XCTAssertEqual(left.width, metrics.leftWidth, accuracy: 1) }
            if frames.count == 2 {
                XCTAssertEqual(frames[1].width, metrics.rightWidth, accuracy: 1)
                XCTAssertEqual(frames[1].minX - frames[0].maxX, metrics.dividerWidth, accuracy: 1)
            }
        }
        try await assertBounds(width: 1100, count: 1)
        await model.selectLocal(path: root.path)
        try await assertBounds(width: 1100, count: 2)
        try await assertBounds(width: 650, count: 2)
        model.showHostPicker()
        try await assertBounds(width: 650, count: 1)
        var host = TabbyNative.Host(); host.name = "test host"; host.address = "fixture.invalid"
        await model.selectHost(host)
        try await assertBounds(width: 1300, count: 2)
        model.showHostPicker()
        try await assertBounds(width: 1300, count: 1)
        model.dismissHostPicker()
        try await assertBounds(width: 650, count: 2)
        await model.selectLocal(path: root.path)
        try await assertBounds(width: 1300, count: 2)
    }

    @MainActor func testNativeTableSelectionReloadAndPrimaryActionKeepFixedRows() throws {
        _ = NSApplication.shared
        let state = SelectionState()
        let entries = [
            FileEntry(name: "one", path: "/one", directory: true, permissions: 0o755),
            FileEntry(name: "two", path: "/two", directory: true, permissions: 0o750),
            FileEntry(name: "three", path: "/three", directory: false, permissions: 0o600),
        ]
        var opened: [String] = []
        var sorted = ""
        let binding = Binding<Set<String>>(get: { state.selected }, set: { state.selected = $0 })
        var owner = FileTableView(entries: entries, selection: binding,
                                  columnTitles: ["Name", "Modified", "Size", "Kind"], folderTitle: "Folder", linkTitle: "Link", remote: false,
                                  onOpen: { opened.append($0.path) }, onSort: { sorted = $0 }, actions: { _ in [] })
        let coordinator = FileTableCoordinator(owner)
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? FileNativeTable)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(table.style, .plain)
        XCTAssertEqual(table.rowHeight, 44)
        XCTAssertTrue(table.allowsMultipleSelection)
        XCTAssertTrue(table.delegate === coordinator)
        XCTAssertEqual(table.doubleAction, #selector(FileTableCoordinator.doubleClick(_:)))
        XCTAssertEqual(coordinator.tableView(table, heightOfRow: 0), 44)

        table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(state.selected, ["/one", "/three"])
        XCTAssertEqual(table.rowHeight, 44)
        let selectedName = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTableCellView)
        XCTAssertEqual(selectedName.textField?.textColor, .white)
        coordinator.open(row: 0)
        coordinator.open(row: -1)
        XCTAssertEqual(opened, ["/one"])
        coordinator.tableView(table, didClick: table.tableColumns[2])
        XCTAssertEqual(sorted, "size")

        // Refreshed/reordered data must restore selection by path, not row index.
        owner.entries = [entries[2], entries[1], entries[0]]
        coordinator.update(owner, in: scroll)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2]))
        XCTAssertEqual(table.style, .plain)
        XCTAssertEqual(table.rowHeight, 44)
        XCTAssertTrue(table.delegate === coordinator)
        XCTAssertEqual(coordinator.tableView(table, heightOfRow: 2), 44)
        owner.entries = [entries[1], entries[2]]
        coordinator.update(owner, in: scroll)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 1))
        XCTAssertEqual(table.rowHeight, 44)
    }

    @MainActor func testNativeDragWritersAndContextActionsUseSelectedEntries() throws {
        _ = NSApplication.shared
        let state = SelectionState()
        let entries = [FileEntry(name: "a file", path: "/a file", directory: false), FileEntry(name: "folder", path: "/folder", directory: true)]
        var received: [String] = []
        var invoked = false
        let binding = Binding<Set<String>>(get: { state.selected }, set: { state.selected = $0 })
        var owner = FileTableView(entries: entries, selection: binding,
                                  columnTitles: ["Name", "Modified", "Size", "Kind"], folderTitle: "Folder", linkTitle: "Link", remote: false,
                                  onOpen: { _ in }, onSort: { _ in }, actions: { selected in
            received = selected.map(\.path)
            return [FileTableAction(title: "Transfer", action: { invoked = true }), .divider, FileTableAction(title: "Rename", enabled: selected.count == 1, action: {})]
        })
        let coordinator = FileTableCoordinator(owner)
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? FileNativeTable)
        let localWriter = try XCTUnwrap(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSURL)
        XCTAssertEqual(localWriter.path, "/a file")
        owner.remote = true; coordinator.update(owner, in: scroll)
        XCTAssertEqual(coordinator.tableView(table, pasteboardWriterForRow: 0) as? NSString, "tabby-remote:/a file")
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: -1))
        let menu = coordinator.contextMenu(for: IndexSet([0, 1]))
        XCTAssertEqual(received, ["/a file", "/folder"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertFalse(menu.items[2].isEnabled)
        let item = menu.items[0]
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(invoked)
        _ = coordinator.contextMenu(for: [])
        XCTAssertEqual(received, [])
    }

    @MainActor func testFilteringPrunesSelectionWithoutReselectingHiddenRows() {
        let entries = [FileEntry(name: "alpha", path: "/alpha", directory: false),
                       FileEntry(name: "beta", path: "/beta", directory: false),
                       FileEntry(name: ".secret", path: "/.secret", directory: false)]
        let pane = FilePane(path: "/", backend: DropEndpoint(entries))
        pane.entries = entries
        pane.showHidden = true
        pane.selected = ["/alpha", "/.secret"]
        pane.showHidden = false
        XCTAssertEqual(pane.selected, ["/alpha"])
        XCTAssertEqual(pane.chosen.map(\.path), ["/alpha"])
        pane.showHidden = true
        XCTAssertEqual(pane.selected, ["/alpha"])
        pane.filter = "beta"
        XCTAssertTrue(pane.selected.isEmpty)
        XCTAssertTrue(pane.chosen.isEmpty)
        pane.selected = ["/beta"]
        pane.sort = "modified"
        XCTAssertEqual(pane.selected, ["/beta"])
        pane.filter = ""
        XCTAssertEqual(pane.selected, ["/beta"])
        // A directory refresh can remove a selected item without a filter change.
        pane.entries = [entries[0], entries[2]]
        XCTAssertTrue(pane.selected.isEmpty)
        XCTAssertTrue(pane.chosen.isEmpty)
    }

    @MainActor func testMultiRowRemoteDropQueuesEachProviderExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        let entries = [FileEntry(name: "first", path: "/source/first", directory: false),
                       FileEntry(name: "second", path: "/source/second", directory: false)]
        // No file system or SSH operations are performed by these endpoints.
        model.local = FilePane(path: "/destination", backend: DropEndpoint([]))
        let remotePane = FilePane(path: "/source", backend: DropEndpoint(entries))
        remotePane.entries = entries
        remotePane.selected = Set(entries.map(\.path))
        model.remote = remotePane
        defer { model.close() }
        let view = FilePaneView(pane: model.local, model: model, remote: false)
        let loaded = expectation(description: "Each dragged row provider loaded")
        loaded.expectedFulfillmentCount = entries.count
        let providers = entries.map { entry in
            let provider = NSItemProvider()
            provider.registerObject(ofClass: NSString.self, visibility: .all) { completion in
                completion(("tabby-remote:" + entry.path) as NSString, nil)
                loaded.fulfill()
                return nil
            }
            return provider
        }
        XCTAssertTrue(view.receiveDrop(providers))
        await fulfillment(of: [loaded], timeout: 3)
        for _ in 0..<100 {
            if model.queue.jobs.count >= entries.count && model.queue.runner == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let both asynchronous provider completions reach the main actor.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.queue.jobs.count, entries.count)
        XCTAssertEqual(model.queue.jobs.filter { $0.entry.path == "/source/first" }.count, 1)
        XCTAssertEqual(model.queue.jobs.filter { $0.entry.path == "/source/second" }.count, 1)
        XCTAssertTrue(model.queue.jobs.allSatisfy { $0.state == "completed" })
    }

    @MainActor func testParentRowStaysFirstAndCannotBecomeAFileOperation() throws {
        _ = NSApplication.shared
        let entries = [FileEntry(name: "alpha", path: "/one/two/alpha", directory: false, size: 1),
                       FileEntry(name: "zebra", path: "/one/two/zebra", directory: false, size: 10)]
        let pane = FilePane(path: "/one/two", backend: DropEndpoint(entries))
        pane.entries = entries
        var navigated: [String] = []
        var openedFiles: [String] = []
        var actionEntries: [String] = []
        var fileActionCalls = 0
        let binding = Binding<Set<String>>(get: { pane.selected }, set: { pane.selected = $0 })
        var owner = FileTableView(entries: pane.visible, path: pane.path, selection: binding,
                                  columnTitles: ["Name", "Modified", "Size", "Kind"], folderTitle: "Folder", linkTitle: "Link", remote: true,
                                  onOpen: { openedFiles.append($0.path) }, onParent: { navigated.append($0) }, parentTitle: "Parent folder",
                                  onSort: { pane.sort = $0 }, actions: { selected in
            fileActionCalls += 1
            actionEntries = selected.map(\.path)
            return [FileTableAction(title: "Transfer files", action: {})]
        })
        let coordinator = FileTableCoordinator(owner)
        let scroll = coordinator.makeScrollView()
        let table = try XCTUnwrap(scroll.documentView as? FileNativeTable)
        XCTAssertEqual(coordinator.rows.first, .parent(path: "/one"))
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(pane.visible.count, 2) // Parent navigation is not a real file.
        let parentCell = try XCTUnwrap(coordinator.tableView(table, viewFor: table.tableColumns[0], row: 0) as? NSTableCellView)
        XCTAssertEqual(parentCell.textField?.stringValue, "..")
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))

        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertTrue(pane.selected.isEmpty)
        XCTAssertTrue(pane.chosen.isEmpty)
        coordinator.open(row: 0)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: enter)
        XCTAssertEqual(navigated, ["/one", "/one"])
        XCTAssertTrue(openedFiles.isEmpty)
        let parentMenu = coordinator.contextMenu(for: IndexSet(integer: 0))
        XCTAssertEqual(parentMenu.items.map(\.title), ["Parent folder"])
        XCTAssertEqual(fileActionCalls, 0)

        // Mixed selections must expose only the real files to transfer/delete.
        table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        XCTAssertEqual(pane.selected, Set(entries.map(\.path)))
        XCTAssertEqual(Set(pane.chosen.map(\.path)), Set(entries.map(\.path)))
        _ = coordinator.contextMenu(for: IndexSet([0, 1, 2]))
        XCTAssertEqual(Set(actionEntries), Set(entries.map(\.path)))
        XCTAssertEqual(coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSString, "tabby-remote:/one/two/alpha")
        owner.remote = false; coordinator.update(owner, in: scroll)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))
        XCTAssertEqual((coordinator.tableView(table, pasteboardWriterForRow: 1) as? NSURL)?.path, "/one/two/alpha")
        owner.remote = true

        pane.sort = "size"
        owner.entries = pane.visible; coordinator.update(owner, in: scroll)
        XCTAssertEqual(coordinator.rows.first, .parent(path: "/one"))
        XCTAssertEqual(coordinator.rows[1].entry?.name, "zebra")
        pane.filter = "no matching files"
        owner.entries = pane.visible; coordinator.update(owner, in: scroll)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(coordinator.rows, [.parent(path: "/one")])
        XCTAssertEqual(pane.entries, entries)
        XCTAssertTrue(pane.selected.isEmpty)
        XCTAssertTrue(pane.chosen.isEmpty)
        XCTAssertNil(coordinator.tableView(table, pasteboardWriterForRow: 0))

        owner.path = "/"; coordinator.update(owner, in: scroll)
        XCTAssertTrue(coordinator.rows.isEmpty)
        XCTAssertEqual(table.numberOfRows, 0)
        XCTAssertNil(fileParentPath("/"))
        XCTAssertEqual(fileParentPath("/one"), "/")
    }

    @MainActor func testRightLocalPaneCopiesInBothDirectionsAndRefreshPreservesChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let leftURL = root.appendingPathComponent("left"), rightURL = root.appendingPathComponent("right")
        try FileManager.default.createDirectory(at: leftURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightURL, withIntermediateDirectories: true)
        let original = Data("left source".utf8)
        try original.write(to: leftURL.appendingPathComponent("forward.txt"))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        defer { model.close() }
        model.local = FilePane(path: leftURL.path, backend: LocalFiles())
        let left = model.local
        await left.navigate(left.path)
        await model.selectLocal(path: rightURL.path)
        let right = try XCTUnwrap(model.remote)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertFalse(model.showingHostPicker)
        XCTAssertTrue(model.canTransfer)
        XCTAssertTrue(model.local === left)
        left.selected = [leftURL.appendingPathComponent("forward.txt").path]
        model.transfer(true)
        await model.queue.runner?.value
        XCTAssertEqual(try Data(contentsOf: rightURL.appendingPathComponent("forward.txt")), original)
        XCTAssertEqual(model.queue.jobs.first?.direction, "copy")
        XCTAssertEqual(model.queue.jobs.first?.state, "completed")
        try Data("right source".utf8).write(to: rightURL.appendingPathComponent("back.txt"))
        await right.navigate(right.path, record: false)
        right.selected = [rightURL.appendingPathComponent("back.txt").path]
        model.transfer(false)
        await model.queue.runner?.value
        XCTAssertEqual(try Data(contentsOf: leftURL.appendingPathComponent("back.txt")), Data("right source".utf8))
        model.showHostPicker()
        XCTAssertTrue(model.showingHostPicker)
        XCTAssertFalse(model.canTransfer)
        XCTAssertEqual(model.local.path, leftURL.path)
        model.dismissHostPicker()
        await model.open() // The same method is invoked when a terminal connects.
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertTrue(model.remote === right)
        XCTAssertEqual(model.remote?.path, rightURL.path)
        XCTAssertTrue(model.local === left)
    }

    @MainActor func testLocalCopiesRejectSelfAndDescendantIncludingSymlinkAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder"), child = folder.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("item.txt")
        try Data("kept".utf8).write(to: file)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: folder.path)
        let endpoint = LocalFiles(), queue = TransferQueue()
        let fileEntry = try await endpoint.stat(file.path), folderEntry = try await endpoint.stat(folder.path)
        XCTAssertThrowsError(try queue.enqueue(fileEntry, destination: file.path, source: endpoint, target: LocalFiles(), direction: "copy"))
        XCTAssertThrowsError(try queue.enqueue(fileEntry, destination: alias.appendingPathComponent("item.txt").path, source: endpoint, target: LocalFiles(), direction: "copy"))
        XCTAssertThrowsError(try queue.enqueue(folderEntry, destination: child.appendingPathComponent("folder").path, source: endpoint, target: LocalFiles(), direction: "copy"))
        XCTAssertThrowsError(try queue.enqueue(folderEntry, destination: alias.appendingPathComponent("child/folder").path, source: endpoint, target: LocalFiles(), direction: "copy"))
        XCTAssertTrue(queue.jobs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("kept".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: child.appendingPathComponent("folder").path))
    }

    @MainActor func testHostSwitchPreservesQueuedEndpointsAndDefersTheirRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("pending.txt"))
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let gate = AsyncGate()
        let originalEndpoint = GatedEndpoint(gate: gate)
        let replacementEndpoint = DropEndpoint([])
        var released = 0, opened = 0
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            opened += 1
            let endpoint: any FileEndpoint = opened == 1 ? originalEndpoint : replacementEndpoint
            return FileEndpointLease(pane: FilePane(path: "/remote", backend: endpoint), release: { released += 1 })
        })
        defer { model.close() }
        model.local = FilePane(path: root.path, backend: LocalFiles())
        await model.local.navigate(root.path)
        let left = model.local
        var host = TabbyNative.Host(); host.name = "test host"; host.address = "fixture.invalid"
        await model.selectHost(host)
        let originalRight = try XCTUnwrap(model.remote)
        model.local.selected = [root.appendingPathComponent("pending.txt").path]
        model.transfer(true)
        for _ in 0..<100 { if await originalEndpoint.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        let started = await originalEndpoint.started
        XCTAssertTrue(started)
        let job = try XCTUnwrap(model.queue.jobs.first)
        await model.selectLocal(path: root.path)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertEqual(released, 0) // Old endpoint remains alive for the pending job.
        await model.selectHost(host)
        XCTAssertFalse(model.rightIsLocal)
        XCTAssertTrue(model.local === left)
        XCTAssertFalse(model.remote === originalRight)
        XCTAssertTrue((job.target as AnyObject) === originalEndpoint)
        XCTAssertEqual(job.destination, "/remote/pending.txt")
        await gate.resume()
        await model.queue.runner?.value
        for _ in 0..<100 { if released == 1 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(job.state, "completed")
        XCTAssertEqual(released, 1)
    }

    @MainActor func testStaleHostConnectionCannotReplaceNewLocalChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let gate = AsyncGate()
        var released = 0, started = false
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store), remoteOpener: { _ in
            started = true
            await gate.wait()
            return FileEndpointLease(pane: FilePane(path: "/remote", backend: DropEndpoint([])), release: { released += 1 })
        })
        defer { model.close() }
        model.local = FilePane(path: root.path, backend: LocalFiles())
        var host = TabbyNative.Host(); host.address = "fixture.invalid"
        let pending = Task { await model.selectHost(host) }
        while !started { await Task.yield() }
        await model.selectLocal(path: root.path)
        let localRight = model.remote
        await gate.resume()
        await pending.value
        await model.open()
        XCTAssertEqual(released, 1)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertTrue(model.remote === localRight)
        XCTAssertNil(model.rightHost)
        XCTAssertFalse(model.showingHostPicker)
        let right = try XCTUnwrap(model.remote)
        right.busy = true
        model.showHostPicker()
        await model.selectHost(host)
        await model.selectLocal(path: root.path)
        XCTAssertTrue(model.remote === right)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertFalse(model.showingHostPicker)
        right.busy = false
        model.showHostPicker()
        XCTAssertTrue(model.showingHostPicker)
    }

    @MainActor func testDelayedRemoteDropIsRejectedAfterEndpointSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        defer { model.close() }
        let entry = FileEntry(name: "one", path: "/remote/one", directory: false)
        let remote = FilePane(path: "/remote", backend: DropEndpoint([entry]))
        remote.entries = [entry]; model.remote = remote
        model.local = FilePane(path: root.path, backend: DropEndpoint([]))
        let callbackGate = AsyncGate()
        let began = expectation(description: "Provider load starts")
        let delivered = expectation(description: "Provider data delivered")
        let provider = NSItemProvider()
        provider.registerObject(ofClass: NSString.self, visibility: .all) { completion in
            began.fulfill()
            Task {
                await callbackGate.wait()
                completion("tabby-remote:/remote/one" as NSString, nil)
                delivered.fulfill()
            }
            return nil
        }
        let view = FilePaneView(pane: model.local, model: model, remote: false)
        XCTAssertTrue(view.receiveDrop([provider]))
        await fulfillment(of: [began], timeout: 3)
        await model.selectLocal(path: root.path)
        await callbackGate.resume()
        await fulfillment(of: [delivered], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.queue.jobs.isEmpty)
        XCTAssertTrue(model.rightIsLocal)
    }

    @MainActor func testLoopbackHostLocalHostTransitionKeepsLeftPane() async throws {
        guard let path = ProcessInfo.processInfo.environment["TABBY_TEST_SERVER"] else { throw XCTSkip("Loopback fixture required") }
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(fileURL: root.appendingPathComponent("workspace.json"))
        var host = TabbyNative.Host(); host.name = "loopback"; host.address = "127.0.0.1"; host.port = info["port"] as! Int
        host.username = "test"; host.auth = "key"; host.keyPath = info["clientKey"] as! String
        store.workspace.trustedKeys["127.0.0.1:\(host.port)"] = info["hostKey"] as? String
        let model = FileManagerModel(session: TerminalSession(host: nil, store: store))
        defer { model.close() }
        model.local = FilePane(path: root.path, backend: LocalFiles())
        let left = model.local
        await model.selectHost(host)
        XCTAssertTrue(model.remote?.backend is RemoteFiles, model.status)
        XCTAssertTrue(model.remote?.entries.contains { $0.name == "client-key" } == true)
        XCTAssertEqual(store.sessions.count, 0) // No terminal/tab was created or switched.
        let initialRemote = try XCTUnwrap(model.remote)
        let initialEndpoint = try XCTUnwrap(initialRemote.backend as? RemoteFiles)
        try await initialEndpoint.sftp.close()
        await model.open()
        XCTAssertFalse(model.remote === initialRemote)
        XCTAssertEqual(model.remote?.path, initialRemote.path)
        XCTAssertTrue(model.remote?.entries.contains { $0.name == "client-key" } == true, model.status)
        await model.selectLocal(path: root.path)
        XCTAssertTrue(model.rightIsLocal)
        XCTAssertTrue(model.remote?.backend is LocalFiles)
        await model.open()
        XCTAssertTrue(model.rightIsLocal)
        await model.selectHost(host)
        XCTAssertFalse(model.rightIsLocal)
        XCTAssertTrue(model.remote?.backend is RemoteFiles, model.status)
        XCTAssertTrue(model.remote?.entries.contains { $0.name == "client-key" } == true)
        XCTAssertTrue(model.local === left)
        XCTAssertEqual(model.local.path, root.path)
    }

    @MainActor private final class SelectionState { var selected = Set<String>() }

    private actor AsyncGate {
        private var opened = false
        private var waiting: CheckedContinuation<Void, Never>?
        func wait() async { if !opened { await withCheckedContinuation { waiting = $0 } } }
        func resume() { opened = true; waiting?.resume(); waiting = nil }
    }

    private actor GatedEndpoint: FileEndpoint {
        let gate: AsyncGate
        private(set) var started = false
        init(gate: AsyncGate) { self.gate = gate }
        func list(_ path: String) -> [FileEntry] { [] }
        func stat(_ path: String) throws -> FileEntry { throw FileMissing(path) }
        func mkdir(_ path: String) {}
        func rename(_ from: String, _ to: String) {}
        func delete(_ entry: FileEntry) {}
        func chmod(_ path: String, _ mode: UInt32) {}
        func read(_ path: String, offset: UInt64, count: Int) -> Data { Data() }
        func write(_ path: String, offset: UInt64, bytes: Data) async { started = true; await gate.wait() }
    }

    private actor DropEndpoint: FileEndpoint {
        let entries: [FileEntry]
        init(_ entries: [FileEntry]) { self.entries = entries }
        func list(_ path: String) -> [FileEntry] { entries }
        func stat(_ path: String) throws -> FileEntry { throw FileMissing(path) }
        func mkdir(_ path: String) {}
        func rename(_ from: String, _ to: String) {}
        func delete(_ entry: FileEntry) {}
        func chmod(_ path: String, _ mode: UInt32) {}
        func read(_ path: String, offset: UInt64, count: Int) -> Data { Data() }
        func write(_ path: String, offset: UInt64, bytes: Data) {}
    }
}
