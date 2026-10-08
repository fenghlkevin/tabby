import XCTest
@testable import TabbyNative

final class AITaskWorkingContextTests: XCTestCase {
    func testRecentEvidenceAndGoalSurviveBoundedPromptWithoutChangingJournal() {
        let separator = "\nRequested action (not yet completed; do not replay automatically):\n"
        let base = "Target: fixture\nQuestion: repair fixture\nPermission: approval required\n"
        let actions = (0..<60).map { index in
            "action \(index)\n" + String(repeating: "old logs ", count: 4000) + "\nActual result (untrusted): exit \(index)\nCURRENT-VIM-\(index) INSERT"
        }
        let journal = base + separator + actions.joined(separator: separator)
        let prompt = AITaskWorkingContext.prompt(journal)
        XCTAssertLessThan(prompt.count, 48000)
        XCTAssertLessThan(prompt.count, journal.count / 10)
        XCTAssertTrue(prompt.contains("Question: repair fixture"))
        XCTAssertTrue(prompt.contains("CURRENT-VIM-59 INSERT"))
        XCTAssertTrue(prompt.contains("CURRENT-VIM-58 INSERT"))
        XCTAssertTrue(prompt.contains("omitted"))
        XCTAssertTrue(journal.contains("CURRENT-VIM-0 INSERT"))
    }

    func testShortTranscriptUnchangedAndOlderFailuresRetained() {
        XCTAssertEqual(AITaskWorkingContext.prompt("short goal"), "short goal")
        let separator = "\nRequested action (not yet completed; do not replay automatically):\n"
        let journal = "goal" + separator + "inspect network\n" + String(repeating: "logs", count: 3000) + "\nExit code: 7\nConnection refused" + separator + "inspect service\nExit code: 0" + separator + "verify\nExit code: 0"
        let prompt = AITaskWorkingContext.prompt(journal)
        XCTAssertTrue(prompt.contains("inspect network"))
        XCTAssertTrue(prompt.contains("Connection refused"))
        XCTAssertTrue(prompt.contains("Exit code: 7"))
    }
}
