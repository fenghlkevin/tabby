import Foundation
import SwiftUI
import Citadel
import NIO

struct MonitoringRouteHop: Hashable, Sendable {
    let address: String
    let port: Int
    let username: String
    init(address: String, port: Int, username: String) {
        self.address = address.lowercased(); self.port = port; self.username = username
    }
}

struct MonitoringTargetID: Hashable, Identifiable, Sendable {
    let address: String
    let port: Int
    let username: String
    let route: [MonitoringRouteHop]
    var id: Self { self }
    init(address: String, port: Int, username: String, route: [MonitoringRouteHop] = []) {
        self.address = address.lowercased()
        self.port = port
        self.username = username
        self.route = route
    }
}

struct MonitoringEntry: Identifiable, Equatable, Sendable {
    let id: MonitoringTargetID
    var label: String
    var address: String
    var group: String
    var isConnected: Bool
}

enum MonitoringState: Equatable, Sendable {
    case collecting
    case paused
    case disconnected
    case error(String)
    case unsupported(String)
}

enum MonitoringDemand: Equatable {
    case none
    case overview
    case target(MonitoringTargetID)
}

/// A source is an existing authenticated connection, never a request to connect.
struct MonitoringSource {
    let id: MonitoringTargetID
    let connectionToken: String
    var hostID: UUID?
    var label: String
    var group: String
    let execute: @Sendable (_ command: String, _ maximumBytes: Int) async throws -> String
}

struct MonitoringClock: Sendable {
    var now: @Sendable () -> Date
    var sleep: @Sendable (Duration) async throws -> Void
    static let continuous = MonitoringClock(now: { Date() }, sleep: { try await Task.sleep(for: $0) })
}

enum MonitoringExecutionError: LocalizedError {
    case timeout
    case tooMuchOutput
    case disconnected
    var errorDescription: String? {
        switch self {
        case .timeout: return "Monitoring sample timed out (8 seconds)."
        case .tooMuchOutput: return "Monitoring output exceeded its size limit."
        case .disconnected: return "The SSH connection is disconnected."
        }
    }
}

enum MonitoringSSHExecutor {
    /// Cancellation terminates AsyncThrowingStream.next; withExec then closes
    /// its child channel. The interactive PTY and parent SSH client stay open.
    static func execute(client: SSHClient, command: String, maximumBytes: Int) async throws -> String {
        guard client.isConnected else { throw MonitoringExecutionError.disconnected }
        try Task.checkCancellation()
        var stdout = Data()
        var stderr = Data()
        var finishedStream = false
        do { try await client.withExec(command) { inbound, _ in
            // Citadel's channel setup future is not cancellable and has its own
            // 15-second creation bound. A late setup must close without reading.
            try Task.checkCancellation()
            for try await event in inbound {
                try Task.checkCancellation()
                switch event {
                case .stdout(let bytes):
                    guard bytes.readableBytes <= maximumBytes - stdout.count else { throw MonitoringExecutionError.tooMuchOutput }
                    stdout.append(contentsOf: bytes.readableBytesView)
                case .stderr(let bytes):
                    // Diagnostic output is not retained in snapshots or logs.
                    guard bytes.readableBytes <= 16 * 1024 - stderr.count else { throw MonitoringExecutionError.tooMuchOutput }
                    stderr.append(contentsOf: bytes.readableBytesView)
                }
            }
            try Task.checkCancellation()
            finishedStream = true
        } } catch let error as ChannelError where error == .alreadyClosed && finishedStream {
            // A normal remote EOF can close the child before withExec's final close.
        }
        try Task.checkCancellation()
        return String(decoding: stdout, as: UTF8.self)
    }
}

@MainActor final class MonitoringCenter: ObservableObject {
    @Published private(set) var entries: [MonitoringEntry] = []
    @Published private(set) var snapshots: [MonitoringTargetID: MonitoringSnapshot] = [:]
    @Published private(set) var history: [MonitoringTargetID: [MonitoringSnapshot]] = [:]
    @Published private(set) var states: [MonitoringTargetID: MonitoringState] = [:]
    @Published var selectedTargetID: MonitoringTargetID? {
        didSet { if selectedTargetID != oldValue { connectionsChanged() } }
    }
    private weak var store: AppStore?
    private var terminalStatusVisible = false
    private var foreground = false
    private var sources: [MonitoringTargetID: MonitoringSource] = [:]
    private var desired: Set<MonitoringTargetID> = []
    private var generations: [MonitoringTargetID: UInt64] = [:]
    private var baselines: [MonitoringTargetID: MonitoringSnapshot] = [:]
    private var unsupported: [MonitoringTargetID: String] = [:]
    private var cachedEntries: [MonitoringTargetID: MonitoringEntry] = [:]
    private var savedCacheTargets: Set<MonitoringTargetID> = []
    private var hostTargets: [UUID: MonitoringTargetID] = [:]
    private var intervals: [MonitoringTargetID: Task<Void, Never>] = [:]
    private var flights: [MonitoringTargetID: Flight] = [:]
    private let clock: MonitoringClock
    private let interval: Duration
    private let timeout: Duration
    private let maximumTargets: Int
    private let maximumHistory: Int
    private let parser: (String, MonitoringSnapshot?, Date) throws -> MonitoringSnapshot

