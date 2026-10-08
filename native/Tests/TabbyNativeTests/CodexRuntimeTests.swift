import AppKit
import SwiftUI
import XCTest
@testable import TabbyNative

@MainActor final class CodexRuntimeTests: XCTestCase {
    private var desktopEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }
    func testLegacySettingsMigrationAndArguments() throws {
        var original = AISettings(); original.codexModel = "saved-model"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["codexNodePath", "codexReasoningEffort", "codexServiceTier"] { object.removeValue(forKey: key) }
        let migrated = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.codexModel, "saved-model"); XCTAssertNil(migrated.codexNodePath)
        var configured = migrated; configured.codexReasoningEffort = "high"; configured.codexServiceTier = "priority"
        let arguments = try CodexRuntime.arguments(settings: configured, output: "/tmp/answer")
        XCTAssertTrue(arguments.contains("model_reasoning_effort=\"high\"")); XCTAssertTrue(arguments.contains("service_tier=\"priority\""))
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "saved-model")
        XCTAssertTrue(arguments.contains("read-only")); XCTAssertTrue(arguments.contains("shell_tool"))
        configured.codexReasoningEffort = "invalid"; XCTAssertThrowsError(try CodexRuntime.arguments(settings: configured, output: "answer"))
        configured.codexReasoningEffort = nil; configured.codexServiceTier = "invalid"; XCTAssertThrowsError(try CodexRuntime.arguments(settings: configured, output: "answer"))
        XCTAssertNil(CodexRuntime.executable("/tmp"))
        XCTAssertFalse(CodexRuntime.failure(status: 127, diagnostic: "env: node: No such file or directory").contains("codex login"))
        XCTAssertFalse(CodexRuntime.failure(status: 1, diagnostic: "error: api_key=secret-value failed").contains("secret-value"))
    }
    func testCatalogUsesAdvertisedCapabilitiesAndIgnoresHiddenModels() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = #"{"models":[{"slug":"model-a","display_name":"Model A","visibility":"list","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"service_tiers":[{"id":"priority"}]},{"slug":"hidden","display_name":"Hidden","visibility":"hide"},{"slug":"model-b","display_name":"Model B","visibility":"list","supported_reasoning_levels":[{"effort":"medium"}],"service_tiers":[]}]}"#
        try Data(json.utf8).write(to: file)
        let models = CodexModelCatalog.load(url: file)
        XCTAssertEqual(models.map(\.slug), ["model-a", "model-b"])
        XCTAssertEqual(models[0].efforts, ["low", "high"]); XCTAssertTrue(models[0].supportsFast); XCTAssertFalse(models[1].supportsFast)
    }
    func testNpmCodexRunsWithDesktopPATHAndReceivesConfiguration() async throws {
        guard CodexRuntime.node(nil, environment: desktopEnvironment) != nil else { throw XCTSkip("Node.js is not installed on this test host") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-node-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex.js")
        try #"""
        #!/usr/bin/env node
        const fs = require('node:fs');
        const args = process.argv.slice(2);
        if (args[0] === 'debug') {
          console.log(JSON.stringify({models:[{slug:'fixture-model',display_name:'Fixture',visibility:'list',supported_reasoning_levels:[{effort:'high'}],service_tiers:[{id:'priority'}]}]})); process.exit(0);
        }
        require('node:readline').createInterface({input:process.stdin}).on('line',line=>{
          const e=JSON.parse(line),emit=x=>console.log(JSON.stringify(x));
          if(e.method==='initialize') emit({id:1,result:{}});
          if(e.method==='thread/start') {
            if(e.params.model!=='fixture-model'||e.params.config.model_reasoning_effort!=='high'||e.params.serviceTier!=='priority') process.exit(3);
            emit({id:2,result:{thread:{id:'fixture'}}});
          }
          if(e.method==='turn/start') {
            emit({id:3,result:{}});
            emit({method:'item/agentMessage/delta',params:{delta:'DESKTOP_NODE_OK'}});
            emit({method:'turn/completed',params:{turn:{status:'completed'}}});
          }
        });
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        XCTAssertTrue(CodexRuntime.requiresNode(script.path))
        let ai = AIAssistant(fileURL: root.appendingPathComponent("settings.json"), cliEnvironment: desktopEnvironment)
        ai.settings.codexPath = script.path; ai.settings.codexModel = "fixture-model"; ai.settings.codexReasoningEffort = "high"; ai.settings.codexServiceTier = "priority"
        ai.prepare(source: "fixture", text: "no host data", sessionID: nil, question: "test")
        ai.send(); for _ in 0..<150 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertEqual(ai.answer, "DESKTOP_NODE_OK", ai.error)
        ai.settings.codexNodePath = "/missing/node"
        ai.question = "test invalid Node path"; ai.send(); for _ in 0..<50 { if !ai.busy { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ai.error.contains("Node.js")); XCTAssertFalse(ai.error.contains("codex login"))
    }
    func testCatalogCacheRefreshAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("axon-catalog-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex"), count = root.appendingPathComponent("calls")
        let script = "#!/bin/sh\nprintf 'x' >> '" + count.path + "'\nprintf '%s\\n' '{\"models\":[{\"slug\":\"fixture\",\"display_name\":\"Fixture\",\"visibility\":\"list\"}]}'\n"
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var settings = AISettings(); settings.codexPath = cli.path
        _ = try await CodexModelCatalog.discover(settings: settings)
        _ = try await CodexModelCatalog.discover(settings: settings)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "x")
        _ = try await CodexModelCatalog.discover(settings: settings, refresh: true)
        XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "xx")
        try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: cli, atomically: true, encoding: .utf8)
        let task = Task { try await CodexModelCatalog.discover(settings: settings, refresh: true) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled discovery must stop") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testNativePreferenceAndCapabilityValidation() throws {
        if let wrapper = CodexRuntime.executable("", environment: desktopEnvironment) {
            XCTAssertNotNil(CodexRuntime.nativeExecutable(wrapper))
            XCTAssertFalse(CodexRuntime.requiresNode(wrapper))
            let launch = try CodexRuntime.launch(executable: wrapper, settings: AISettings(), environment: ["PATH": "/usr/bin:/bin", "OPENAI_API_KEY": "do-not-inherit", "NODE_OPTIONS": "injected"])
            XCTAssertTrue(launch.prefix.isEmpty); XCTAssertNil(launch.environment["OPENAI_API_KEY"]); XCTAssertNil(launch.environment["NODE_OPTIONS"])
        }
        let model = CodexModel(slug: "basic", display_name: "Basic", visibility: "list", supported_reasoning_levels: [.init(effort: "low")], service_tiers: [], additional_speed_tiers: [])
        var settings = AISettings(); settings.codexModel = "basic"; settings.codexReasoningEffort = "high"
        XCTAssertThrowsError(try CodexRuntime.validate(settings: settings, models: [model]))
        settings.codexReasoningEffort = "low"; XCTAssertNoThrow(try CodexRuntime.validate(settings: settings, models: [model]))
        settings.codexServiceTier = "priority"; XCTAssertThrowsError(try CodexRuntime.validate(settings: settings, models: [model]))
        settings.codexModel = "--bad"; XCTAssertThrowsError(try CodexRuntime.arguments(settings: settings, output: "unused"))
    }
    func testEventsRequireCompletedAnswerAndRejectTools() throws {
        let answer = Data(#"{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}"#.utf8)
        XCTAssertThrowsError(try CodexEvents.answer(answer))
        XCTAssertEqual(try CodexEvents.answer(answer + Data("\n{\"type\":\"turn.completed\"}\n".utf8)), "ok")
        XCTAssertThrowsError(try CodexEvents.answer(Data(#"{"type":"turn.failed"}"#.utf8)))
        XCTAssertThrowsError(try CodexEvents.answer(Data(#"{"type":"item.completed","item":{"type":"command_execution","text":"unsafe"}}"#.utf8)))
    }
    func testInstalledCLIWithDesktopPATH() throws {
        guard let executable = CodexRuntime.executable("", environment: desktopEnvironment) else { throw XCTSkip("Codex is not installed on this test host") }
        let launch = try CodexRuntime.launch(executable: executable, settings: AISettings(), environment: desktopEnvironment)
        let child = Process(); child.executableURL = URL(fileURLWithPath: launch.executable); child.arguments = launch.prefix + ["--version"]; child.environment = launch.environment
        let output = Pipe(); child.standardOutput = output; child.standardError = output
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}
