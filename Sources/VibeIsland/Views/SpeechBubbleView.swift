import SwiftUI

/// The "AI is chatting with you" popup. Appears under the walking mascot when
/// you hover it — a small dark speech bubble with a tail pointing up at the
/// logo, the agent's own avatar, the task, and what it's doing right now.
///
/// Purely informational (no buttons): the user asked for a glanceable status,
/// and the full panel — needed for approvals/questions — is a separate click /
/// ⌥⌘I away.
struct SpeechBubbleView: View {
    let session: Session
    /// Answer callback: (hook JSON response, toast to flash). Present only when
    /// the agent is asking something, which is also when the popup accepts
    /// clicks — otherwise it is pure information and click-through.
    var onAnswer: ((String, SessionStore.Toast) -> Void)? = nil

    static let teal = Color(red: 0.28, green: 0.87, blue: 0.74)

    private var accent: Color {
        switch session.status {
        case .waiting: return SessionStatus.waiting.color
        case .done:    return SessionStatus.done.color
        default:       return session.agent.brandColor
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tail pointing up toward the mascot.
            BubbleTail()
                .fill(Color(white: 0.11))
                .frame(width: 16, height: 7)
                .overlay(
                    BubbleTail().stroke(Color.white.opacity(0.10), lineWidth: 1)
                        .mask(Rectangle().padding(.bottom, 1))   // hide the seam where it meets the body
                )

            HStack(alignment: .top, spacing: 9) {
                avatar
                    .frame(width: 26, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(session.agent.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent)
                        if let model = session.model {
                            Text(model)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer(minLength: 0)
                        Text(session.elapsedLabel)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                    }

                    Text(session.prompt ?? session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(statusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(accent.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let req = session.pendingRequest, onAnswer != nil {
                        answerControls(req)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: 264, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.11))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        switch session.status {
        case .done:
            PixelCheckView()
        default:
            if session.agent == .codex {
                PetSpriteView(animating: session.status == .working, height: 22)
            } else {
                CrabView(animating: session.status == .working,
                         tint: session.status == .waiting ? SessionStatus.waiting.color
                                                          : MascotKit.claudeOrange)
            }
        }
    }

    private var statusText: String {
        switch session.status {
        case .working:
            if let last = session.activity.last { return "· \(verb(last))" }
            if let recap = session.recap, !recap.isEmpty { return "· \(recap)" }
            return "· Working…"
        case .waiting:
            return "◆ Needs you — ⌥⌘I to answer"
        case .done:
            return "✓ Done — ⌥⌘I to review or jump"
        case .ended:
            return "Ended"
        }
    }

    /// One-click answers, right in the popup.
    @ViewBuilder
    private func answerControls(_ req: PendingRequest) -> some View {
        switch req.kind {
        case .question:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(req.options.prefix(4).enumerated()), id: \.offset) { i, option in
                    Button {
                        answer(option)
                    } label: {
                        HStack(spacing: 6) {
                            Text("⌘\(i + 1)")
                                .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Self.teal)
                            Text(option)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.95))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Self.teal.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .stroke(Self.teal.opacity(0.35), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case .permission:
            HStack(spacing: 6) {
                Button { deny() } label: {
                    Text("Deny").font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(DarkButtonStyle())
                Button { allow() } label: {
                    Text("Allow").font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(LightButtonStyle())
            }
        case .plan:
            Text("Press ⌥⌘I to review the plan")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func answer(_ option: String) {
        let reason = "User answered via Vibe Island: \"\(option)\". Proceed with this choice; do not re-ask."
        onAnswer?(denyJSON(reason),
                  .init(symbol: "checkmark", text: option, color: .green))
    }

    private func allow() {
        onAnswer?("""
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"Approved from Vibe Island"}}
        """, .init(symbol: "checkmark", text: "Allowed", color: .green))
    }

    private func deny() {
        onAnswer?(denyJSON("User denied this action from Vibe Island."),
                  .init(symbol: "xmark", text: "Denied", color: .red))
    }

    private func denyJSON(_ reason: String) -> String {
        """
        {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":\(RequestView.jsonString(reason))}}
        """
    }

    private func verb(_ e: ActivityEntry) -> String {
        let inner: String = {
            guard let open = e.summary.firstIndex(of: "("), e.summary.hasSuffix(")") else { return e.summary }
            return String(e.summary[e.summary.index(after: open)..<e.summary.index(before: e.summary.endIndex)])
        }()
        switch e.toolName {
        case "Edit", "Write", "NotebookEdit": return "Writing \(inner)"
        case "Read":  return "Reading \(inner)"
        case "Bash":  return "Running \(inner)"
        case "Grep":  return "Searching \(inner)"
        default:      return e.summary
        }
    }
}

/// Upward-pointing triangle for the bubble tail.
private struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
