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
