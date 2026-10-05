import Foundation

extension AppStore {
    /// Clear the complete history; the view's search only affects display.
    /// Restore the full workspace if saving fails, including save's normalization.
    @discardableResult func clearActivityLogs() -> Bool {
        guard !workspace.logs.isEmpty else { return true }
        let previous = workspace
        workspace.logs.removeAll()
        if save() { return true }
        workspace = previous
        return false
    }
}
