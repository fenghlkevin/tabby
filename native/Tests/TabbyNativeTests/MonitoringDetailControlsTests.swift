import XCTest
import SwiftUI
import AppKit
@testable import TabbyNative

@MainActor final class MonitoringDetailControlsTests: XCTestCase {
    func testMountGroupingKeepsDataVolumesAndAllHiddenRecords() {
        let disks = [disk("/opt", "xfs"), disk("/run", "tmpfs"), disk("/", "ext4"), disk("/opt/docker/very-long-overlay", "overlay"), disk("/mnt/shared", "nfs"), disk("/unclassified", nil)]
        let volumes = MonitoringStoragePresentation.volumes(disks, system: false)
        let system = MonitoringStoragePresentation.volumes(disks, system: true)
        XCTAssertEqual(volumes.map(\.mountpoint), ["/", "/mnt/shared", "/opt", "/unclassified"])
        XCTAssertEqual(Set(system.map(\.mountpoint)), ["/run", "/opt/docker/very-long-overlay"])
        XCTAssertEqual(Set((volumes + system).map(\.id)), Set(disks.map(\.id)))
        XCTAssertEqual(MonitoringStoragePresentation.volumes([disk("/", "overlay"), disk("/opt/docker/overlay", "overlay")], system: false).map(\.mountpoint), ["/"])
    }

    func testRunningFilterUsesDockerStateAndPreservesAllWhenDisabled() {
        let containers = [container("run", "running"), container("stop", "exited"), container("new", "created"), container("pause", "paused"), container("restart", "restarting"), container("dead", "dead"), container("remove", "removing")]
        XCTAssertEqual(MonitoringContainerPresentation.visible(containers, hideNotRunning: false), containers)
        XCTAssertEqual(MonitoringContainerPresentation.visible(containers, hideNotRunning: true).map(\.id), ["run"])
        var statusOnly = container("false-up", "paused"); statusOnly.status = "Up 2 weeks"
        XCTAssertFalse(MonitoringContainerPresentation.isRunning(statusOnly))
        XCTAssertTrue(MonitoringContainerPresentation.isRunning(container("normalized", " RUNNING\n")))
    }

    func testNetworkPresentationRetainsDownLoopbackAndAddressOnlyInterfaces() {
        let interfaces = [interface("lo", "UNKNOWN", ["127.0.0.1/8", "::1/128"]), interface("eth0", "UP", ["10.2.3.4/24", "2001:db8:1234:5678::1/64"]), interface("br-docker", "DOWN", ["172.18.0.1/16"])]
        XCTAssertEqual(MonitoringNetworkPresentation.interfaces(interfaces).map(\.name), ["br-docker", "eth0", "lo"])
        for interface in interfaces { XCTAssertEqual(MonitoringNetworkPresentation.interfaces(interfaces).first { $0.id == interface.id }, interface) }
        XCTAssertEqual(MonitoringNetworkPresentation.version("::1/128"), "IPv6")
        XCTAssertEqual(MonitoringNetworkPresentation.version("10.2.3.4/24"), "IPv4")
    }

