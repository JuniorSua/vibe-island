import SwiftUI

/// Interactive takeover for a held hook request: permission approval, multiple
/// choice question, or plan review. Resolving sends the JSON hook response
/// back over the held connection and flashes a confirmation toast.
struct RequestView: View {
    @EnvironmentObject var store: SessionStore
    let session: Session
    let request: PendingRequest
    /// Other agents waiting behind this one.
    var queuedBehind: Int = 0
    @State private var feedback: String = ""

    static let teal = Color(red: 0.28, green: 0.87, blue: 0.74)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            contextLine
            switch request.kind {
            case .permission: permissionBody
            case .question: questionBody
            case .plan: planBody
            }
        }
    }

    /// Which agent, in which project, waiting how long — essential when
    /// several agents are running and one of them interrupts you.
    private var contextLine: some View {
        HStack(spacing: 6) {
            Text(session.projectName ?? session.agent.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            if let terminal = TerminalJump.displayName(for: session.termProgram) {
                Text("· \(terminal)")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.3))
            }
            Text("· waiting \(waitLabel)")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            if queuedBehind > 0 {
                Text("+\(queuedBehind) more")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(SessionStatus.waiting.color))
                    .help("\(queuedBehind) other agent\(queuedBehind == 1 ? "" : "s") waiting — answer this one and the next appears")
            }
        }
    }

    private var waitLabel: String {
        _ = store.tick   // re-evaluate on the store's 30s tick
        let secs = Int(Date().timeIntervalSince(request.createdAt))
        if secs < 60 { return "\(max(secs, 1))s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    // MARK: - Permission (diff + Deny / Allow)

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(SessionStatus.waiting.color)
                    .frame(width: 5, height: 5)
                Text("Permission Request")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(session.agent.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }

            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(SessionStatus.waiting.color)
                Text(toolLabel)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SessionStatus.waiting.color)
                Text(targetLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if !request.body.isEmpty {
                DiffPreview(text: request.body)
                if let stats = diffStats {
                    Text(stats)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }

            actionButtons(denyTitle: "Deny", allowTitle: "Allow")
        }
    }

    private var toolLabel: String {
        request.title.components(separatedBy: "(").first ?? request.toolName
    }

    private var targetLabel: String {
        guard let open = request.title.firstIndex(of: "("),
              request.title.hasSuffix(")") else { return "" }
        return String(request.title[request.title.index(after: open)..<request.title.index(before: request.title.endIndex)])
    }

    private var diffStats: String? {
        let lines = request.body.components(separatedBy: .newlines)
        let added = lines.filter { DiffPreview.kind(of: $0) == .added }.count
        let removed = lines.filter { DiffPreview.kind(of: $0) == .removed }.count
        guard added + removed > 0 else { return nil }
        return "+\(added) -\(removed)"
    }

    // MARK: - Question ("Claude asks" + ⌘1..⌘9 choices)

    private var questionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 10))
                Text("\(session.agent.displayName) asks")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Self.teal)

            Text(request.body.isEmpty ? request.title : request.body)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(Array(request.options.prefix(9).enumerated()), id: \.offset) { i, option in
                    QuestionOptionRow(index: i, label: option) { answer(option) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                }
            }
        }
    }

    // MARK: - Plan review

    private var planBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 10))
                Text("\(session.agent.displayName) has a plan")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Self.teal)

            ScrollView {
                Text(planAttributed)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 190)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))

            TextField("Feedback (sent with Revise)", text: $feedback)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))

            actionButtons(denyTitle: "Revise", allowTitle: "Approve plan")
        }
    }

    private var planAttributed: AttributedString {
        (try? AttributedString(
            markdown: request.body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(request.body)
    }

    // MARK: - Buttons (Deny dark / Allow white, real-app style)

    private func actionButtons(denyTitle: String, allowTitle: String) -> some View {
        HStack(spacing: 8) {
            Button {
                if request.kind == .plan {
                    let msg = feedback.isEmpty
                        ? "User asked for plan revisions from Vibe Island."
                        : "User feedback on the plan: \(feedback)"
                    resolveDeny(reason: msg, toastText: "Sent back for revision", color: .orange)
                } else {
                    resolveDeny(reason: "User denied this action from Vibe Island.",
                                toastText: "Denied", color: .red)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(denyTitle).font(.system(size: 11.5, weight: .semibold))
                    Text("⌘N").font(.system(size: 9, design: .monospaced)).opacity(0.5)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .keyboardShortcut("n", modifiers: .command)
            .buttonStyle(DarkButtonStyle())

            Button {
                resolveAllow(toastText: request.kind == .plan ? "Plan approved" : "Allowed")
            } label: {
                HStack(spacing: 5) {
                    Text(allowTitle).font(.system(size: 11.5, weight: .semibold))
                    Text("⌘Y").font(.system(size: 9, design: .monospaced)).opacity(0.45)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .keyboardShortcut("y", modifiers: .command)
            .buttonStyle(LightButtonStyle())
        }
    }

    // MARK: - Responses

    private func resolveAllow(toastText: String) {
        send(json: """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved from Vibe Island"}}
        """, toast: .init(symbol: "checkmark", text: toastText, color: .green))
    }

    private func resolveDeny(reason: String, toastText: String,
                             color: SessionStore.Toast.ToastColor) {
        send(json: """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":\(Self.jsonString(reason))}}
        """, toast: .init(symbol: color == .red ? "xmark" : "arrow.uturn.backward",
                          text: toastText, color: color))
    }

    private func answer(_ option: String) {
        // AskUserQuestion is answered by denying the tool call with the chosen
        // option as the reason — the agent reads it as the user's answer.
        let reason = "User answered via Vibe Island: \"\(option)\". Proceed with this choice; do not re-ask."
        send(json: """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":\(Self.jsonString(reason))}}
        """, toast: .init(symbol: "checkmark", text: option, color: .green))
    }

    private func send(json: String, toast: SessionStore.Toast) {
        SoundEngine.shared.play(.resolved)
        store.resolve(sessionID: session.id, response: json)
        store.expanded = false
        store.showToast(toast)
    }

    static func jsonString(_ s: String) -> String {
        let data = (try? JSONEncoder().encode([s])) ?? Data("[\"\"]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }
}

// MARK: - Question option row

struct QuestionOptionRow: View {
    let index: Int
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("⌘\(index + 1)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(RequestView.teal)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(RequestView.teal.opacity(0.15)))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(RequestView.teal.opacity(hovering ? 0.14 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(RequestView.teal.opacity(hovering ? 0.5 : 0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Diff preview with line-number gutter

struct DiffPreview: View {
    let text: String

    enum LineKind { case added, removed, context }

    /// Lines are pre-formatted by EventHandler as "  12 - old" / "  13 + new"
    /// (number gutter when known) or bare "+ new" / "- old".
    static func kind(of line: String) -> LineKind {
        let trimmed = line.drop { $0 == " " || $0.isNumber }
        if trimmed.hasPrefix("+") { return .added }
        if trimmed.hasPrefix("-") { return .removed }
        return .context
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(text.components(separatedBy: .newlines).prefix(80).enumerated()),
                        id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 0.5)
                        .background(background(for: line))
                }
            }
        }
        .frame(maxHeight: 150)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private func color(for line: String) -> Color {
        switch Self.kind(of: line) {
        case .added: return Color(red: 0.55, green: 0.9, blue: 0.6)
        case .removed: return Color(red: 0.95, green: 0.55, blue: 0.55)
        case .context: return .white.opacity(0.55)
        }
    }

    private func background(for line: String) -> Color {
        switch Self.kind(of: line) {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}

// MARK: - Buttons

struct DarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(0.9))
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

struct LightButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.75 : 0.94))
            )
    }
}
