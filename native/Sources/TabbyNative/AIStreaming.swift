import Foundation

/// Provider SSE events carry public answer text only; reasoning and tool payloads are ignored.
struct AIStreamEvents {
    var text = ""
    var completed = false
    var payload: [String] = []
    mutating func line(_ line: String, backend: AIBackend) throws {
        if line.hasPrefix("data:") { payload.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)) }
        else if line.isEmpty, !payload.isEmpty {
            let value = payload.joined(separator: "\n"); payload.removeAll()
            if value == "[DONE]" { completed = true; return }
            guard let event = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw AppFailure.message("Invalid stream / 流式响应无效") }
            if event["error"] != nil || event["type"] as? String == "error" { throw AppFailure.message("Provider stream failed / 服务流式响应失败") }
            if backend == .claude {
                if event["type"] as? String == "content_block_delta", let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" { text += delta["text"] as? String ?? "" }
                if event["type"] as? String == "message_stop" { completed = true }
                if let delta = event["delta"] as? [String: Any], delta["stop_reason"] as? String == "max_tokens" { throw AppFailure.message("Answer reached its length limit / 回答达到长度上限") }
            } else {
                if let choice = (event["choices"] as? [[String: Any]])?.first {
                    text += (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
                    if choice["finish_reason"] as? String == "length" { throw AppFailure.message("Answer reached its length limit / 回答达到长度上限") }
                    if let reason = choice["finish_reason"] as? String, !["stop", "length"].contains(reason) { throw AppFailure.message("Unexpected provider completion / 服务返回了非预期结束状态") }
                }
            }
            guard text.utf8.count <= 2 * 1024 * 1024 else { throw AppFailure.message("Answer too large / 回答过大") }
        }
    }
    func result() throws -> String {
        guard completed, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure.message("Stream ended before a complete answer / 流式连接结束，未收到完整回答") }
        return text
    }
}

enum CodexReplyError: Error { case empty }

struct CodexAnswerStream {
    var text = ""
    var completed = false
    mutating func event(_ event: [String: Any]) throws {
        if let error = event["error"] as? [String: Any] { throw AppFailure.message(AIContext.sanitize(error["message"] as? String ?? "Codex request failed")) }
        let method = event["method"] as? String ?? "", params = event["params"] as? [String: Any] ?? [:]
        if method == "error", params["willRetry"] as? Bool != true { throw AppFailure.message(AIContext.sanitize(String(describing: params["error"] ?? "Codex stream failed"))) }
        if method == "item/agentMessage/delta" { text += params["delta"] as? String ?? "" }
        if ["item/started", "item/completed"].contains(method), let item = params["item"] as? [String: Any], let type = item["type"] as? String {
            guard ["userMessage", "agentMessage", "reasoning"].contains(type) else { throw AppFailure.message("Unexpected Codex tool output / Codex 返回了非预期工具输出") }
            if method == "item/completed", type == "agentMessage" { takeMessage(item) }
        }
        if method == "turn/completed" {
            guard let turn = params["turn"] as? [String: Any] else { throw AppFailure.message("Invalid Codex completion / Codex 结束响应无效") }
            guard turn["status"] as? String == "completed" else {
                let detail = (turn["error"] as? [String: Any])?["message"] as? String
                throw AppFailure.message("Codex turn failed or stopped / Codex 回答失败或已停止" + (detail.map { "：" + AIContext.sanitize($0) } ?? ""))
            }
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "agentMessage" { takeMessage(item) }
                else if let type = item["type"] as? String, !["userMessage", "reasoning"].contains(type) { throw AppFailure.message("Unexpected Codex tool output / Codex 返回了非预期工具输出") }
            }
            completed = true
        }
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw AppFailure.message("Answer too large / 回答过大") }
    }
    private mutating func takeMessage(_ item: [String: Any]) {
        // Some completions carry only the turn snapshot; an empty snapshot must
        // never erase text already received from public message deltas.
        if let value = item["text"] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = value }
    }
    func result() throws -> String {
        guard completed else { throw AppFailure.message("Codex answer incomplete / Codex 回答尚未完成") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CodexReplyError.empty }
        return text
    }

}
