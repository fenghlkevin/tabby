import Foundation

enum RecentTargetKind: String, Codable, CaseIterable {
    case localTerminal, ssh, sftp, localFiles
    var isFiles: Bool { self == .sftp || self == .localFiles }
}

/// Only a vault identity or safe connection coordinates are persisted. Authentication
/// metadata and secrets are resolved from the current vault when the user reopens it.
struct RecentTarget: Codable, Equatable, Identifiable {
    var kind: RecentTargetKind
    var hostID: UUID?
    var credentialID: UUID?
    var username: String?
    var address: String?
    var port: Int?
    var lastOpened: Date
    var id: String {
        let destination = hostID.map { "host:\($0.uuidString)" }
            ?? address.map { "quick:\(credentialID.map { "identity:\($0.uuidString)" } ?? username ?? "")@\($0.lowercased()):\(port ?? 22)" }
            ?? "local"
        return kind.rawValue + ":" + destination
    }
    init(kind: RecentTargetKind, hostID: UUID? = nil, credentialID: UUID? = nil, username: String? = nil, address: String? = nil, port: Int? = nil, lastOpened: Date = Date()) {
        self.kind = kind; self.hostID = hostID; self.credentialID = credentialID; self.username = username
        self.address = address; self.port = port; self.lastOpened = lastOpened
    }
}

struct RecentFileRequest: Identifiable {
    let id = UUID()
    let target: RecentTarget
    let sessionID: UUID?
}

enum RecentTargets {
    static let maximumCount = 5
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func effectiveUsername(_ host: Host, workspace: Workspace) -> String {
        GroupDefaults.resolved(host, workspace: workspace).username.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func savedHost(matching host: Host, workspace: Workspace) -> Host? {
        let target = GroupDefaults.resolved(host, workspace: workspace)
        return workspace.hosts.first {
            let saved = GroupDefaults.resolved($0, workspace: workspace)
            return saved.address.caseInsensitiveCompare(target.address) == .orderedSame && saved.port == target.port
                && saved.username == target.username
        }
    }
    static func validUsername(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }
    static func make(kind: RecentTargetKind, host: Host?, workspace: Workspace, now: Date = Date()) -> RecentTarget? {
        if kind == .localTerminal || kind == .localFiles { return RecentTarget(kind: kind, lastOpened: now) }
        guard let host else { return nil }
        if workspace.hosts.contains(where: { $0.id == host.id }) { return RecentTarget(kind: kind, hostID: host.id, lastOpened: now) }
        guard validQuickAddress(host.address), (1...65535).contains(host.port) else { return nil }
        if let id = host.credentialID {
            guard workspace.credentials.contains(where: { $0.id == id }) else { return nil }
            return RecentTarget(kind: kind, credentialID: id, address: host.address, port: host.port, lastOpened: now)
        }
        guard validUsername(host.username) else { return nil }
        return RecentTarget(kind: kind, username: host.username, address: host.address, port: host.port, lastOpened: now)
    }
    static func resolvedHost(_ target: RecentTarget, workspace: Workspace) -> Host? {
        guard target.kind == .ssh || target.kind == .sftp else { return nil }
        if let id = target.hostID { return workspace.hosts.first { $0.id == id } }
        guard let address = target.address, let port = target.port,
              validQuickAddress(address), (1...65535).contains(port) else { return nil }
        var host = Host(); host.address = address; host.port = port; host.name = address
        if let id = target.credentialID {
            guard let credential = workspace.credentials.first(where: { $0.id == id }) else { return nil }
            host.credentialID = id; host.username = credential.username
            return host
        }
        guard let username = target.username, validUsername(username) else { return nil }
        host.username = username
        return savedHost(matching: host, workspace: workspace) ?? host
    }
    static func pruned(_ targets: [RecentTarget], workspace: Workspace, now: Date = Date()) -> [RecentTarget] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var seen = Set<String>()
        var categoryCounts: [Bool: Int] = [:]
        return targets.filter { $0.lastOpened >= cutoff && $0.lastOpened <= now }
            .compactMap { target -> RecentTarget? in
                if target.kind == .localTerminal || target.kind == .localFiles {
                    return RecentTarget(kind: target.kind, lastOpened: target.lastOpened)
                }
                guard let host = resolvedHost(target, workspace: workspace) else { return nil }
                if workspace.hosts.contains(where: { $0.id == host.id }) {
                    return RecentTarget(kind: target.kind, hostID: host.id, lastOpened: target.lastOpened)
                }
                return make(kind: target.kind, host: host, workspace: workspace, now: target.lastOpened)
            }
            .sorted { $0.lastOpened == $1.lastOpened ? $0.id < $1.id : $0.lastOpened > $1.lastOpened }
            .filter { seen.insert($0.id).inserted }
            .filter { target in
                let category = target.kind.isFiles
                let count = categoryCounts[category, default: 0]
                guard count < maximumCount else { return false }
                categoryCounts[category] = count + 1
                return true
            }
    }
    /// A live connection may have identical coordinates but come from a
    /// different vault profile, identity, or jump route. Those are distinct
    /// targets even when the resulting login name happens to match.
    static func canReuseProfile(_ current: Host, _ requested: Host, workspace: Workspace) -> Bool {
        let savedIDs = Set(workspace.hosts.map(\.id))
        if savedIDs.contains(current.id) || savedIDs.contains(requested.id) {
            guard current.id == requested.id else { return false }
        }
        let current = GroupDefaults.resolved(groupSnapshotForReuse(current, workspace: workspace), workspace: workspace)
        let requested = GroupDefaults.resolved(groupSnapshotForReuse(requested, workspace: workspace), workspace: workspace)
        guard current.credentialID == requested.credentialID, current.jumpHostID == requested.jumpHostID else { return false }
        if current.credentialID == nil {
            guard current.persistentSession == requested.persistentSession, current.persistentSessionName == requested.persistentSessionName, current.auth == requested.auth, current.keyPath == requested.keyPath, current.keySource == requested.keySource else { return false }
        }
        return true
    }
    private static func groupSnapshotForReuse(_ original: Host, workspace: Workspace) -> Host {
        guard let flags = original.groupInheritance, flags.hasAny,
              let current = workspace.hosts.first(where: { $0.id == original.id }),
              !CatalogNames.matches(original.group, current.group) else { return original }
        var source = GroupDefaults.connectionSource(original, workspace: workspace)
        // A rename or group dissolution refreshes inherited values, while
        // independent identity changes remain distinct profiles for reuse.
        if !flags.authentication {
            source.auth = original.auth; source.keyPath = original.keyPath; source.keySource = original.keySource
            source.credentialID = original.credentialID
        }
        if !flags.username { source.username = original.username }
        return source
    }
    static func sameHost(_ target: RecentTarget, host: Host?, workspace: Workspace) -> Bool {
        guard let host else { return target.kind == .localTerminal || target.kind == .localFiles }
        if let id = target.hostID { return host.id == id }
        guard let targetHost = resolvedHost(target, workspace: workspace) else { return false }
        let current = GroupDefaults.resolved(host, workspace: workspace)
        let requested = GroupDefaults.resolved(targetHost, workspace: workspace)
        return current.address.caseInsensitiveCompare(requested.address) == .orderedSame && current.port == requested.port
            && current.username == requested.username
    }
}