    func testStorageFullWidthGridAndLongMountCopyStayCompact() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var snapshot = fixture.snapshot
        let long = "/opt/docker/rootfs/overlayfs/" + String(repeating: "123456789abcdef", count: 8)
        snapshot.disks = [disk("/", "ext4"), disk("/opt", "xfs"), disk(long, "overlay")] + (0..<8).map { disk("/run/user/\($0)", "tmpfs") }
        snapshot.diskIO = (0..<3).map { MonitoringDiskIO(device: "vd\($0)", readBytesPerSecond: 300, writeBytesPerSecond: 400, readIOPS: 1, writeIOPS: 2, utilizationPercent: 4) }
        for width: CGFloat in [650, 1100] {
            let hosting = NSHostingView(rootView: ScrollView { MonitoringStorageView(snapshot: snapshot).padding(22) }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 900)); defer { window.close() }
            try await settle(hosting)
            let texts = nodes(hosting).map(\.text).joined(separator: " | ")
            XCTAssertTrue(texts.contains("Storage volumes")); XCTAssertTrue(texts.contains("Disk I/O"))
            XCTAssertTrue(texts.contains("System and container mounts (9)"))
            XCTAssertFalse(texts.contains(long), "System and container mount cards start collapsed")
            try captureAndAudit(hosting, name: "monitor-storage-\(Int(width))")
        }
        let pasteboard = NSPasteboard(name: .init("axon-test-mount-" + UUID().uuidString)); defer { pasteboard.releaseGlobally() }
        let hosting = NSHostingView(rootView: MonitoringVolumeCard(disk: disk(long, "overlay"), pasteboard: pasteboard).padding(14).background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
        let window = show(hosting, size: NSSize(width: 340, height: 220)); defer { window.close() }
        try await settle(hosting)
        let path = try XCTUnwrap(nodes(hosting).first { $0.role == .staticText && $0.text == long })
        XCTAssertLessThanOrEqual(path.frame.height, 22, "Long paths must remain a single compact line")
        XCTAssertTrue(path.read("accessibilityHelp") as? String == long)
        let copy = try XCTUnwrap(nodes(hosting).first { $0.role == .button && $0.text == "Copy mount path: " + long })
        XCTAssertTrue(copy.press())
        XCTAssertEqual(pasteboard.string(forType: .string), long, "Copy must preserve the entire untruncated path")
        try captureAndAudit(hosting, name: "monitor-long-mount-copy-340")
    }

    func testAllNetworkInterfaceCardsAndAddressesShowWithoutPicker() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var snapshot = fixture.snapshot
        snapshot.trafficHistory = nil
        snapshot.interfaces = [interface("eth0", "UP", ["10.2.3.4/24", "2001:db8:1234:5678:90ab:cdef:1234:5678/64"]), interface("eth1", "DOWN", ["192.168.2.1/24"]), interface("br-docker", "DOWN", ["172.18.0.1/16"]), interface("lo", "UNKNOWN", ["127.0.0.1/8", "::1/128"])]
        let entry = MonitoringEntry(id: MonitoringTargetID(address: "fixture.invalid", port: 22, username: "qa"), label: "Fixture", address: "fixture.invalid", group: "", isConnected: true)
        for width: CGFloat in [650, 1100] {
            let hosting = NSHostingView(rootView: ScrollView { MonitoringNetworkView(snapshot: snapshot, entry: entry).padding(22) }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
            let window = show(hosting, size: NSSize(width: width, height: 1400)); defer { window.close() }
            try await settle(hosting)
            let content = nodes(hosting)
            let text = content.map(\.text).joined(separator: " | ")
            for item in snapshot.interfaces {
                XCTAssertTrue(text.contains(item.name), "Every NIC must be present simultaneously")
                for address in item.addresses { XCTAssertTrue(text.contains(address), "Missing address \(address) on \(item.name)") }
            }
            XCTAssertFalse(content.contains { $0.role == .popUpButton }, "Network interfaces must not be hidden behind a picker")
            try captureAndAudit(hosting, name: "monitor-all-interfaces-\(Int(width))")
        }
    }

    func testDockerCheckboxActuallyFiltersAndCanRestoreAllContainers() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var snapshot = fixture.snapshot
        snapshot.containers = [container("Running container", "running"), container("Stopped container", "exited"), container("Paused container", "paused"), container("Restarting container", "restarting")]
        snapshot.availability["containerStats"] = "Available"
        let hosting = NSHostingView(rootView: ScrollView { MonitoringDockerView(snapshot: snapshot).padding(22) }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
        let window = show(hosting, size: NSSize(width: 1100, height: 1100)); defer { window.close() }
        try await settle(hosting)
        let before = nodes(hosting).map(\.text).joined(separator: " | ")
        for container in snapshot.containers { XCTAssertTrue(before.contains("Container details: " + container.name)) }
        let checkbox = try XCTUnwrap(nodes(hosting).first { $0.role == .checkBox && $0.text.contains("Hide not running") })
        XCTAssertTrue(checkbox.press()); try await settle(hosting)
        let after = nodes(hosting).map(\.text).joined(separator: " | ")
        XCTAssertTrue(after.contains("Container details: Running container"))
        for name in ["Stopped", "Paused", "Restarting"] { XCTAssertFalse(after.contains("Container details: \(name) container")) }
        try captureAndAudit(hosting, name: "monitor-docker-filter-running-1100")
        let restoreCheckbox = try XCTUnwrap(nodes(hosting).first { $0.role == .checkBox && $0.text.contains("Hide not running") })
        XCTAssertTrue(restoreCheckbox.press()); try await settle(hosting)
        let restored = nodes(hosting).map(\.text).joined(separator: " | ")
        for container in snapshot.containers { XCTAssertTrue(restored.contains("Container details: " + container.name)) }
        snapshot.containers.removeAll { $0.state == "running" }
        let stoppedHosting = NSHostingView(rootView: ScrollView { MonitoringDockerView(snapshot: snapshot).padding(22) }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(fixture.store).preferredColorScheme(.light))
        let stoppedWindow = show(stoppedHosting, size: NSSize(width: 650, height: 900)); defer { stoppedWindow.close() }
        try await settle(stoppedHosting)
        let stoppedCheckbox = try XCTUnwrap(nodes(stoppedHosting).first { $0.role == .checkBox && $0.text.contains("Hide not running") })
        XCTAssertTrue(stoppedCheckbox.press()); try await settle(stoppedHosting)
        let empty = nodes(stoppedHosting).map(\.text).joined(separator: " | ")
        XCTAssertTrue(empty.contains("No running containers"))
        XCTAssertTrue(empty.contains("Hide not running"), "The filter remains reachable when it hides every container")
        try captureAndAudit(stoppedHosting, name: "monitor-docker-filter-empty-650")
    }

    private func disk(_ path: String, _ filesystem: String?) -> MonitoringDisk { MonitoringDisk(device: "/dev/vda", mountpoint: path, filesystem: filesystem, totalBytes: 100_000, usedBytes: 40_000, availableBytes: 60_000, usedPercent: 40) }
    private func interface(_ name: String, _ state: String, _ addresses: [String]) -> MonitoringInterface { MonitoringInterface(name: name, addresses: addresses, state: state, receivedBytes: 600, transmittedBytes: 700, receiveBytesPerSecond: 80, transmitBytesPerSecond: 90) }
    private func container(_ id: String, _ state: String) -> MonitoringContainer { MonitoringContainer(id: id, name: id, image: "fixture/image", state: state, status: state, health: nil, restartCount: nil, pid: nil, startedAt: nil, cpuPercent: nil, memoryUsedBytes: nil, memoryLimitBytes: nil, memoryPercent: nil, networkReceivedBytes: nil, networkTransmittedBytes: nil, blockReadBytes: nil, blockWrittenBytes: nil, pids: nil) }
    private func makeFixture() throws -> (directory: URL, store: AppStore, snapshot: MonitoringSnapshot) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-detail-" + UUID().uuidString)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json")); store.workspace.preferences.language = "en-US"
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let raw = try String(contentsOf: native.appendingPathComponent("scripts/fixtures/monitoring-linux.txt"), encoding: .utf8)
        return (directory, store, try MonitoringSampleParser.parse(raw: raw, previous: nil, timestamp: Date(timeIntervalSince1970: 1_791_032_400)))
    }
    private struct Node {
        let element: NSObject
        func read(_ key: String) -> Any? { element.responds(to: NSSelectorFromString(key)) ? element.value(forKey: key) : nil }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        // SwiftUI exposes static text through AXValue; button titles generally
        // use AXLabel. An empty AXLabel must not mask either of those values.
        var text: String {
            [read("accessibilityLabel") as? String, read("accessibilityTitle") as? String, read("accessibilityValue") as? String]
                .compactMap { $0 }.first { !$0.isEmpty } ?? ""
        }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard element.responds(to: selector) else { return false }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(element.method(for: selector), to: Press.self)(element, selector)
        }
    }
    private func nodes(_ root: NSView) -> [Node] {
        var found: [Node] = [], seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, _ depth: Int) {
            guard depth < 50, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(element: object); found.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth + 1) } }
        }
        visit(root, 0); return found
    }
    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key); NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }
    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }
    private func settle(_ hosting: NSView) async throws { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); hosting.layoutSubtreeIfNeeded(); hosting.displayIfNeeded() }
    private func captureAndAudit(_ hosting: NSView, name: String) throws {
        let window = try XCTUnwrap(hosting.window)
        let viewport = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))
        let content = nodes(hosting)
        let leaves: Set<NSAccessibility.Role> = [.staticText, .button, .checkBox, .popUpButton]
        for node in content where node.role.map(leaves.contains) == true {
            let frame = node.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(viewport) else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, "\(name): \(node.text) overflows left")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, "\(name): \(node.text) overflows right")
        }
        let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-details")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)); hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        try content.map { "\($0.role?.rawValue ?? "?")\t\($0.frame)\t\($0.text)" }.joined(separator: "\n").write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
}
