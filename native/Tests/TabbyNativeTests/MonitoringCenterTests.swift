import XCTest
@testable import TabbyNative

@MainActor final class MonitoringCenterTests: XCTestCase {
    func testVisibilityAndExplicitDemandNeverStartSavedOrHiddenTargets() async throws {
        let gate = MonitoringGate()
        let clock = MonitoringManualClock()
        let id = target("visible")
        let offline = target("saved-only")
        let source = source(id, gate: gate)
        let entries = [entry(id), entry(offline)]
        let center = MonitoringCenter(clock: clock.clock, parser: sample)
        center.configure(sources: [source], entries: entries, demand: .overview, foreground: false)
        await settle()
        await expectCount(0, gate)
        XCTAssertEqual(center.states[id], .paused)
        XCTAssertEqual(center.states[offline], .disconnected)
        center.configure(sources: [source], entries: entries, demand: .none, foreground: true)
        center.refresh(id)
        await settle()
        await expectCount(0, gate)
        center.configure(sources: [source], entries: entries, demand: .target(offline), foreground: true)
        await settle()
        await expectCount(0, gate)
        center.configure(sources: [source], entries: entries, demand: .target(id), foreground: true)
        await eventually { await gate.count == 1 }
        XCTAssertEqual(center.states[id], .collecting)
        center.stop()
        await gate.finishAll()
        await settle()
        XCTAssertEqual(center.states[id], .paused)
    }

    func testDuplicateAuthenticatedTargetsShareOneSourceButDifferentUsersDoNot() async throws {
        let gate = MonitoringGate()
        let id = target("HOST.example")
        let sameID = target("host.example")
        let otherUser = target("host.example", username: "other")
        let center = MonitoringCenter(parser: sample)
        center.configure(sources: [source(id, token: "first", gate: gate), source(sameID, token: "second", gate: gate), source(otherUser, token: "third", gate: gate)],
                         entries: [], demand: .overview, foreground: true)
        await eventually { await gate.count == 2 }
        let calls = await gate.labels
        XCTAssertEqual(Set(calls), ["first", "third"])
        XCTAssertEqual(center.entries.count, 2)
        center.stop()
        await gate.finishAll()
        await settle()
    }

