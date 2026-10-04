import XCTest
import AppKit
import SwiftUI
@testable import TabbyNative

/// Measures the real card surfaces in native windows, including their AX
/// descendants. Fixtures are parsed locally; no terminal or SSH is started.
@MainActor final class MonitoringResourceEqualHeightTests: XCTestCase {
    func testResourceSurfacesAlignByRowWithoutClippingFirstSampleOrPartialData() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(); defer { try? FileManager.default.removeItem(at: fixture.directory) }
        XCTAssertNil(fixture.first.cpu?.usagePercent, "The first sample must exercise the waiting-rate content")
        XCTAssertNotNil(fixture.sampled.cpu?.usagePercent)
        let model = try XCTUnwrap(fixture.first.cpuModel)

        var withoutModel = fixture.sampled; withoutModel.cpuModel = nil
        var withoutMemory = fixture.sampled; withoutMemory.memory = nil
        withoutMemory.availability["memory"] = "Memory counters are unavailable for this synthetic sample."
        let variants: [(name: String, snapshot: MonitoringSnapshot, history: [MonitoringSnapshot])] = [
            ("first-sample", fixture.first, [fixture.first]),
            ("load-trend", fixture.sampled, [fixture.first, fixture.sampled]),
            ("no-cpu-model", withoutModel, [fixture.first, withoutModel]),
            ("missing-memory", withoutMemory, [fixture.first, withoutMemory]),
        ]