    private final class Flight {
        let token = UUID()
        let generation: UInt64
        let connectionToken: String
        var worker: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var cancelled = false
        var timedOut = false
        init(generation: UInt64, connectionToken: String) { self.generation = generation; self.connectionToken = connectionToken }
        func cancel() { cancelled = true; worker?.cancel(); deadline?.cancel() }
    }

    init(clock: MonitoringClock = .continuous, interval: Duration = .seconds(5), timeout: Duration = .seconds(8),
         maximumTargets: Int = 32, maximumHistory: Int = 120,
         parser: @escaping (String, MonitoringSnapshot?, Date) throws -> MonitoringSnapshot = { raw, previous, timestamp in
             try MonitoringSampleParser.parse(raw: raw, previous: previous, timestamp: timestamp)
         }) {
        self.clock = clock; self.interval = interval; self.timeout = timeout
        self.maximumTargets = max(1, maximumTargets); self.maximumHistory = max(1, min(120, maximumHistory)); self.parser = parser
    }

    deinit {
        for task in intervals.values { task.cancel() }
        for flight in flights.values { flight.cancel() }
    }

    func configure(store: AppStore, terminalStatusVisible: Bool, foreground: Bool) {
        self.store = store; self.terminalStatusVisible = terminalStatusVisible; self.foreground = foreground
        connectionsChanged()
    }

    func targetID(for session: TerminalSession) -> MonitoringTargetID? {
        guard let host = session.host else { return nil }
        return MonitoringTargetID(address: session.authenticatedAddress ?? host.address,
                                  port: session.authenticatedPort ?? host.port,
                                  username: session.authenticatedUsername ?? host.username,
                                  route: session.connected ? session.authenticatedRoute : Self.savedRoute(for: host, workspace: session.store.workspace))
    }

    func targetID(for host: Host, workspace: Workspace) -> MonitoringTargetID {
        if let id = hostTargets[host.id] { return id }
        let effective = GroupDefaults.resolved(host, workspace: workspace)
        return MonitoringTargetID(address: effective.address, port: effective.port, username: RecentTargets.effectiveUsername(effective, workspace: workspace),
                                  route: Self.savedRoute(for: host, workspace: workspace))
    }

    /// Saved, disconnected catalog identity. A connected source always uses the
    /// immutable authenticated hop metadata from its successful SSH chain.
    static func savedRoute(for host: Host, workspace: Workspace) -> [MonitoringRouteHop] {
        var hops: [MonitoringRouteHop] = []
        var current = GroupDefaults.resolved(host, workspace: workspace)
        var seen: Set<UUID> = [host.id]
        while let jumpID = current.jumpHostID, seen.insert(jumpID).inserted,
              let saved = workspace.hosts.first(where: { $0.id == jumpID }) {
            let jump = GroupDefaults.resolved(saved, workspace: workspace)
            hops.insert(MonitoringRouteHop(address: jump.address, port: jump.port,
                                          username: RecentTargets.effectiveUsername(jump, workspace: workspace)), at: 0)
            current = jump
        }
        return hops
    }

    func select(_ id: MonitoringTargetID?) { selectedTargetID = id }

    /// Stops visibility demands, not the parent SSH connections. A subsequent
    /// configure from a visible window resumes using the saved view selection.
    func stop() {
        foreground = false
        for id in desired { invalidate(id) }
        desired = []
        for entry in entries { states[entry.id] = entry.isConnected ? .paused : .disconnected }
    }

