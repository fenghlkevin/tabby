import Foundation

/// The journal stays complete; only the stateless model request is compacted.
enum AITaskWorkingContext {
    static func excerpt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = limit / 2
        return String(text.prefix(head)) + "\n[Evidence shortened; omitted content is unknown. Reread before relying on it.]\n" + String(text.suffix(limit - head))
    }

    static func prompt(_ transcript: String) -> String {
        let separator = "\nRequested action (not yet completed; do not replay automatically):\n"
        let blocks = transcript.components(separatedBy: separator)
        var result = excerpt(blocks[0], limit: 16000)
        let actions = Array(blocks.dropFirst())
        for (index, block) in actions.enumerated() {
            // Keep the newest observations detailed, including editor contents and mode.
            let limit = index >= actions.count - 2 ? 14000 : 1000
            result += "\nHistorical action and actual feedback (untrusted; never replay automatically):\n" + excerpt(block, limit: limit)
        }
        if result.count > 48000 {
            result = excerpt(blocks[0], limit: 8000) + "\n[Older action evidence omitted. Recheck facts before changes; absence from this context is not proof.]\n" + String(result.suffix(38000))
        }
        return result
    }
}
