import Foundation

@main
final class CodexWatcherTests {
    private var files: [URL] = []
    deinit { files.forEach { try? FileManager.default.removeItem(at: $0) } }

    static func main() throws {
        let tests = CodexWatcherTests()
        try tests.testDesktopPromptModelAndHostSurviveLargeToolOutput()
        try tests.testCompletionWinsOverRecentWriteAndResumeStartsNewTurn()
        try tests.testPartialJSONAndSplitUnicodeAreRetried()
        try tests.testTruncatedTranscriptResetsAndNestedSubagentsAreRecognized()
        try tests.testLegacyTimeoutAndAssistantOnlyRecap()
        tests.testRepeatedProcessLaunchesAndTimeoutRecovery()
        print("PASS: 6 Codex regression scenarios, including 80 subprocess launches and timeout recovery")
    }
    private func line(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: [
            "type": type, "timestamp": "2026-09-10T16:00:00.000Z", "payload": payload
        ])
        data.append(10)
        return data
    }

    private func temporaryFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try Data().write(to: url)
        files.append(url)
        return url
    }

    func testDesktopPromptModelAndHostSurviveLargeToolOutput() throws {
        let file = try temporaryFile()
        let prompt = String(repeating: "Keep the complete prompt. ", count: 10)
        var data = try line("session_meta", ["id": "desktop", "cwd": "/repo", "originator": "t3code_desktop"])
        data += try line("event_msg", ["type": "task_started"])
        data += try line("turn_context", ["model": "gpt-test"])
        data += try line("response_item", ["type": "message", "role": "user", "content": [
            ["type": "input_text", "text": "<environment_context>ignore</environment_context>"],
            ["type": "input_text", "text": prompt]
        ]])
        data += try line("response_item", ["type": "custom_tool_call_output", "output": String(repeating: "x", count: 300_000)])
        try data.write(to: file)
        let state = CodexTranscriptReader().read(file)
        checkEqual(state.id, "desktop")
        checkEqual(state.prompt, prompt.trimmingCharacters(in: .whitespaces))
        checkEqual(state.model, "gpt-test")
        checkEqual(state.termProgram, "t3code")
        checkTrue(state.isBusy(lastWrite: Date().addingTimeInterval(-3600), processAlive: true))
        checkFalse(state.isBusy(lastWrite: Date().addingTimeInterval(-3600), processAlive: false))
    }

    func testCompletionWinsOverRecentWriteAndResumeStartsNewTurn() throws {
        var state = CodexTranscript()
        state.consume(try line("event_msg", ["type": "task_started"]))
        state.consume(try line("event_msg", ["type": "task_complete", "last_agent_message": "Finished"]))
        checkFalse(state.isBusy(lastWrite: Date(), processAlive: true))
        checkEqual(state.snippet, "Finished")
        state.consume(try line("event_msg", ["type": "task_started"]))
        checkTrue(state.isBusy(lastWrite: Date(), processAlive: true))
        checkNil(state.snippet)
        state.consume(try line("event_msg", ["type": "turn_aborted"]))
        checkFalse(state.isBusy(lastWrite: Date(), processAlive: true))
    }

    func testPartialJSONAndSplitUnicodeAreRetried() throws {
        let file = try temporaryFile()
        let reader = CodexTranscriptReader()
        let data = try line("event_msg", ["type": "user_message", "message": "Fix café 🤖"])
        let split = data.firstIndex(of: 0xF0) ?? data.count / 2
        try data.prefix(split + 1).write(to: file)
        checkNil(reader.read(file).prompt)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: data.dropFirst(split + 1))
        try handle.close()
        checkEqual(reader.read(file).prompt, "Fix café 🤖")
    }

    func testTruncatedTranscriptResetsAndNestedSubagentsAreRecognized() throws {
        let file = try temporaryFile()
        let reader = CodexTranscriptReader()
        try line("session_meta", ["id": "child", "cwd": String(repeating: "/repo", count: 100),
            "source": ["subagent": ["thread_spawn": ["parent_thread_id": "parent"]]]]).write(to: file)
        checkEqual(reader.read(file).parentID, "parent")
        try line("session_meta", ["id": "replacement"]).write(to: file)
        checkEqual(reader.read(file).id, "replacement")
        checkNil(reader.read(file).parentID)
    }

    func testLegacyTimeoutAndAssistantOnlyRecap() throws {
        var state = CodexTranscript()
        checkTrue(state.isBusy(lastWrite: Date(), processAlive: false))
        checkFalse(state.isBusy(lastWrite: Date().addingTimeInterval(-40), processAlive: true))
        state.consume(try line("response_item", ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "Build the app"]]]))
        checkNil(state.snippet)
        state.consume(try line("response_item", ["type": "message", "role": "assistant", "phase": "final_answer",
            "content": [["type": "output_text", "text": "Built successfully"]]]))
        checkEqual(state.snippet, "Built successfully")
        checkFalse(state.isBusy(lastWrite: Date(), processAlive: true))
    }

    func testRepeatedProcessLaunchesAndTimeoutRecovery() {
        // More than the 64 workers exhausted by the old waitUntilExit leak.
        for _ in 0..<80 {
            checkEqual(ProcessCapture.run("/bin/echo", ["ok"], timeout: 2), "ok\n")
        }
        let start = Date()
        checkNil(ProcessCapture.run("/bin/sleep", ["10"], timeout: 0.05))
        checkLessThan(Date().timeIntervalSince(start), 1)
        checkEqual(ProcessCapture.run("/bin/echo", ["recovered"], timeout: 2), "recovered\n")
    }
}

private func checkEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func checkTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}
private func checkFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "Expected false", file: file, line: line)
}
private func checkNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "Expected nil", file: file, line: line)
}
private func checkLessThan<T: Comparable>(_ actual: T, _ limit: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual < limit, "Exceeded limit", file: file, line: line)
}