    func connectionsChanged() {
        guard let store else { return }
        var live: [MonitoringSource] = []
        var sessionEntries: [MonitoringEntry] = []
        for session in store.sessions.sorted(by: { $0.creationOrder < $1.creationOrder }) {
            guard let host = session.host, let id = targetID(for: session) else { continue }
            let connected = session.connected && session.client?.isConnected == true
            let label = host.name.isEmpty ? id.address : host.name
            sessionEntries.append(MonitoringEntry(id: id, label: label, address: id.address, group: host.group, isConnected: connected))
            if connected, let client = session.client {
                live.append(MonitoringSource(id: id, connectionToken: String(describing: ObjectIdentifier(client)), hostID: host.id,
                                             label: label, group: host.group, execute: { command, maximum in
                    try await MonitoringSSHExecutor.execute(client: client, command: command, maximumBytes: maximum)
                }))
            }
        }
        let saved = store.workspace.hosts.map { host -> MonitoringEntry in
            let effective = GroupDefaults.resolved(host, workspace: store.workspace)
            let id = live.first(where: { $0.hostID == host.id })?.id
                ?? MonitoringTargetID(address: effective.address, port: effective.port, username: RecentTargets.effectiveUsername(effective, workspace: store.workspace),
                                      route: Self.savedRoute(for: host, workspace: store.workspace))
            return MonitoringEntry(id: id, label: host.name.isEmpty ? host.address : host.name, address: id.address, group: host.group,
                                   isConnected: live.contains { $0.id == id })
        }
        let savedIDs = Set(saved.map(\.id)), liveIDs = Set(live.map(\.id))
        for id in savedCacheTargets.subtracting(savedIDs) where !liveIDs.contains(id) { discardCache(id) }
        let demand: MonitoringDemand
        if store.section == "monitoring" { demand = selectedTargetID.map(MonitoringDemand.target) ?? .overview }
        else if store.section == "terminal", terminalStatusVisible,
                let session = store.sessions.first(where: { $0.id == store.activeSession }), let id = targetID(for: session) { demand = .target(id) }
        else { demand = .none }
        configure(sources: live, entries: saved + sessionEntries, demand: demand, foreground: foreground)
    }

    /// Independent source/clock injection permits lifecycle tests without SSH or credentials.
    func configure(sources candidates: [MonitoringSource], entries metadata: [MonitoringEntry], demand: MonitoringDemand, foreground: Bool) {
        var live: [MonitoringTargetID: MonitoringSource] = [:]
        hostTargets = [:]
        for source in candidates where live[source.id] == nil { live[source.id] = source }
        for source in candidates { if let host = source.hostID, hostTargets[host] == nil { hostTargets[host] = source.id } }
        for id in Set(sources.keys).union(live.keys) where sources[id]?.connectionToken != live[id]?.connectionToken {
            invalidate(id)
            unsupported[id] = nil
        }
        sources = live
        var catalog = cachedEntries
        for entry in metadata { catalog[entry.id] = entry }
        for (id, source) in live {
            catalog[id] = MonitoringEntry(id: id, label: source.label, address: id.address, group: source.group, isConnected: true)
        }
        for id in catalog.keys { catalog[id]?.isConnected = live[id] != nil }
        entries = catalog.values.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        let wanted: Set<MonitoringTargetID>
        if !foreground { wanted = [] }
        else { switch demand { case .none: wanted = []; case .overview: wanted = Set(live.keys); case .target(let id): wanted = live[id] == nil ? [] : [id] } }
        for id in desired.subtracting(wanted) { invalidate(id) }
        desired = wanted
        for entry in entries {
            if live[entry.id] == nil { states[entry.id] = .disconnected }
            else if !wanted.contains(entry.id) { states[entry.id] = .paused }
            else if let reason = unsupported[entry.id] { states[entry.id] = .unsupported(reason) }
            else if flights[entry.id] == nil && intervals[entry.id] == nil { start(entry.id) }
            else if flights[entry.id]?.cancelled == true { states[entry.id] = .collecting }
        }
        states = states.filter { catalog[$0.key] != nil || flights[$0.key] != nil }
        let retained = Set(catalog.keys).union(live.keys).union(flights.keys)
        generations = generations.filter { retained.contains($0.key) }
        unsupported = unsupported.filter { retained.contains($0.key) }
        trimCache()
    }

    func refresh(_ id: MonitoringTargetID) {
        guard desired.contains(id), sources[id] != nil else { return }
        unsupported[id] = nil
        intervals.removeValue(forKey: id)?.cancel()
        if flights[id] == nil { start(id) }
    }

    private func invalidate(_ id: MonitoringTargetID) {
        generations[id, default: 0] &+= 1
        intervals.removeValue(forKey: id)?.cancel()
        flights[id]?.cancel()
        baselines[id] = nil
    }

