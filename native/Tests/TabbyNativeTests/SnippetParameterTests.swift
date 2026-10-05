import XCTest
@testable import TabbyNative

final class SnippetParameterTests: XCTestCase {
    func testDefinitionsFollowFirstOccurrenceAndPreserveMetadata() throws {
        let definitions = [SnippetParameter(name: "行数", type: .number, defaultValue: "50"), SnippetParameter(name: "removed")]
        let result = try SnippetParameters.synchronized(definitions, body: "tail -n {{行数}} {{路径}}; echo {{行数}}")
        XCTAssertEqual(result.map(\.name), ["行数", "路径"])
        XCTAssertEqual(result[0], definitions[0])
        XCTAssertEqual(result[1].type, .text)
        XCTAssertTrue(result[1].required)
    }

    func testDefaultsRequiredAndTypedValues() throws {
        var snippet = CommandSnippet(); snippet.body = "tail -n {{行数}} {{路径}} {{可选}}"
        snippet.parameters = [.init(name: "行数", type: .number, defaultValue: "100"), .init(name: "路径", type: .path), .init(name: "可选", required: false)]
        XCTAssertThrowsError(try SnippetParameters.expanded(snippet))
        XCTAssertEqual(try SnippetParameters.expanded(snippet, values: ["路径": "/var/log/my app.log"]), "tail -n '100' '/var/log/my app.log' ''")
        for value in ["1; id", "$(id)", "1\n2", "NaN", "1 2", "0x10", "1e2"] {
            XCTAssertThrowsError(try SnippetParameters.expanded(snippet, values: ["行数": value, "路径": "/tmp/log"]))
        }
        XCTAssertNoThrow(try SnippetParameters.expanded(snippet, values: ["行数": "-1.25", "路径": "/tmp/log"]))
        XCTAssertThrowsError(try SnippetParameters.expanded(snippet, values: ["路径": "/tmp/\u{1b}[201~"]))
    }

    func testExpansionKeepsMaliciousValuesLiteralAndDoesNotExpandAgain() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let input = "hello'; $(touch \(marker.path)); `id` {{other}} 中文 空格"
        var snippet = CommandSnippet(); snippet.body = "printf '%s' {{文本}}"
        let command = try SnippetParameters.expanded(snippet, values: ["文本": input])
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-c", command]
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testLiteralTemplatesRemainCompatibleAndUnsafeTemplatesAreRejected() throws {
        for body in ["docker ps --format '{{.Names}}'", "echo '{{name}}'", "echo \"{{name}}\"", "echo \\{{name}}", "echo `printf '{{name}}'`"] {
            var snippet = CommandSnippet(); snippet.body = body
            XCTAssertTrue(try SnippetParameters.placeholders(in: body).isEmpty)
            XCTAssertEqual(try SnippetParameters.expanded(snippet), body)
        }
        for body in ["cat <<EOF\n{{name}}\nEOF", "echo {{unfinished", "echo {{bad name}}"] {
            XCTAssertThrowsError(try SnippetParameters.placeholders(in: body), body)
        }
        XCTAssertEqual(try SnippetParameters.placeholders(in: "echo --name={{name}}/{{suffix}}").map(\.name), ["name", "suffix"])
        var mixed = CommandSnippet(); mixed.body = "docker ps --filter {{filter}} --format '{{.Names}}'"
        XCTAssertEqual(try SnippetParameters.expanded(mixed, values: ["filter": "status=running"]), "docker ps --filter 'status=running' --format '{{.Names}}'")
    }

    func testParameterMetadataRoundTripsAndLegacyDefaultsRemainCompatible() throws {
        let legacy = try JSONDecoder().decode(CommandSnippet.self, from: Data(#"{"body":"pwd","name":"Legacy"}"#.utf8))
        XCTAssertTrue(legacy.parameters.isEmpty)
        XCTAssertEqual(try SnippetParameters.expanded(legacy), "pwd")
        var snippet = legacy; snippet.body = "tail -n {{count}} {{file}}"
        snippet.parameters = [.init(name: "count", type: .number, defaultValue: "20"), .init(name: "file", type: .path, defaultValue: "/tmp/app.log", required: false)]
        XCTAssertEqual(try JSONDecoder().decode(CommandSnippet.self, from: JSONEncoder().encode(snippet)), snippet)
        let partial = try JSONDecoder().decode(SnippetParameter.self, from: Data(#"{"name":"file"}"#.utf8))
        XCTAssertEqual(partial, SnippetParameter(name: "file"))
    }
}