    func testSamePrivateEndpointThroughDifferentJumpRoutesIsNotMerged() async throws {
        let gate = MonitoringGate()
        let firstRoute = [MonitoringRouteHop(address: "Jump-A.example", port: 2222, username: "bastion-user")]
        let equivalentRoute = [MonitoringRouteHop(address: "jump-a.example", port: 2222, username: "bastion-user")]
        let secondRoute = [MonitoringRouteHop(address: "jump-b.example", port: 2222, username: "bastion-user")]
        let a = MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: firstRoute)
        let duplicateA = MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: equivalentRoute)
        let b = MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: secondRoute)
        XCTAssertEqual(a, duplicateA)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, target("10.0.0.1", username: "root"), "Direct and tunneled endpoints must not share a sample")
        let center = MonitoringCenter(parser: sample)
        center.configure(sources: [source(a, token: "route-a-first", gate: gate), source(duplicateA, token: "route-a-duplicate", gate: gate),
                                   source(b, token: "route-b", gate: gate)], entries: [], demand: .overview, foreground: true)
        await eventually { await gate.count == 2 }
        let calls = await gate.labels
        XCTAssertEqual(Set(calls), ["route-a-first", "route-b"])
        XCTAssertEqual(center.entries.count, 2)
        center.stop()
        await gate.finishAll()
        await settle()
    }

    func testAuthenticatedHopUserPortAndHopOrderArePartOfIdentity() {
        let outer = MonitoringRouteHop(address: "OUTER.example", port: 22, username: "ActualUser")
        let inner = MonitoringRouteHop(address: "10.0.0.2", port: 2222, username: "inner-user")
        let target = MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: [outer, inner])
        XCTAssertEqual(outer.address, "outer.example")
        XCTAssertEqual(outer.username, "ActualUser", "Usernames must preserve case and the actually authenticated identity")
        XCTAssertNotEqual(target, MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: [inner, outer]))
        XCTAssertNotEqual(target, MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: [
            MonitoringRouteHop(address: outer.address, port: 2222, username: outer.username), inner]))
        XCTAssertNotEqual(target, MonitoringTargetID(address: "10.0.0.1", port: 22, username: "root", route: [
            MonitoringRouteHop(address: outer.address, port: 22, username: "saved-user"), inner]))
    }

    func testDisconnectedSavedRouteUsesEffectiveCredentialsInConnectionOrder() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("axon-monitor-route-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = AppStore(fileURL: path.appendingPathComponent("workspace.json"))
        var credential = VaultCredential(); credential.username = "actual-jump-identity"
        var outer = TabbyNative.Host(); outer.address = "OUTER.example"; outer.username = "unused-saved-user"; outer.credentialID = credential.id
        var inner = TabbyNative.Host(); inner.address = "10.0.0.2"; inner.port = 2222; inner.username = "inner-user"; inner.jumpHostID = outer.id
        var host = TabbyNative.Host(); host.address = "10.0.0.1"; host.username = "root"; host.jumpHostID = inner.id
        store.workspace.credentials = [credential]
        store.workspace.hosts = [host, inner, outer]
        let route = [MonitoringRouteHop(address: "outer.example", port: 22, username: "actual-jump-identity"),
                     MonitoringRouteHop(address: "10.0.0.2", port: 2222, username: "inner-user")]
        let expected = MonitoringTargetID(address: host.address, port: host.port, username: host.username, route: route)
        let session = TerminalSession(host: host, store: store)
        XCTAssertEqual(MonitoringCenter.savedRoute(for: host, workspace: store.workspace), route)
        XCTAssertEqual(store.monitoring.targetID(for: host, workspace: store.workspace), expected)
        XCTAssertEqual(store.monitoring.targetID(for: session), expected)
        store.section = "monitoring"
        store.monitoring.configure(store: store, terminalStatusVisible: false, foreground: true)
        XCTAssertTrue(store.monitoring.entries.contains { $0.id == expected })
        XCTAssertEqual(store.monitoring.states[expected], .disconnected)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        store.monitoring.stop()
    }

    func testDeadlinePublishesErrorWithoutOverlappingAnUncancellableSetup() async throws {
        let gate = MonitoringGate()
        let clock = MonitoringManualClock()
        let id = target("deadline")
        let source = source(id, gate: gate)
        let center = MonitoringCenter(clock: clock.clock, parser: sample)
        center.configure(sources: [source], entries: [], demand: .overview, foreground: true)
        await eventually { await gate.count == 1 && clock.pendingCount == 1 }
        clock.advance(8)
        await eventually { if case .error = center.states[id] { return true }; return false }
        center.refresh(id)
        clock.advance(30)
        await settle()
        await expectCount(1, gate)
        XCTAssertNil(center.snapshots[id])
        await gate.finish(0, raw: "77")
        await eventually { clock.pendingCount == 1 }
        XCTAssertNil(center.snapshots[id], "A result that arrives after the deadline must be discarded")
        clock.advance(5)
        await eventually { await gate.count == 2 }
        await gate.finish(1, raw: "2")
        await eventually { center.snapshots[id] != nil }
        XCTAssertNil(center.snapshots[id]?.cpu?.usagePercent, "Timeout resets the rate baseline")
        center.stop()
    }

    func testPauseResumeAndReconnectDiscardLateResultsAndWaitForCleanup() async throws {
        let gate = MonitoringGate()
        let clock = MonitoringManualClock()
        let id = target("generation")
        let old = source(id, token: "old", gate: gate)
        let replacement = source(id, token: "new", gate: gate)
        let center = MonitoringCenter(clock: clock.clock, parser: sample)
        center.configure(sources: [old], entries: [], demand: .overview, foreground: true)
        await eventually { await gate.count == 1 }
        center.configure(sources: [old], entries: [], demand: .none, foreground: true)
        XCTAssertEqual(center.states[id], .paused)
        center.configure(sources: [replacement], entries: [], demand: .target(id), foreground: true)
        await settle()
        await expectCount(1, gate, "The new connection must wait until the previous child finishes")
        await gate.finish(0, raw: "99")
        await eventually { await gate.count == 2 }
        XCTAssertNil(center.snapshots[id])
        let labels = await gate.labels
        XCTAssertEqual(labels, ["old", "new"])
        await gate.finish(1, raw: "3")
        await eventually { center.snapshots[id] != nil }
        XCTAssertEqual(center.snapshots[id]?.uptime, 103)
        XCTAssertNil(center.snapshots[id]?.cpu?.usagePercent)
        center.stop()
    }

    func testFiveSecondCadenceUsesSmallBaselinesAndBoundsHistory() async throws {
        let gate = MonitoringGate()
        let clock = MonitoringManualClock()
        let id = target("cadence")
        var previousSamples: [MonitoringSnapshot?] = []
        let center = MonitoringCenter(clock: clock.clock, maximumHistory: 2, parser: { raw, previous, date in
            previousSamples.append(previous)
            return Self.makeSample(raw, previous: previous, timestamp: date)
        })
        let source = source(id, gate: gate)
        center.configure(sources: [source], entries: [], demand: .overview, foreground: true)
        for index in 0..<3 {
            await eventually { await gate.count == index + 1 }
            await gate.finish(index, raw: String(index + 1))
            await eventually { center.snapshots[id]?.uptime == 101 + Double(index) && clock.pendingCount == 1 }
            if index < 2 {
                clock.advance(4)
                await settle()
                await expectCount(index + 1, gate)
                clock.advance(1)
            }
        }
        XCTAssertEqual(previousSamples.count, 3)
        XCTAssertNil(previousSamples[0])
        let baseline = try XCTUnwrap(previousSamples[1])
        XCTAssertEqual(baseline.cpuCounters["cpu"]?.values, [1, 2, 3, 4])
        XCTAssertEqual(baseline.bootID, "fixture-boot")
        XCTAssertEqual(baseline.uptime, 101)
        XCTAssertNil(baseline.cpu)
        XCTAssertNil(baseline.load)
        XCTAssertTrue(baseline.processes.isEmpty)
        XCTAssertTrue(baseline.availability.isEmpty)
        XCTAssertEqual(center.history[id]?.count, 2)
        XCTAssertEqual(center.history[id]?.first?.uptime, 102)
        XCTAssertTrue(center.history[id]?.allSatisfy { $0.processes.isEmpty && $0.cpuCounters.isEmpty } == true)
        XCTAssertEqual(center.snapshots[id]?.processes.count, 1)
        center.configure(sources: [source], entries: [], demand: .none, foreground: true)
        center.configure(sources: [source], entries: [], demand: .target(id), foreground: true)
        await eventually { await gate.count == 4 }
        await gate.finish(3, raw: "4")
        await eventually { previousSamples.count == 4 }
        XCTAssertNil(previousSamples[3], "Returning to a visible monitor needs a fresh delta baseline")
        center.stop()
    }

    func testActiveTargetsCannotEvictEachOthersSnapshotsOrRateBaselines() async throws {
        let clock = MonitoringManualClock()
        var previousByID: [String: [Bool]] = [:]
        let ids = (0..<4).map { target("active-\($0)") }
        let sources = ids.map { id in
            MonitoringSource(id: id, connectionToken: id.address, label: id.address, group: "", execute: { _, _ in id.address })
        }
        let center = MonitoringCenter(clock: clock.clock, maximumTargets: 2, parser: { raw, previous, date in
            previousByID[raw, default: []].append(previous != nil)
            return Self.makeSample("1", previous: previous, timestamp: date)
        })
        center.configure(sources: sources, entries: [], demand: .overview, foreground: true)
        await eventually { center.snapshots.count == 4 && clock.pendingCount == 4 }
        clock.advance(5)
        await eventually { previousByID.values.allSatisfy { $0.count == 2 } && clock.pendingCount == 4 }
        XCTAssertTrue(previousByID.values.allSatisfy { $0 == [false, true] })
        XCTAssertEqual(center.snapshots.count, 4)
        center.configure(sources: [], entries: [], demand: .none, foreground: true)
        XCTAssertEqual(center.snapshots.count, 2, "Only old, unsubscribed targets are subject to the cache cap")
        XCTAssertEqual(center.history.count, 2)
        center.stop()
    }

    func testUnsupportedHostWaitsForExplicitRetryAndFailedParserDoesNotReuseBaseline() async throws {
        let clock = MonitoringManualClock()
        let gate = MonitoringGate()
        let id = target("unsupported")
        var previousSamples: [MonitoringSnapshot?] = []
        let source = source(id, gate: gate)
        let center = MonitoringCenter(clock: clock.clock, parser: { raw, previous, date in
            previousSamples.append(previous)
            if raw == "invalid" { throw MonitoringParseError.invalid("fixture protocol error") }
            return Self.makeSample(raw, previous: previous, timestamp: date)
        })
        center.configure(sources: [source], entries: [], demand: .overview, foreground: true)
        await eventually { await gate.count == 1 }
        await gate.finish(0, raw: "unsupported")
        await eventually { if case .unsupported = center.states[id] { return true }; return false }
        XCTAssertTrue(center.history[id]?.isEmpty != false)
        clock.advance(50)
        await settle()
        await expectCount(1, gate)
        center.refresh(id)
        await eventually { await gate.count == 2 }
        await gate.finish(1, raw: "invalid")
        await eventually { center.states[id] == .error("fixture protocol error") && clock.pendingCount == 1 }
        clock.advance(5)
        await eventually { await gate.count == 3 }
        await gate.finish(2, raw: "3")
        await eventually { center.snapshots[id]?.isSupported == true }
        XCTAssertNil(previousSamples.last!)
        center.stop()
    }

    func testSwitchingSelectedTargetImmediatelyPausesTheOtherTarget() async throws {
        let gate = MonitoringGate()
        let a = target("a"), b = target("b")
        let sources = [source(a, token: "a", gate: gate), source(b, token: "b", gate: gate)]
        let center = MonitoringCenter(parser: sample)
        center.configure(sources: sources, entries: [], demand: .target(a), foreground: true)
        await eventually { await gate.count == 1 }
        center.configure(sources: sources, entries: [], demand: .target(b), foreground: true)
        await eventually { await gate.count == 2 }
        XCTAssertEqual(center.states[a], .paused)
        XCTAssertEqual(center.states[b], .collecting)
        await gate.finish(0, raw: "80")
        await gate.finish(1, raw: "2")
        await eventually { center.snapshots[b] != nil }
        XCTAssertNil(center.snapshots[a])
        center.stop()
    }

    private func target(_ address: String, username: String = "tester") -> MonitoringTargetID {
        MonitoringTargetID(address: address, port: 22, username: username)
    }
    private func entry(_ id: MonitoringTargetID) -> MonitoringEntry {
        MonitoringEntry(id: id, label: id.address, address: id.address, group: "Fixture", isConnected: false)
    }
    private func source(_ id: MonitoringTargetID, token: String = "connection", gate: MonitoringGate) -> MonitoringSource {
        MonitoringSource(id: id, connectionToken: token, label: id.address, group: "Fixture", execute: { command, maximum in
            guard command == MonitoringCommand.script, maximum == MonitoringCommand.maximumResponseBytes else {
                throw MonitoringParseError.invalid("Unexpected collector command or output bound")
            }
            return try await gate.execute(label: token)
        })
    }
    private func sample(_ raw: String, _ previous: MonitoringSnapshot?, _ date: Date) throws -> MonitoringSnapshot {
        Self.makeSample(raw, previous: previous, timestamp: date)
    }
    private static func makeSample(_ raw: String, previous: MonitoringSnapshot?, timestamp: Date) -> MonitoringSnapshot {
        let value = UInt64(raw) ?? 1
        return MonitoringSnapshot(timestamp: timestamp, os: raw == "unsupported" ? "Darwin" : "Linux", kernel: "fixture",
                                  uptime: 100 + Double(value), bootID: "fixture-boot", coreCount: 2,
                                  cpu: MonitoringCPU(usagePercent: previous == nil ? nil : 20, userPercent: nil, systemPercent: nil,
                                                     nicePercent: nil, ioWaitPercent: nil, stealPercent: nil, cores: []),
                                  load: MonitoringLoad(oneMinute: 1, fiveMinutes: 2, fifteenMinutes: 3), memory: nil,
                                  processes: [MonitoringProcess(pid: 7, user: "tester", threads: 1, state: "S", cpuPercent: 1, memoryBytes: 1, command: "fixture")],
                                  trafficHistory: nil, availability: ["system": raw == "unsupported" ? "Fixture OS is unsupported" : "Available"],
                                  cpuCounters: ["cpu": MonitoringCPUCounters(values: [value, 2, 3, 4])])
    }
    private func expectCount(_ expected: Int, _ gate: MonitoringGate, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await gate.count
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(2))
    }
    private func eventually(_ predicate: @MainActor () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Monitoring lifecycle did not reach its expected state", file: file, line: line)
    }
}