        for variant in variants {
            for width: CGFloat in [650, 850, 1100, 1400] {
                let hosting = resources(variant.snapshot, history: variant.history, store: fixture.store)
                let window = show(hosting, size: NSSize(width: width, height: 1400)); defer { window.close() }
                try await settle(hosting)
                let name = "monitor-resource-\(variant.name)-\(Int(width))"
                try captureAndAudit(hosting, name: name)
                let cards = try assertCardRows(in: hosting, width: width)
                try assertResourceContent(variant.snapshot, history: variant.history, cards: cards)
                assertCardContentsStayInsideSurfaces(cards)

                if variant.snapshot.cpuModel == nil {
                    XCTAssertFalse(nodes(cards.cpu.object).contains { $0.text.contains(model) }, "An absent CPU model must not leave stale content")
                }
                if width <= 850, variant.snapshot.memory == nil {
                    XCTAssertLessThan(cards.memory.frame.height, cards.cpu.frame.height - 20,
                                      "Separate rows should size to their own content instead of adopting one global card height")
                }
            }
        }
        assertFixtureIsolation(fixture)
    }

    func testExpandedSixteenCoresKeepEqualRowSurfacesAndRemainReachableAfterResize() async throws {
        _ = NSApplication.shared
        let restore = enableAccessibility(); defer { restore() }
        let fixture = try makeFixture(name: "monitoring-linux-16cores")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cpu = try XCTUnwrap(fixture.sampled.cpu)
        XCTAssertEqual(cpu.cores.count, 16)
        let history = [fixture.first, fixture.sampled]
        let hosting = resources(fixture.sampled, history: history, store: fixture.store)
        let window = show(hosting, size: NSSize(width: 1400, height: 900)); defer { window.close() }
        try await settle(hosting)
        let collapsed = try assertCardRows(in: hosting, width: 1400)
        let collapsedHeight = collapsed.cpu.frame.height
        XCTAssertFalse(nodes(collapsed.cpu.object).contains { isCoreLabel($0.text, id: 0) })
        try captureAndAudit(hosting, name: "monitor-resource-16cores-collapsed-1400")

        let disclosure = try XCTUnwrap(nativeViews(NSButton.self, in: hosting).first { $0.identifier?.rawValue == "axon-cpu-cores" })
        disclosure.performClick(nil)
        try await settle(hosting)
        XCTAssertEqual(Node(object: disclosure).read("accessibilityValue") as? String, "Expanded")

        // Keep the same view and disclosure state while changing the available
        // column width. This also checks that reflow does not drop core rows.
        for (index, width) in ([CGFloat(1400), 1100, 850, 650, 1400]).enumerated() {
            window.setContentSize(NSSize(width: width, height: 900))
            try await settle(hosting)
            try await reveal(Node(object: disclosure), in: hosting)
            let cards = try assertCardRows(in: hosting, width: width)
            XCTAssertGreaterThan(cards.cpu.frame.height, collapsedHeight + 500,
                                 "Expansion must grow the card surface enough to retain all sixteen core rows")
            try assertResourceContent(fixture.sampled, history: history, cards: cards)
            for core in cpu.cores {
                let meter = try coreNode(core.id, in: cards.cpu)
                assertContained(meter.frame, by: cards.cpu.frame, message: "Core \(core.id) meter")
                try assertText("User \(MonitoringPresentation.percentage(core.userPercent)) · System \(MonitoringPresentation.percentage(core.systemPercent))", in: cards.cpu)
            }
            assertCardContentsStayInsideSurfaces(cards)
            let name = "monitor-resource-16cores-expanded-\(Int(width))-\(index)"
            try captureAndAudit(hosting, name: name)

            try await reveal(try coreNode(15, in: cards.cpu), in: hosting)
            let scrolled = try resourceCards(in: hosting)
            assertVisible(try coreNode(15, in: scrolled.cpu), in: hosting)
            try captureAndAudit(hosting, name: name + "-last-core")
            if width <= 850 {
                try await reveal(try textNode("Uptime", in: scrolled.load), in: hosting)
                assertVisible(try textNode("Uptime", in: try resourceCards(in: hosting).load), in: hosting)
                try await reveal(try textNode("Swap", in: try resourceCards(in: hosting).memory), in: hosting)
                assertVisible(try textNode("Swap", in: try resourceCards(in: hosting).memory), in: hosting)
                try captureAndAudit(hosting, name: name + "-memory-bottom")
            }
        }

        try await reveal(Node(object: disclosure), in: hosting)
        disclosure.performClick(nil)
        try await settle(hosting)
        let restored = try assertCardRows(in: hosting, width: 1400)
        XCTAssertEqual(Node(object: disclosure).read("accessibilityValue") as? String, "Collapsed")
        XCTAssertFalse(nodes(restored.cpu.object).contains { isCoreLabel($0.text, id: 0) })
        XCTAssertEqual(restored.cpu.frame.height, collapsedHeight, accuracy: 2,
                       "Collapsing must remove the expanded height instead of preserving a stale row measurement")
        try captureAndAudit(hosting, name: "monitor-resource-16cores-restored-1400")
        assertFixtureIsolation(fixture)
    }

    private struct Fixture {
        let directory: URL
        let store: AppStore
        let first: MonitoringSnapshot
        let sampled: MonitoringSnapshot
    }

    private func makeFixture(name: String = "monitoring-linux") throws -> Fixture {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = native.appendingPathComponent("scripts/fixtures")
        let firstRaw = try String(contentsOf: fixtures.appendingPathComponent(name + ".txt"), encoding: .utf8)
        let nextRaw = try String(contentsOf: fixtures.appendingPathComponent(name + "-next.txt"), encoding: .utf8)
        let date = Date(timeIntervalSince1970: 1_791_032_400)
        let first = try MonitoringSampleParser.parse(raw: firstRaw, previous: nil, timestamp: date.addingTimeInterval(-5))
        let sampled = try MonitoringSampleParser.parse(raw: nextRaw, previous: first, timestamp: date)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-resource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = AppStore(fileURL: directory.appendingPathComponent("workspace.json"))
        store.workspace.preferences.language = "en-US"
        return Fixture(directory: directory, store: store, first: first, sampled: sampled)
    }

    private func assertFixtureIsolation(_ fixture: Fixture) {
        XCTAssertTrue(fixture.store.sessions.isEmpty, "Resource views must not initialize a terminal or SSH client")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path), "Rendering and expanding resource cards must not write workspace configuration")
    }

    private func resources(_ snapshot: MonitoringSnapshot, history: [MonitoringSnapshot], store: AppStore) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(ScrollView {
            MonitoringResourcesView(snapshot: snapshot, history: history).padding(22)
        }.background(Palette.background).foregroundStyle(Palette.text).environmentObject(store).preferredColorScheme(.light)))
    }

    private struct Cards {
        let cpu: Node
        let load: Node
        let memory: Node
        var all: [Node] { [cpu, load, memory] }
    }

    private func resourceCards(in root: NSView) throws -> Cards {
        let content = nodes(root)
        func card(_ identifier: String) throws -> Node {
            try XCTUnwrap(content.first { $0.identifier == identifier && $0.frame.width > 100 && $0.frame.height > 0 }, "Missing outer resource card surface: \(identifier)")
        }
        return try Cards(cpu: card("axon-resource-cpu"), load: card("axon-resource-load"), memory: card("axon-resource-memory"))
    }

    @discardableResult private func assertCardRows(in root: NSView, width: CGFloat) throws -> Cards {
        let cards = try resourceCards(in: root)
        for card in cards.all {
            XCTAssertGreaterThan(card.frame.height, 60)
            let siblings = cards.all.filter { abs($0.frame.maxY - card.frame.maxY) <= 1 }
            for sibling in siblings {
                XCTAssertEqual(sibling.frame.maxY, card.frame.maxY, accuracy: 1, "Same-row outer top edges must align")
                XCTAssertEqual(sibling.frame.minY, card.frame.minY, accuracy: 1, "Same-row outer bottom edges must align")
                XCTAssertEqual(sibling.frame.height, card.frame.height, accuracy: 1, "Same-row resource surfaces must have equal height")
            }
            let expectedSiblings = width == 650 ? 1 : (width == 850 ? (card.identifier == "axon-resource-memory" ? 1 : 2) : 3)
            XCTAssertEqual(siblings.count, expectedSiblings,
                           "Resource cards must use one column at 650, two at 850, and three at 1100/1400 points")
        }
        if width == 650 {
            XCTAssertLessThan(cards.load.frame.maxY, cards.cpu.frame.minY)
            XCTAssertLessThan(cards.memory.frame.maxY, cards.load.frame.minY)
        } else if width == 850 {
            XCTAssertEqual(cards.cpu.frame.maxY, cards.load.frame.maxY, accuracy: 1)
            XCTAssertEqual(cards.cpu.frame.minY, cards.load.frame.minY, accuracy: 1)
            XCTAssertLessThan(cards.cpu.frame.maxX, cards.load.frame.minX)
            XCTAssertLessThan(cards.memory.frame.maxY, cards.cpu.frame.minY,
                              "Memory must size independently in its own second row")
        } else {
            XCTAssertLessThan(cards.cpu.frame.maxX, cards.load.frame.minX)
            XCTAssertLessThan(cards.load.frame.maxX, cards.memory.frame.minX)
        }
        return cards
    }

    private func assertResourceContent(_ snapshot: MonitoringSnapshot, history: [MonitoringSnapshot], cards: Cards) throws {
        try assertText("CPU", in: cards.cpu)
        try assertText("Usage", in: cards.cpu)
        if let model = snapshot.cpuModel { try assertText(model, in: cards.cpu) }
        if let architecture = snapshot.architecture { try assertText(architecture, in: cards.cpu) }
        if snapshot.cpu?.usagePercent == nil { try assertText("Rate requires two samples.", in: cards.cpu) }
        else { XCTAssertFalse(nodes(cards.cpu.object).contains { $0.text.contains("Rate requires two samples.") }) }
        try assertText("Nice ", in: cards.cpu)
        try assertText("Logical cores (\(snapshot.cpu?.cores.count ?? 0))", in: cards.cpu)

        try assertText("1 / 5 / 15 minutes", in: cards.load)
        if let load = snapshot.load {
            try assertText("\(MonitoringPresentation.number(load.oneMinute)) / \(MonitoringPresentation.number(load.fiveMinutes)) / \(MonitoringPresentation.number(load.fifteenMinutes))", in: cards.load)
        }
        let points = MonitoringPresentation.trendSamples(history.compactMap { sample in
            sample.load.map { MonitoringTrendPoint(timestamp: sample.timestamp, value: $0.oneMinute) }
        })
        if points.count > 1 {
            try assertText("Recent one-minute load samples", in: cards.load)
            try assertText("Latest \(points.count) samples", in: cards.load)
            XCTAssertFalse(nodes(cards.load.object).contains { $0.text.contains("Trend appears after multiple samples.") })
        } else { try assertText("Trend appears after multiple samples.", in: cards.load) }
        try assertText("Logical cores", in: cards.load)
        try assertText("Uptime", in: cards.load)

        try assertText("Memory", in: cards.memory)
        if let memory = snapshot.memory {
            for label in ["Used / total", "Available", "Free", "Cache / buffers", "Swap"] { try assertText(label, in: cards.memory) }
            try assertText("\(MonitoringPresentation.bytes(memory.usedBytes)) / \(MonitoringPresentation.bytes(memory.totalBytes))", in: cards.memory)
            try assertText("\(MonitoringPresentation.bytes(memory.swapUsedBytes)) / \(MonitoringPresentation.bytes(memory.swapTotalBytes))", in: cards.memory)
        } else {
            try assertText("Unavailable", in: cards.memory)
            try assertText(try XCTUnwrap(snapshot.availability["memory"]), in: cards.memory)
        }
    }

    private func textNode(_ text: String, in card: Node) throws -> Node {
        let matches = nodes(card.object).dropFirst().filter { $0.text.contains(text) && $0.frame.width > 0 && $0.frame.height > 0 }
        return try XCTUnwrap(matches.first { $0.role == .staticText || $0.role == .button } ?? matches.first,
                             "Missing readable content '\(text)' inside \(card.identifier ?? "resource card")")
    }

    private func assertText(_ text: String, in card: Node) throws {
        let node = try textNode(text, in: card)
        assertContained(node.frame, by: card.frame, message: text)
    }

    private func isCoreLabel(_ text: String, id: Int) -> Bool {
        let prefix = "Core \(id)"
        guard text.hasPrefix(prefix) else { return false }
        let suffix = text.dropFirst(prefix.count)
        return suffix.isEmpty || suffix.first?.isNumber == false
    }

    private func coreNode(_ id: Int, in card: Node) throws -> Node {
        try XCTUnwrap(nodes(card.object).dropFirst().first { isCoreLabel($0.text, id: id) && $0.frame.width > 0 && $0.frame.height > 0 }, "Missing readable Core \(id) after expansion")
    }

    private func assertCardContentsStayInsideSurfaces(_ cards: Cards) {
        for card in cards.all {
            let descendants = nodes(card.object).dropFirst().filter { !$0.text.isEmpty && $0.frame.width > 0 && $0.frame.height > 0 }
            XCTAssertGreaterThan(descendants.count, 2, "Card audits need real accessible descendants")
            for node in descendants { assertContained(node.frame, by: card.frame, message: "\(card.identifier ?? ""): \(node.text)") }
        }
    }

    private func assertContained(_ frame: NSRect, by outer: NSRect, message: String) {
        XCTAssertGreaterThanOrEqual(frame.minX, outer.minX - 1, message + " overflows left")
        XCTAssertLessThanOrEqual(frame.maxX, outer.maxX + 1, message + " overflows right")
        XCTAssertGreaterThanOrEqual(frame.minY, outer.minY - 1, message + " is clipped at the card bottom")
        XCTAssertLessThanOrEqual(frame.maxY, outer.maxY + 1, message + " is clipped at the card top")
    }

    private func reveal(_ node: Node, in root: NSView) async throws {
        let window = try XCTUnwrap(root.window)
        let scroll = try XCTUnwrap(nativeViews(NSScrollView.self, in: root).first { ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height + 1 }, "Expanded resource content must have a native vertical scroll surface")
        let document = try XCTUnwrap(scroll.documentView)
        let target = document.convert(window.convertFromScreen(node.frame), from: nil)
        _ = document.scrollToVisible(target.insetBy(dx: -2, dy: -2))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(root)
    }

    private func assertVisible(_ node: Node, in root: NSView) {
        guard let window = root.window else { XCTFail("Expected a native window"); return }
        let viewport = window.convertToScreen(root.convert(root.bounds, to: nil))
        assertContained(node.frame, by: viewport, message: "Reachable content: " + node.text)
    }

    private struct Node {
        let object: NSObject
        func read(_ key: String) -> Any? { object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil }
        var role: NSAccessibility.Role? { (read("accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:)) }
        var text: String { [read("accessibilityLabel") as? String, read("accessibilityTitle") as? String, read("accessibilityValue") as? String].compactMap { $0 }.first { !$0.isEmpty } ?? "" }
        var identifier: String? { read("accessibilityIdentifier") as? String }
        var frame: NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    }

    private func nodes(_ root: NSObject) -> [Node] {
        var result = [Node](), seen = Set<ObjectIdentifier>()
        func visit(_ value: Any, depth: Int) {
            guard depth < 60, let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return }
            let node = Node(object: object); result.append(node)
            for child in node.read("accessibilityChildren") as? [Any] ?? [] { visit(child, depth: depth + 1) }
            if let view = object as? NSView { for child in view.subviews { visit(child, depth: depth + 1) } }
        }
        visit(root, depth: 0); return result
    }

    private func nativeViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { nativeViews(type, in: $0) }
    }

    private func show<V: View>(_ hosting: NSHostingView<V>, size: NSSize) -> NSWindow {
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil); return window
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    }

    private func enableAccessibility() -> () -> Void {
        let key = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        guard NSApp.accessibilityAttributeNames().contains(key) else { return {} }
        let previous = NSApp.accessibilityAttributeValue(key); NSApp.accessibilitySetValue(true, forAttribute: key)
        return { NSApp.accessibilitySetValue(previous ?? false, forAttribute: key) }
    }

    private func captureAndAudit(_ root: NSView, name: String) throws {
        let window = try XCTUnwrap(root.window)
        let viewport = window.convertToScreen(root.convert(root.bounds, to: nil))
        let content = nodes(root)
        let leaves: Set<NSAccessibility.Role> = [.staticText, .button, .checkBox, .popUpButton]
        for node in content where node.role.map(leaves.contains) == true {
            let frame = node.frame
            guard frame.width > 0, frame.height > 0, frame.intersects(viewport) else { continue }
            XCTAssertGreaterThanOrEqual(frame.minX, viewport.minX - 1, "\(name): \(node.text) overflows left")
            XCTAssertLessThanOrEqual(frame.maxX, viewport.maxX + 1, "\(name): \(node.text) overflows right")
        }
        for scroll in nativeViews(NSScrollView.self, in: root) {
            if let document = scroll.documentView {
                XCTAssertLessThanOrEqual(document.frame.width, scroll.contentView.bounds.width + 1, "Resource scroll content must not require horizontal scrolling")
            }
        }
        let directory = ProcessInfo.processInfo.environment["AXON_UI_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-resource-equal-height")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds)); root.cacheDisplay(in: root.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
        try content.map { "\($0.identifier ?? "")\t\($0.role?.rawValue ?? "")\t\($0.frame)\t\($0.text)" }.joined(separator: "\n")
            .write(to: directory.appendingPathComponent(name + "-accessibility.txt"), atomically: true, encoding: .utf8)
    }
}