    private func start(_ id: MonitoringTargetID) {
        guard desired.contains(id), let source = sources[id], flights[id] == nil, unsupported[id] == nil else { return }
        let flight = Flight(generation: generations[id, default: 0], connectionToken: source.connectionToken)
        flights[id] = flight
        states[id] = .collecting
        let clock = self.clock, timeout = self.timeout
        flight.worker = Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await source.execute(MonitoringCommand.script, MonitoringCommand.maximumResponseBytes)) }
            catch { result = .failure(error) }
            self?.completed(id, token: flight.token, result: result)
        }
        // MainActor serializes completion, timeout and cancellation. There is no
        // continuation to resume twice and no structured group waiting on NIO.
        flight.deadline = Task { [weak self] in
            do { try await clock.sleep(timeout); try Task.checkCancellation() }
            catch { return }
            guard let self, self.flights[id]?.token == flight.token else { return }
            flight.timedOut = true
            flight.worker?.cancel()
            self.baselines[id] = nil
            if self.desired.contains(id) {
                self.states[id] = .error(self.store?.text("Monitoring sample timed out (8 seconds).", "监控采样超时（8 秒）。") ?? MonitoringExecutionError.timeout.localizedDescription)
            }
            // Keep this flight until setup/stream cleanup actually completes.
        }
    }

    private func completed(_ id: MonitoringTargetID, token: UUID, result: Result<String, Error>) {
        guard let flight = flights[id], flight.token == token else { return }
        flights[id] = nil
        flight.deadline?.cancel()
        guard desired.contains(id), let source = sources[id] else { return }
        if flight.cancelled || flight.generation != generations[id, default: 0] || flight.connectionToken != source.connectionToken {
            start(id)
            return
        }
        if !flight.timedOut {
            do {
                let raw = try result.get()
                guard raw.utf8.count <= MonitoringCommand.maximumResponseBytes else { throw MonitoringExecutionError.tooMuchOutput }
                let snapshot = try parser(raw, baselines[id], clock.now())
                snapshots[id] = snapshot
                baselines[id] = baselineSnapshot(snapshot)
                cachedEntries[id] = entries.first { $0.id == id }
                if let hostID = source.hostID, store?.workspace.hosts.contains(where: { $0.id == hostID }) == true { savedCacheTargets.insert(id) }
                if snapshot.isSupported {
                    states[id] = .collecting
                    history[id, default: []].append(trendSnapshot(snapshot))
                    history[id] = Array((history[id] ?? []).suffix(maximumHistory))
                } else {
                    let reason = snapshot.availability["system"] ?? "Unsupported operating system"
                    unsupported[id] = reason; states[id] = .unsupported(reason)
                }
                trimCache()
            } catch {
                baselines[id] = nil
                states[id] = .error(error.localizedDescription)
            }
        }
        guard unsupported[id] == nil else { return }
        schedule(id)
    }

    private func schedule(_ id: MonitoringTargetID) {
        let clock = self.clock, interval = self.interval, generation = generations[id, default: 0]
        intervals[id] = Task { [weak self] in
            do { try await clock.sleep(interval); try Task.checkCancellation() }
            catch { return }
            guard let self, self.generations[id, default: 0] == generation else { return }
            self.intervals[id] = nil
            self.start(id)
        }
    }

    private func trendSnapshot(_ snapshot: MonitoringSnapshot) -> MonitoringSnapshot {
        var value = snapshot
        value.processes = []; value.gpuProcesses = []; value.containers = []; value.trafficHistory = nil
        value.cpuCounters = [:]; value.diskCounters = [:]; value.networkCounters = [:]
        return value
    }

    private func baselineSnapshot(_ snapshot: MonitoringSnapshot) -> MonitoringSnapshot {
        var value = snapshot
        value.cpu = nil; value.load = nil; value.memory = nil
        value.disks = []; value.diskIO = []; value.processes = []; value.interfaces = []; value.gpus = []
        value.gpuProcesses = []; value.containers = []; value.trafficHistory = nil
        value.availability = [:]; value.issues = []
        return value
    }

    private func discardCache(_ id: MonitoringTargetID) {
        snapshots[id] = nil; history[id] = nil; baselines[id] = nil; cachedEntries[id] = nil; savedCacheTargets.remove(id)
    }

    private func trimCache() {
        let limit = max(maximumTargets, desired.count)
        while snapshots.count > limit {
            guard let id = snapshots.keys.filter({ !desired.contains($0) && $0 != selectedTargetID }).min(by: { snapshots[$0]!.timestamp < snapshots[$1]!.timestamp }) else { break }
            discardCache(id)
        }
    }
}
