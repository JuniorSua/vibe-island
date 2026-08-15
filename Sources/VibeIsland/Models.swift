import Foundation
import SwiftUI

// MARK: - Agent brands

enum AgentKind: String, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case gemini = "gemini"
    case cursor = "cursor"
    case opencode = "opencode"
    case copilot = "copilot"
    case droid = "droid"
    case amp = "amp"
    case unknown = "unknown"

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .copilot: return "Copilot"
        case .droid: return "Droid"
        case .amp: return "Amp"
        case .unknown: return "Agent"
        }
    }

    var brandColor: Color {
        switch self {
        case .claudeCode: return Color(red: 0.85, green: 0.47, blue: 0.25)   // Anthropic clay
        case .codex: return Color(red: 0.10, green: 0.65, blue: 0.55)
        case .gemini: return Color(red: 0.30, green: 0.52, blue: 0.96)
        case .cursor: return Color(red: 0.60, green: 0.60, blue: 0.95)
        case .opencode: return Color(red: 0.9, green: 0.75, blue: 0.2)
        case .copilot: return Color(red: 0.45, green: 0.45, blue: 0.5)
        case .droid: return Color(red: 0.75, green: 0.3, blue: 0.75)
        case .amp: return Color(red: 0.85, green: 0.2, blue: 0.35)
        case .unknown: return Color.gray
        }
    }

    static func from(source: String) -> AgentKind {
        AgentKind(rawValue: source.lowercased()) ?? .unknown
    }
}

// MARK: - Session status

enum SessionStatus: String, Codable {
    case working
    case waiting     // needs the user (permission, question, plan)
    case done        // agent finished its turn, idle
    case ended       // process exited

    var color: Color {
        switch self {
        case .working: return Color(red: 0.35, green: 0.78, blue: 0.98)
        case .waiting: return Color(red: 1.0, green: 0.62, blue: 0.15)
        case .done: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .ended: return Color.gray
        }
    }

    var label: String {
        switch self {
        case .working: return "working"
        case .waiting: return "waiting for you"
        case .done: return "done"
        case .ended: return "ended"
        }
    }
}

// MARK: - Activity feed

struct ActivityEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var timestamp: Date
    var toolName: String
    var summary: String        // e.g. "Read(schema.prisma)"
    var detail: String?        // e.g. "1.2 KB" / "Updated (+8 -23)"
}

// MARK: - Pending interactive request

enum PendingRequestKind: String, Codable {
    case permission   // tool approval (Allow / Deny)
    case question     // AskUserQuestion (multiple choice)
    case plan         // ExitPlanMode (plan review)
}

struct PendingRequest: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var kind: PendingRequestKind
    var toolName: String
    var title: String              // e.g. "Edit src/auth/middleware.ts"
    var body: String               // diff / question text / plan markdown
    var options: [String] = []     // for questions
    var createdAt: Date = Date()
}

// MARK: - Session

struct Session: Codable, Identifiable, Equatable {
    var id: String                 // agent session id
    var agent: AgentKind
    var title: String
    var prompt: String?            // the user's full prompt (title is a short form)
    var cwd: String?
    var termProgram: String?
    var termSession: String?
    var tty: String?
    var status: SessionStatus
    var startedAt: Date
    var lastEventAt: Date
    var activity: [ActivityEntry] = []
    var pendingRequest: PendingRequest?
    var recap: String?             // away summary shown on idle cards
    var approveFromNotch: Bool = false  // hold risky tools for GUI approval
    var model: String? = nil            // e.g. "fable-5", "gpt-5.3-codex"
    var transcriptPath: String? = nil   // agent transcript (for model lookup)
    var acknowledged: Bool = false      // done + seen (green blob cleared)

    var projectName: String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var elapsedLabel: String {
        let secs = Int(Date().timeIntervalSince(startedAt))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Wire protocol (what the hook script sends)

struct WireEvent: Codable {
    var v: Int?
    var source: String?
    var term_program: String?
    var term_session: String?
    var tty: String?
    var payload: HookPayload
}

/// Loosely-typed Claude Code hook payload; other agents map onto the same shape.
struct HookPayload: Codable {
    var session_id: String?
    var transcript_path: String?
    var cwd: String?
    var hook_event_name: String?
    var tool_name: String?
    var tool_input: JSONValue?
    var tool_response: JSONValue?
    var message: String?
    var prompt: String?
    var source: String?
    var reason: String?
}

// MARK: - Free-form JSON

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
}
