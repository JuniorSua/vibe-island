import Foundation

/// Local rollout formats are not a public API. Keep their adapter isolated and
/// accept both legacy CLI events and the response items emitted by desktop hosts.
struct CodexTranscript {
    var id: String?
    var cwd: String?
    var parentID: String?
    var termProgram: String?
    var model: String?
    var prompt: String?
    var snippet: String?
    var inTurn: Bool?
    var turnStartedAt: Date?

    mutating func consume(_ line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "session_meta" {
            id = payload["id"] as? String
            cwd = payload["cwd"] as? String
            let source = payload["source"] as? [String: Any]
            let subagent = source?["subagent"] as? [String: Any]
            let spawn = subagent?["thread_spawn"] as? [String: Any]
            parentID = payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String
            switch payload["originator"] as? String {
            case "t3code_desktop": termProgram = "t3code"
            case "Codex Desktop", "codex_desktop": termProgram = "codex-desktop"
            default: break
            }
        }
        if type == "turn_context" {
            model = payload["model"] as? String ?? model
            cwd = payload["cwd"] as? String ?? cwd
        }
        if type == "event_msg" {
            switch payload["type"] as? String {
            case "task_started", "turn_started":
                inTurn = true
                snippet = nil
                turnStartedAt = Self.date(obj["timestamp"] as? String)
            case "task_complete", "task_completed", "turn_completed", "turn_aborted":
                inTurn = false
                if let text = payload["last_agent_message"] as? String { snippet = Self.summary(text) }
            case "user_message":
                if let text = payload["message"] as? String, let clean = Self.userText(text) { prompt = clean }
                inTurn = true
            case "agent_message":
                if let text = payload["message"] as? String { snippet = Self.summary(text) }
            default: break
            }
        }
        if type == "response_item", payload["type"] as? String == "message" {
            let parts = payload["content"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if payload["role"] as? String == "user" {
                // Environment/skill context is also sent with role=user.
                let userParts = parts.compactMap { ($0["text"] as? String).flatMap(Self.userText) }
                if !userParts.isEmpty { prompt = userParts.joined(separator: "\n") }
            } else if payload["role"] as? String == "assistant" {
                snippet = Self.summary(text) ?? snippet
                if payload["phase"] as? String == "final_answer" || payload["channel"] as? String == "final" {
                    inTurn = false
                }
            }
        }
    }

    func isBusy(lastWrite: Date, processAlive: Bool, now: Date = Date()) -> Bool {
        if inTurn == false { return false }
        let age = now.timeIntervalSince(lastWrite)
        if inTurn == true { return processAlive || age < 120 }
        return age < 30 // Older transcripts without lifecycle events.
    }

    private static func userText(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.hasPrefix("<"), !clean.hasPrefix("# AGENTS.md") else { return nil }
        return clean
    }

    private static func summary(_ text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        return clean.isEmpty ? nil : String(clean.prefix(180))
    }

    private static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Incremental reads retain the prompt/start event even after a large tool result
/// pushes them out of the tail. Incomplete JSON lines are saved for the next poll.
final class CodexTranscriptReader {
    private(set) var state = CodexTranscript()
    private var offset: UInt64 = 0
    private var pending = Data()
    private var discardingOversizedLine = false

    func read(_ url: URL) -> CodexTranscript {
        guard let file = try? FileHandle(forReadingFrom: url) else { return state }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        if size < offset {
            state = CodexTranscript(); offset = 0; pending = Data(); discardingOversizedLine = false
        }
        try? file.seek(toOffset: offset)
        while let chunk = try? file.read(upToCount: 65_536), !chunk.isEmpty {
            offset += UInt64(chunk.count)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending = Data(pending[pending.index(after: newline)...])
                if !discardingOversizedLine { state.consume(line) }
                discardingOversizedLine = false
            }
            // Tool output can be enormous. Bound memory without losing the
            // start of the following valid JSON record.
            if pending.count > 4 * 1_024 * 1_024 {
                pending = Data(); discardingOversizedLine = true
            }
        }
        return state
    }
}
