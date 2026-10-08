import Foundation

struct CodexModel: Codable, Identifiable {
    struct Effort: Codable { let effort: String }
    struct Tier: Codable { let id: String }
    let slug: String
    let display_name: String
    let visibility: String?
    let supported_reasoning_levels: [Effort]?
    let service_tiers: [Tier]?
    let additional_speed_tiers: [String]?
    var id: String { slug }
    var efforts: [String] { supported_reasoning_levels?.map(\.effort) ?? [] }
    var supportsFast: Bool { service_tiers?.contains { ["fast", "priority"].contains($0.id) } == true || additional_speed_tiers?.contains("fast") == true }
}
enum CodexModelCatalog {
    private struct Cache: Codable { let identity: String; let saved: Date; let models: [CodexModel] }
    static func discover(settings: AISettings, environment: [String: String] = ProcessInfo.processInfo.environment, refresh: Bool = false) async throws -> [CodexModel] {
        guard let executable = CodexRuntime.executable(settings.codexPath, environment: environment) else { throw AppFailure.message("Codex CLI not found / 未找到 Codex CLI") }
        let attributes = try FileManager.default.attributesOfItem(atPath: executable)
        let identity = executable + "|" + String(describing: attributes[.modificationDate]) + "|" + String(describing: attributes[.size])
        let key = "axon.codex.capabilities.v1"
        if !refresh, let data = UserDefaults.standard.data(forKey: key), let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.identity == identity, Date().timeIntervalSince(cache.saved) < 86_400 { return cache.models }
        let task = Task.detached {
            let launch = try CodexRuntime.launch(executable: executable, settings: settings, environment: environment)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("axon-models-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("models.json")
            _ = FileManager.default.createFile(atPath: output.path, contents: nil)
            let writer = try FileHandle(forWritingTo: output)
            defer { try? writer.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launch.executable)
            process.arguments = launch.prefix + ["debug", "models", "-c", "model_provider=\"openai\""]
            process.environment = launch.environment; process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice; process.standardOutput = writer; process.standardError = FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            let deadline = Date().addingTimeInterval(25)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw AppFailure.message("Model discovery timed out / 模型查询超时") }
                guard ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= 4 * 1024 * 1024 else { throw AppFailure.message("Model catalog too large / 模型目录过大") }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else { throw AppFailure.message("Model discovery failed / 模型查询失败") }
            let models = load(url: output)
            guard !models.isEmpty else { throw AppFailure.message("No available models / 未返回可用模型") }
            let data = try JSONEncoder().encode(Cache(identity: identity, saved: Date(), models: models))
            UserDefaults.standard.set(data, forKey: key)
            return models
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CodexModel] {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return load(url: home.appendingPathComponent("models_cache.json"))
    }
    static func load(url: URL) -> [CodexModel] {
        struct Catalog: Codable { let models: [CodexModel] }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [] }
        var seen = Set<String>()
        return catalog.models.filter { $0.visibility != "hide" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
    }
}

/// Finder/Dock apps do not inherit the user's interactive shell PATH.
/// Discover runtimes without executing shell startup files or changing the login configuration.
enum CodexRuntime {
    static func isExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
    static func searchPaths(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        var paths = (environment["PATH"] ?? "").components(separatedBy: ":")
        paths += ["/opt/homebrew/bin", "/usr/local/bin", home.path + "/.npm-global/bin", home.path + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for key in ["NVM_BIN", "FNM_MULTISHELL_PATH"] { if let path = environment[key] { paths.append(key == "FNM_MULTISHELL_PATH" ? path + "/bin" : path) } }
        for base in [home.appendingPathComponent(".nvm/versions/node"), home.appendingPathComponent(".asdf/installs/nodejs"), home.appendingPathComponent(".local/share/fnm/node-versions")] {
            let versions = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for version in versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }).prefix(80) {
                paths.append(version.appendingPathComponent(base.path.contains("fnm") ? "installation/bin" : "bin").path)
            }
        }
        var seen = Set<String>()
        return paths.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }
    static func executable(_ configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = NSString(string: configured.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        if !path.isEmpty { return isExecutable(path) ? (nativeExecutable(path) ?? path) : nil }
        return searchPaths(environment: environment).map { $0 + "/codex" }.first(where: isExecutable).map { nativeExecutable($0) ?? $0 }
    }
    static func nativeExecutable(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        func native(_ url: URL) -> Bool {
            guard isExecutable(url.path), let file = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? file.close() }
            guard let magic = try? file.read(upToCount: 4) else { return false }
            return [Data([0xcf, 0xfa, 0xed, 0xfe]), Data([0xfe, 0xed, 0xfa, 0xcf]), Data([0xca, 0xfe, 0xba, 0xbe]), Data([0xca, 0xfe, 0xba, 0xbf])].contains(magic)
        }
        if native(url) { return url.path }
        guard url.lastPathComponent == "codex.js" else { return nil }
        #if arch(arm64)
        let platform = "codex-darwin-arm64", triple = "aarch64-apple-darwin"
        #else
        let platform = "codex-darwin-x64", triple = "x86_64-apple-darwin"
        #endif
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        for base in [root.appendingPathComponent("node_modules/@openai/" + platform), root.deletingLastPathComponent().appendingPathComponent(platform), root] {
            let binary = base.appendingPathComponent("vendor/" + triple + "/bin/codex")
            if native(binary) { return binary.path }
        }
        return nil
    }
    static func validate(settings: AISettings, models: [CodexModel]) throws {
        let effort = settings.codexReasoningEffort ?? "", speed = settings.codexServiceTier ?? ""
        guard !effort.isEmpty || speed == "priority" else { return }
        guard let model = models.first(where: { $0.slug == settings.codexModel }),
              effort.isEmpty || model.efforts.contains(effort), speed != "priority" || model.supportsFast else {
            throw AppFailure.message("Choose a listed model and supported reasoning effort/speed, or use default options. / 请为列表中的模型选择支持的推理强度和速度，或使用默认选项。")
        }
    }
    static func requiresNode(_ executable: String) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: executable)) else { return false }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 128), let line = String(data: data, encoding: .utf8)?.components(separatedBy: "\n").first else { return false }
        return line.hasPrefix("#!") && line.range(of: #"\bnode\b"#, options: .regularExpression) != nil
    }
    static func node(_ configured: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let path = NSString(string: (configured ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        if !path.isEmpty { return isExecutable(path) ? path : nil }
        return searchPaths(environment: environment).map { $0 + "/node" }.first(where: isExecutable)
    }
    static func launch(executable: String, settings: AISettings, environment: [String: String]) throws -> (executable: String, prefix: [String], environment: [String: String]) {
        var paths = [URL(fileURLWithPath: executable).deletingLastPathComponent().path]
        var launchPath = executable, prefix: [String] = []
        if requiresNode(executable) {
            guard let node = node(settings.codexNodePath, environment: environment) else { throw AppFailure.message("Codex is installed through npm, but Node.js was not found. Set the Node.js executable in AI settings. / Codex 通过 npm 安装，但未找到 Node.js；请在 AI 设置中指定 Node.js 程序路径。") }
            launchPath = node; prefix = [executable]; paths.insert(URL(fileURLWithPath: node).deletingLastPathComponent().path, at: 0)
        }
        paths += searchPaths(environment: environment)
        var result = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "LANG": "en_US.UTF-8"]; result["PATH"] = paths.joined(separator: ":")
        return (launchPath, prefix, result)
    }
    static func appServerArguments() -> [String] {
        var args = ["app-server", "--stdio"]
        for feature in ["shell_tool", "unified_exec", "multi_agent", "hooks", "shell_snapshot", "apps", "plugins", "browser_use", "computer_use", "image_generation", "in_app_browser", "goals", "memories", "code_mode", "tool_suggest"] { args += ["--disable", feature] }
        for config in ["model_provider=\"openai\"", "web_search=\"disabled\"", "approval_policy=\"never\"", "mcp_servers={}", "tools.view_image=false", "project_doc_max_bytes=0", "analytics.enabled=false"] { args += ["-c", config] }
        return args
    }
    static func arguments(settings: AISettings, output: String) throws -> [String] {
        var arguments = ["exec", "--ignore-user-config", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never", "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "multi_agent", "--disable", "hooks", "--disable", "shell_snapshot", "-c", "web_search=\"disabled\"", "-c", "approval_policy=\"never\"", "--json"]
        let model = settings.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.isEmpty || (model.count <= 128 && model.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil) else { throw AppFailure.message("Invalid model ID / 模型 ID 无效") }
        if !model.isEmpty { arguments += ["--model", model] }
        if let effort = settings.codexReasoningEffort, !effort.isEmpty {
            guard ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(effort) else { throw AppFailure.message("Invalid reasoning effort. / 推理强度无效。") }
            arguments += ["-c", "model_reasoning_effort=\"" + effort + "\""]
        }
        if let tier = settings.codexServiceTier, !tier.isEmpty {
            guard ["default", "priority"].contains(tier) else { throw AppFailure.message("Invalid speed selection. / 速度选项无效。") }
            arguments += ["-c", "service_tier=\"" + tier + "\""]
        }
        arguments.append("-"); return arguments
    }
    static func failure(status: Int32, diagnostic: String) -> String {
        let detail = AIContext.sanitize(diagnostic).components(separatedBy: "\n").filter {
            let lower = $0.lowercased()
            return ["error", "env:", "not found", "unsupported", "failed", "unauthorized"].contains(where: lower.contains)
        }.suffix(5).joined(separator: "\n")
        let message = status == 127
            ? "Codex could not find a runtime dependency. Check Codex and Node.js paths in AI settings. / Codex 缺少运行依赖，请检查 AI 设置中的 Codex 和 Node.js 路径。"
            : "Codex failed (\(status)). Check the details below and your model, reasoning effort, speed or login. / Codex 运行失败（\(status)），请根据下方详情检查模型、推理强度、速度或登录。"
        return message + (detail.isEmpty ? "" : "\n" + String(detail.prefix(1200)))
    }
}

/// Only a completed model turn is a successful answer; tool output is never a suggestion.
enum CodexEvents {
    static func answer(_ data: Data) throws -> String {
        var result = "", completed = false
        for line in data.split(separator: 10) {
            guard let event = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], let type = event["type"] as? String else { throw AppFailure.message("Invalid Codex event / Codex 响应事件无效") }
            if ["turn.failed", "error"].contains(type) { throw AppFailure.message(CodexRuntime.failure(status: 1, diagnostic: String(decoding: line, as: UTF8.self))) }
            if type == "turn.completed" { completed = true }
            if type.hasPrefix("item."), let item = event["item"] as? [String: Any] {
                guard let kind = item["type"] as? String, ["agent_message", "reasoning"].contains(kind) else { throw AppFailure.message("Unexpected Codex tool output / Codex 返回了非预期工具输出") }
                if type == "item.completed", kind == "agent_message" { result = item["text"] as? String ?? "" }
            }
        }
        guard completed, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure.message("Codex returned no completed answer / Codex 未返回完整回答") }
        return result
    }
}