/// Intentionally ignores cancellation while waiting, like Citadel's channel
/// setup future. The center must keep its in-flight slot until cleanup returns.
private actor MonitoringGate {
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private(set) var labels: [String] = []
    var count: Int { labels.count }
    func execute(label: String) async throws -> String {
        let index = labels.count
        labels.append(label)
        return try await withCheckedThrowingContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, raw: String) { continuations.removeValue(forKey: index)?.resume(returning: raw) }
    func finishAll() {
        let values = Array(continuations.values)
        continuations = [:]
        for value in values { value.resume(returning: "cleanup") }
    }
}

private final class MonitoringManualClock: @unchecked Sendable {
    private struct Waiter { let deadline: TimeInterval; let continuation: CheckedContinuation<Void, Error> }
    private let lock = NSLock()
    private var current: TimeInterval = 1_000
    private var waiters: [UUID: Waiter] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var completed: Set<UUID> = []
    var clock: MonitoringClock { MonitoringClock(now: { self.now }, sleep: { try await self.sleep($0) }) }
    private var now: Date { lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: current) }
    var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return waiters.count }
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current += seconds
        let ready = waiters.filter { $0.value.deadline <= current }
        for id in ready.keys { waiters[id] = nil; completed.insert(id) }
        lock.unlock()
        for waiter in ready.values { waiter.continuation.resume() }
    }
    private func sleep(_ duration: Duration) async throws {
        let id = UUID()
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(id, seconds: seconds, continuation: continuation)
            }
        }, onCancel: { self.cancel(id) })
    }
    private func register(_ id: UUID, seconds: Double, continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        let cancelled = cancelledBeforeRegistration.remove(id) != nil
        if cancelled { completed.insert(id) }
        else { waiters[id] = Waiter(deadline: current + seconds, continuation: continuation) }
        lock.unlock()
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }
    private func cancel(_ id: UUID) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        if waiter != nil { completed.insert(id) }
        else if !completed.contains(id) { cancelledBeforeRegistration.insert(id) }
        lock.unlock()
        waiter?.continuation.resume(throwing: CancellationError())
    }
}
