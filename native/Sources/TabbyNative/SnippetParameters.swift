import Foundation

enum SnippetParameterType: String, Codable, CaseIterable {
    case text, number, path
    func title(chinese: Bool) -> String {
        switch self {
        case .text: return chinese ? "文本" : "Text"
        case .number: return chinese ? "数字" : "Number"
        case .path: return chinese ? "路径" : "Path"
        }
    }
}

struct SnippetParameter: Codable, Equatable, Identifiable {
    var name: String
    var type: SnippetParameterType = .text
    var defaultValue = ""
    var required = true
    var id: String { name }

    init(name: String, type: SnippetParameterType = .text, defaultValue: String = "", required: Bool = true) {
        self.name = name; self.type = type; self.defaultValue = defaultValue; self.required = required
    }
    enum CodingKeys: String, CodingKey { case name, type, defaultValue, required }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decodeIfPresent(SnippetParameterType.self, forKey: .type) ?? .text
        defaultValue = try values.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
        required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

/// Parameters represent one shell argument. Replacements are never parsed again,
/// and quotes in user values cannot become shell syntax.
enum SnippetParameters {
    struct Placeholder { let name: String; let range: Range<String.Index> }

    static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func placeholders(in body: String, chinese: Bool = false) throws -> [Placeholder] {
        var result: [Placeholder] = []
        var index = body.startIndex
        var quote: Character?
        var escaped = false
        while index < body.endIndex {
            let character = body[index]
            let next = body.index(after: index)
            // Quoted and escaped braces are shell literals. Keeping them intact
            // preserves commands such as docker --format '{{.Names}}'.
            if character == "{", next < body.endIndex, body[next] == "{", !escaped, quote == nil {
                guard let close = body.range(of: "}}", range: body.index(after: next)..<body.endIndex) else {
                    throw AppFailure.message(chinese ? "参数占位符缺少 }}" : "A parameter placeholder is missing }}")
                }
                let name = String(body[body.index(after: next)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
                guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
                    throw AppFailure.message(chinese ? "参数名称只能包含文字、数字、下划线、点和连字符。" : "Parameter names may contain letters, numbers, underscores, dots, and hyphens.")
                }
                result.append(Placeholder(name: name, range: index..<close.upperBound))
                index = close.upperBound; continue
            }
            if escaped { escaped = false }
            else if character == "\\", quote != "'" { escaped = true }
            else if let current = quote { if character == current { quote = nil } }
            else if character == "'" || character == "\"" || character == "`" { quote = character }
            index = next
        }
        guard result.isEmpty || !body.contains("<<") else {
            throw AppFailure.message(chinese ? "参数占位符不能用于 heredoc。请使用普通命令参数。" : "Parameter placeholders cannot be used in heredocs. Use normal command arguments.")
        }
        return result
    }

    static func synchronized(_ definitions: [SnippetParameter], body: String, chinese: Bool = false) throws -> [SnippetParameter] {
        let tokens = try placeholders(in: body, chinese: chinese)
        var seen: Set<String> = []
        return tokens.compactMap { token in
            guard seen.insert(token.name).inserted else { return nil }
            return definitions.first { $0.name == token.name } ?? SnippetParameter(name: token.name)
        }
    }

    static func expanded(_ snippet: CommandSnippet, values: [String: String] = [:], chinese: Bool = false) throws -> String {
        let tokens = try placeholders(in: snippet.body, chinese: chinese)
        let definitions = try synchronized(snippet.parameters, body: snippet.body, chinese: chinese)
        var substitutions: [String: String] = [:]
        for definition in definitions {
            let value = values[definition.name] ?? definition.defaultValue
            guard !definition.required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppFailure.message(chinese ? "请填写参数「\(definition.name)」" : "Enter a value for \(definition.name)")
            }
            guard value.utf8.count <= 64 * 1024,
                  !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                throw AppFailure.message(chinese ? "参数「\(definition.name)」不能包含控制字符或超过 64 KB。" : "\(definition.name) cannot contain control characters or exceed 64 KB.")
            }
            if definition.type == .number, !value.isEmpty {
                guard value.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil else {
                    throw AppFailure.message(chinese ? "参数「\(definition.name)」需要填写数字。" : "\(definition.name) must be a number.")
                }
            }
            substitutions[definition.name] = shellArgument(value)
        }
        var result = "", cursor = snippet.body.startIndex
        for token in tokens {
            result += snippet.body[cursor..<token.range.lowerBound]
            result += substitutions[token.name] ?? "''"
            cursor = token.range.upperBound
        }
        result += snippet.body[cursor...]
        try SnippetInput.validate(result, chinese: chinese)
        return result
    }
}