@MainActor extension AppStore {
    var recentTargets: [RecentTarget] { RecentTargets.pruned(workspace.recentTargets, workspace: workspace) }
    func pruneRecentTargets(now: Date = Date()) {
        let updated = RecentTargets.pruned(workspace.recentTargets, workspace: workspace, now: now)
        if updated != workspace.recentTargets { commitRecentTargets(updated) }
    }
    func recordRecentSuccess(_ host: Host? = nil, kind: RecentTargetKind, now: Date = Date()) {
        // A deleted saved host must not turn into an anonymous quick target later
        // when an old in-flight connection finishes.
        if let host, deletedHostIDs.contains(host.id) { return }
        guard let target = RecentTargets.make(kind: kind, host: host, workspace: workspace, now: now) else { return }
        commitRecentTargets(RecentTargets.pruned([target] + workspace.recentTargets.filter { $0.id != target.id }, workspace: workspace, now: now))
    }
    func removeRecent(_ target: RecentTarget) { commitRecentTargets(workspace.recentTargets.filter { $0.id != target.id }) }
    func clearRecent() { commitRecentTargets([]) }
    func recentTitle(_ target: RecentTarget) -> String {
        switch target.kind {
        case .localTerminal: return text("Local terminal", "本地终端")
        case .localFiles: return text("Local files", "本地文件")
        case .ssh, .sftp:
            guard let host = RecentTargets.resolvedHost(target, workspace: workspace) else { return text("Unavailable host", "主机已不可用") }
            return host.name.isEmpty ? host.address : host.name
        }
    }
    func recentTypeTitle(_ target: RecentTarget) -> String {
        switch target.kind {
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        case .localTerminal: return "Local"
        case .localFiles: return text("Local files", "本地文件")
        }
    }
    func recentSubtitle(_ target: RecentTarget) -> String {
        switch target.kind {
        case .localTerminal: return text("Terminal", "终端")
        case .localFiles: return text("Local file browser", "本地文件浏览")
        case .ssh, .sftp:
            guard let raw = RecentTargets.resolvedHost(target, workspace: workspace) else { return "" }
            let host = resolvedHost(raw)
            return (target.kind == .ssh ? "SSH" : "SFTP") + " · \(RecentTargets.effectiveUsername(host, workspace: workspace))@\(host.address):\(host.port)"
        }
    }
    @discardableResult func openRecent(_ target: RecentTarget) -> Bool {
        guard recentTargets.contains(where: { $0.id == target.id }) else { return false }
        if target.kind.isFiles {
            if target.kind == .sftp, RecentTargets.resolvedHost(target, workspace: workspace) == nil { return false }
            let matching = sessions.first { target.kind == .sftp && RecentTargets.sameHost(target, host: $0.host, workspace: workspace) }
            let recipient = matching ?? sessions.first { $0.id == activeSession } ?? sessions.first
            if let recipient { activeSession = recipient.id }
            section = "sftp"
            recentFileRequest = RecentFileRequest(target: target, sessionID: recipient?.id)
            return true
        }
        let host: Host?
        if target.kind == .localTerminal { host = nil }
        else { guard let value = RecentTargets.resolvedHost(target, workspace: workspace) else { return false }; host = value }
        if target.kind == .ssh { connect(host); return true }
        if let session = sessions.first(where: { session in
            let matches = target.kind == .localTerminal ? session.host == nil : host.map { session.matchesEndpoint($0) } == true
            return matches && (session.connected || session.terminal == nil || session.connectionInProgress)
        }) {
            activeSession = session.id; section = "terminal"
            if session.connected { recordRecentSuccess(host, kind: target.kind) }
        } else { connect(host) }
        return true
    }
}
