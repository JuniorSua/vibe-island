import Foundation
import AppKit

/// Normalizes incoming hook events into Session mutations and decides whether
/// a connection must be held for an interactive response.
@MainActor
final class EventHandler {
    static let shared = EventHandler()

    /// Tools that are always intercepted for GUI interaction.
    private let interactiveTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Tools held for GUI approval when a session has "approve from notch" on.
    private let approvableTools: Set<String> = ["Bash", "Edit", "Write", "NotebookEdit"]

    func handle(data: Data, reply: @escaping (String) -> Void, onHold: (String, UUID) -> Void) {
        guard let event = try? JSONDecoder().decode(WireEvent.self, from: data) else {
            NSLog("VibeIsland: undecodable event: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            reply("{}")
            return
        }
        let p = event.payload
        guard let sessionID = p.session_id else { reply("{}"); return }

        let store = SessionStore.shared

        // Debug/UI-only events never create sessions.
        if p.hook_event_name == "VibeShow" {
            store.expanded = true
            NotchPanelController.shared?.showForAttention()
            reply("{}")
            return
        }
        // Test hook: shove the panel out of position to prove the heartbeat
        // drags it back flush with the screen top.
        if p.hook_event_name == "VibeNudge" {
            NotchPanelController.shared?.nudgeForTesting(down: 40)
            reply("{}")
            return
        }
        // Exact replica of the hover path: expand WITHOUT re-laying out or
        // keying the window, so tests exercise what the mouse actually does.
        if p.hook_event_name == "VibeHover" {
            store.expanded = true
            NotchPanelController.shared?.logGeometry(tag: "hover-expand")
            reply("{}")
            return
        }

        ensureSession(sessionID: sessionID, event: event)

        switch p.hook_event_name ?? "" {
        case "SessionStart":
            store.update(id: sessionID) { s in
                s.status = .working
            }
            reply("{}")

        case "UserPromptSubmit":
            store.update(id: sessionID) { s in
                if let prompt = p.prompt, !prompt.isEmpty {
                    s.title = Self.titleFrom(prompt: prompt)
                    s.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                s.status = .working
                s.recap = nil
                s.pendingRequest = nil
            }
            reply("{}")

        case "PreToolUse":
            handlePreToolUse(event, sessionID: sessionID, reply: reply, onHold: onHold)

        case "PostToolUse":
            store.update(id: sessionID) { s in
                if let last = s.activity.indices.last,
                   s.activity[last].toolName == (p.tool_name ?? ""),
                   s.activity[last].detail == nil {
                    s.activity[last].detail = Self.resultDetail(toolName: p.tool_name ?? "", response: p.tool_response)
                }
                s.status = .working
            }
            reply("{}")

        case "Notification":
            let message = p.message ?? ""
            store.update(id: sessionID) { s in
                s.status = .waiting
                s.recap = message
            }
            SoundEngine.shared.play(.needsAttention)
            reply("{}")

        case "Stop", "SubagentStop":
            store.update(id: sessionID) { s in
                s.status = .done
                s.pendingRequest = nil
            }
            SoundEngine.shared.play(.done)
            reply("{}")
            // Opportunistic model tag from the transcript (once per session).
            if let session = store.session(id: sessionID), session.model == nil,
               let path = session.transcriptPath {
                Task.detached(priority: .utility) {
                    guard let model = TranscriptInfo.model(of: path) else { return }
                    await MainActor.run {
                        SessionStore.shared.update(id: sessionID) { $0.model = model }
                    }
                }
            }

        case "SessionEnd":
            store.update(id: sessionID) { s in
                s.status = .ended
                s.pendingRequest = nil
            }
            reply("{}")

        default:
            reply("{}")
        }
    }

    // MARK: - PreToolUse

    private func handlePreToolUse(_ event: WireEvent, sessionID: String,
                                  reply: @escaping (String) -> Void,
                                  onHold: (String, UUID) -> Void) {
        let store = SessionStore.shared
        let p = event.payload
        let tool = p.tool_name ?? "?"

        // Always log to the activity feed.
        store.update(id: sessionID) { s in
            s.status = .working
            s.activity.append(ActivityEntry(
                timestamp: Date(),
                toolName: tool,
                summary: Self.activitySummary(toolName: tool, input: p.tool_input)
            ))
            if s.activity.count > 30 { s.activity.removeFirst(s.activity.count - 30) }
        }

        let session = store.session(id: sessionID)
        let holdForApproval = session?.approveFromNotch == true && approvableTools.contains(tool)
        // Demo/testing escape hatch: an event may force interactive handling.
        let forceHold = p.tool_input?["vibe_force_hold"] != nil

        guard interactiveTools.contains(tool) || holdForApproval || forceHold else {
            reply("{}")
            return
        }

        let request: PendingRequest
        switch tool {
        case "AskUserQuestion":
            let (title, body, options) = Self.parseQuestion(p.tool_input)
            request = PendingRequest(kind: .question, toolName: tool, title: title, body: body, options: options)
        case "ExitPlanMode":
            let plan = p.tool_input?["plan"]?.stringValue ?? ""
            request = PendingRequest(kind: .plan, toolName: tool, title: "Plan ready for review", body: plan)
        default:
            request = PendingRequest(
                kind: .permission,
                toolName: tool,
                title: Self.activitySummary(toolName: tool, input: p.tool_input),
                body: Self.permissionBody(toolName: tool, input: p.tool_input)
            )
        }

        let token = store.hold(sessionID: sessionID, reply: reply)
        onHold(sessionID, token)
        store.update(id: sessionID) { s in
            s.status = .waiting
            s.pendingRequest = request
        }
        store.expanded = true
        SoundEngine.shared.play(request.kind == .question ? .question : .needsAttention)
        NotchPanelController.shared?.showForAttention()
    }

    // MARK: - Session bootstrap

    private func ensureSession(sessionID: String, event: WireEvent) {
        let store = SessionStore.shared
        let p = event.payload
        if var existing = store.session(id: sessionID) {
            var changed = false
            // A session reviving after the app restarted (or after it ended)
            // starts a fresh clock — "93h" elapsed labels help no one.
            if existing.status == .ended {
                existing.startedAt = Date()
                changed = true
            }
            if existing.tty == nil, let tty = event.tty, !tty.isEmpty, tty != "??" { existing.tty = tty; changed = true }
            if existing.termProgram == nil, let tp = event.term_program, !tp.isEmpty { existing.termProgram = tp; changed = true }
            if existing.cwd == nil, let cwd = p.cwd { existing.cwd = cwd; changed = true }
            if existing.transcriptPath == nil, let tp = p.transcript_path { existing.transcriptPath = tp; changed = true }
            if changed { store.upsert(existing) }
            return
        }
        var session = Session(
            id: sessionID,
            agent: AgentKind.from(source: event.source ?? "unknown"),
            title: p.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "New session",
            cwd: p.cwd,
            termProgram: event.term_program,
            termSession: event.term_session,
            tty: (event.tty == "??" ? nil : event.tty),
            status: .working,
            startedAt: Date(),
            lastEventAt: Date()
        )
        session.transcriptPath = p.transcript_path
        store.upsert(session)
    }

    // MARK: - Formatting helpers

    nonisolated static func titleFrom(prompt: String) -> String {
        let line = prompt
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 34 ? String(trimmed.prefix(34)) + "…" : trimmed
    }

    static func activitySummary(toolName: String, input: JSONValue?) -> String {
        func short(_ path: String) -> String {
            URL(fileURLWithPath: path).lastPathComponent
        }
        switch toolName {
        case "Read", "Edit", "Write", "NotebookEdit":
            if let path = input?["file_path"]?.stringValue ?? input?["notebook_path"]?.stringValue {
                return "\(toolName)(\(short(path)))"
            }
        case "Bash":
            if let cmd = input?["command"]?.stringValue {
                let firstLine = cmd.components(separatedBy: .newlines).first ?? cmd
                let clipped = firstLine.count > 40 ? String(firstLine.prefix(40)) + "…" : firstLine
                return "Bash(\(clipped))"
            }
        case "Grep":
            if let pattern = input?["pattern"]?.stringValue {
                return "Grep(\(pattern))"
            }
        case "WebFetch", "WebSearch":
            if let q = input?["url"]?.stringValue ?? input?["query"]?.stringValue {
                return "\(toolName)(\(q))"
            }
        case "Task", "Agent":
            if let d = input?["description"]?.stringValue {
                return "Agent(\(d))"
            }
        default:
            break
        }
        return toolName
    }

    static func resultDetail(toolName: String, response: JSONValue?) -> String? {
        guard let response else { return nil }
        if let s = response.stringValue {
            let bytes = s.utf8.count
            return bytes > 1024
                ? String(format: "%.1f KB", Double(bytes) / 1024.0)
                : "\(bytes) B"
        }
        if case .object(let o) = response {
            if o["success"] != nil || o["structuredPatch"] != nil { return "Updated" }
            if let out = o["stdout"]?.stringValue {
                let lines = out.split(separator: "\n").count
                return lines == 1 ? "1 line" : "\(lines) lines"
            }
        }
        return "OK"
    }

    static func permissionBody(toolName: String, input: JSONValue?) -> String {
        switch toolName {
        case "Bash":
            return input?["command"]?.stringValue ?? ""
        case "Edit":
            let old = input?["old_string"]?.stringValue ?? ""
            let new = input?["new_string"]?.stringValue ?? ""
            let oldLines = old.components(separatedBy: .newlines)
            let newLines = new.components(separatedBy: .newlines)

            // Locate the edit in the file to show real line numbers plus one
            // line of surrounding context, like a proper diff.
            if let path = input?["file_path"]?.stringValue,
               let content = try? String(contentsOfFile: path, encoding: .utf8),
               let range = content.range(of: old), !old.isEmpty {
                let startLine = content[content.startIndex..<range.lowerBound]
                    .components(separatedBy: .newlines).count // 1-based
                let fileLines = content.components(separatedBy: .newlines)
                var out: [String] = []
                if startLine >= 2 {
                    out.append(String(format: "%4d   %@", startLine - 1, fileLines[startLine - 2]))
                }
                for (i, line) in oldLines.enumerated() {
                    out.append(String(format: "%4d - %@", startLine + i, line))
                }
                for (i, line) in newLines.enumerated() {
                    out.append(String(format: "%4d + %@", startLine + i, line))
                }
                let after = startLine + oldLines.count - 1
                if after < fileLines.count {
                    out.append(String(format: "%4d   %@", after + 1, fileLines[after]))
                }
                return out.joined(separator: "\n")
            }
            let removed = oldLines.map { "- " + $0 }
            let added = newLines.map { "+ " + $0 }
            return (removed + added).joined(separator: "\n")
        case "Write":
            let content = input?["content"]?.stringValue ?? ""
            return content.components(separatedBy: .newlines)
                .prefix(40)
                .map { "+ " + $0 }
                .joined(separator: "\n")
        default:
            if let input, case .object = input,
               let data = try? JSONEncoder().encode(input),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return ""
        }
    }

    static func parseQuestion(_ input: JSONValue?) -> (title: String, body: String, options: [String]) {
        // Claude Code AskUserQuestion: {questions: [{question, header, options: [{label, description}]}]}
        guard let q = input?["questions"]?.arrayValue?.first else {
            return ("Question", "", [])
        }
        let title = q["header"]?.stringValue ?? "Question"
        let body = q["question"]?.stringValue ?? ""
        let options = (q["options"]?.arrayValue ?? []).compactMap { opt -> String? in
            opt["label"]?.stringValue ?? opt.stringValue
        }
        return (title, body, options)
    }
}
