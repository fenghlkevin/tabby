import Foundation

/// Browsing the vault root shows folders and ungrouped hosts; explicit filters
/// can still find saved connections within those folders.
struct HostLibraryCatalog {
    let hosts: [Host]
    var group = ""
    var query = ""
    var tag = ""
    var favoritesOnly = false
    var sort = "name"
    var workspace: Workspace? = nil
    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isRootBrowse: Bool { group.isEmpty && search.isEmpty && tag.isEmpty && !favoritesOnly }
    var visibleHosts: [Host] {
        hosts.filter { host in
            let scopeMatches = group.isEmpty ? (!isRootBrowse || host.group.isEmpty) : CatalogNames.matches(host.group, group)
            let tags = TagTokens.parse(host.tags)
            let username = workspace.map { RecentTargets.effectiveUsername(host, workspace: $0) } ?? host.username
            return scopeMatches && (!favoritesOnly || host.favorite) && (tag.isEmpty || tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })) &&
                (search.isEmpty || "\(host.name) \(host.address) \(username) \(host.tags) \(host.group)".localizedCaseInsensitiveContains(search))
        }.sorted {
            if sort == "favorite", $0.favorite != $1.favorite { return $0.favorite }
            let lhs = sort == "address" ? $0.address : ($0.name.isEmpty ? $0.address : $0.name)
            let rhs = sort == "address" ? $1.address : ($1.name.isEmpty ? $1.address : $1.name)
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }
}
