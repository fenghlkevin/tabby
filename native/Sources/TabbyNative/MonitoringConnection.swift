import Foundation

/// An explicit terminal action uses the selected monitoring identity, including
/// every jump hop. Browsing or selecting a monitor card never invokes it.
@MainActor enum MonitoringTerminalAction {
    case session(UUID)
    case connect(Host)

    static func savedTargetID(for host: Host, workspace: Workspace) -> MonitoringTargetID {
        let effective = GroupDefaults.resolved(host, workspace: workspace)
        return MonitoringTargetID(address: effective.address, port: effective.port,
                                  username: RecentTargets.effectiveUsername(effective, workspace: workspace),
                                  route: MonitoringCenter.savedRoute(for: host, workspace: workspace))
    }

    static func resolve(_ id: MonitoringTargetID, store: AppStore) -> Self? {
        // A live card describes the authenticated connection, even after the
        // corresponding saved host has been edited. Focus that exact session.
        if let session = store.sessions.first(where: {
            $0.connected && $0.client?.isConnected == true && store.monitoring.targetID(for: $0) == id
        }) { return .session(session.id) }

        let saved = store.workspace.hosts.first { savedTargetID(for: $0, workspace: store.workspace) == id }
        if let session = store.sessions.first(where: { session in
            // makeView() schedules the connection before connectionInProgress
            // is set. Reuse that pending task when Connect is clicked again.
            guard session.connectionInProgress || (!session.connected && (session.terminal == nil || session.task != nil)),
                  let raw = session.host,
                  store.monitoring.targetID(for: session) == id,
                  savedTargetID(for: GroupDefaults.connectionSource(raw, workspace: store.workspace), workspace: store.workspace) == id else { return false }
            return saved.map { session.matchesEndpoint($0) } ?? true
        }) { return .session(session.id) }
        if let saved { return .connect(saved) }

        // Quick connections still have their original authentication source.
        // Do not fabricate a fresh password-only profile from the display IP.
        if let original = store.sessions.first(where: { store.monitoring.targetID(for: $0) == id })?.host,
           !store.deletedHostIDs.contains(original.id) {
            let current = GroupDefaults.connectionSource(original, workspace: store.workspace)
            guard savedTargetID(for: current, workspace: store.workspace) == id else { return nil }
            return .connect(current)
        }
        return nil
    }
}

@MainActor extension AppStore {
    @discardableResult func openMonitoringTerminal(_ id: MonitoringTargetID, activate: Bool = true) -> Bool {
        guard let action = MonitoringTerminalAction.resolve(id, store: self) else {
            error = text("This host is no longer available. Return to the monitoring overview.", "此主机已不可用，请返回监控概览。")
            return false
        }
        switch action {
        case .session(let sessionID):
            if activate {
                activeSession = sessionID
                section = "terminal"
            } else if let session = sessions.first(where: { $0.id == sessionID }), session.terminal == nil {
                _ = session.makeView()
            }
        case .connect(let host):
            do {
                // Validate effective metadata while preserving the raw profile
                // so group/shared credentials are read from their correct owner.
                _ = try ConnectionValidation.host(host, workspace: workspace, chinese: chinese)
                if activate {
                    connect(host)
                } else {
                    // Start the SSH session without changing navigation or
                    // focus. Monitoring begins sampling when it connects.
                    let session = TerminalSession(host: host, store: self)
                    sessions.append(session)
                    _ = session.makeView()
                }
            } catch { self.error = error.localizedDescription; return false }
        }
        return true
    }
}
