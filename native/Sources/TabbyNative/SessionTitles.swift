import Foundation

/// Display labels are derived from immutable creation order, independently of tab layout.
enum SessionTitleCatalog {
    struct Entry {
        let id: UUID
        let baseTitle: String
        let creationOrder: UInt64
    }

    static func labels(for entries: [Entry]) -> [UUID: String] {
        let ordered = entries.sorted {
            $0.creationOrder == $1.creationOrder ? $0.id.uuidString < $1.id.uuidString : $0.creationOrder < $1.creationOrder
        }
        let counts = Dictionary(grouping: ordered, by: \.baseTitle).mapValues(\.count)
        let reserved = Set(ordered.map(\.baseTitle))
        var generated = Set<String>()
        var nextNumbers: [String: Int] = [:]
        var labels: [UUID: String] = [:]
        for entry in ordered {
            guard counts[entry.baseTitle, default: 0] > 1 else {
                labels[entry.id] = entry.baseTitle
                continue
            }
            var number = nextNumbers[entry.baseTitle, default: 1]
            var candidate = "\(entry.baseTitle) (\(number))"
            // A real configured name such as "prod (1)" keeps its spelling.
            // Generated suffixes skip reserved base labels to avoid ambiguous tabs.
            while reserved.contains(candidate) || generated.contains(candidate) {
                number += 1; candidate = "\(entry.baseTitle) (\(number))"
            }
            nextNumbers[entry.baseTitle] = number + 1
            generated.insert(candidate); labels[entry.id] = candidate
        }
        return labels
    }
}

@MainActor extension AppStore {
    var sessionTitles: [UUID: String] {
        SessionTitleCatalog.labels(for: sessions.map {
            SessionTitleCatalog.Entry(id: $0.id, baseTitle: $0.title, creationOrder: $0.creationOrder)
        })
    }
    func sessionTitle(_ session: TerminalSession) -> String { sessionTitles[session.id] ?? session.title }
}

@MainActor extension TerminalSession {
    var displayTitle: String { store.sessionTitle(self) }
}
