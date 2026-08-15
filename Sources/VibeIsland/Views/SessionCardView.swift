import SwiftUI

/// Compact session row. The prominent (top) row shows the animated pixel bot,
/// the user's prompt, and the live activity line; other rows collapse to a
/// status dot + title + chips.
struct SessionRowView: View {
    @EnvironmentObject var store: SessionStore
    let session: Session
    let prominent: Bool
    @State private var hovering = false
    @State private var showHistory = false

    private var hasHistory: Bool { session.activity.count > 1 }

    /// Recent tool calls, newest last — answers "what has it been doing?".
    private var historyFeed: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(session.activity.suffix(6).reversed()) { entry in
                HStack(spacing: 4) {
                    Text(entry.summary)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                    if let detail = entry.detail {
                        Text("└ \(detail)")
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5, design: .monospaced))
            }
        }
        .padding(.top, 3)
        .padding(.leading, 1)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leadingIcon
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // agent-notch rows lead with YOUR prompt, not agent chatter.
                    Text(session.prompt ?? session.title)
                        .font(.system(size: 12.5, weight: prominent ? .bold : .semibold))
                        .foregroundStyle(.white.opacity(dimmed ? 0.55 : (prominent ? 0.95 : 0.85)))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Which repo this agent is in — the fastest way to tell
                    // several concurrent sessions apart.
                    if let project = session.projectName, project != session.title {
                        Text(project)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.32))
                            .lineLimit(1)
                    }
                    if let model = session.model {
                        Text(model)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    }
                    Text(session.elapsedLabel)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }

                if prominent || session.status == .waiting {
                    HStack(spacing: 6) {
                        statusLine
                        if hasHistory {
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    showHistory.toggle()
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: showHistory ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 7, weight: .bold))
                                    Text("\(session.activity.count) steps")
                                        .font(.system(size: 9))
                                }
                                .foregroundStyle(.white.opacity(0.4))
                            }
                            .buttonStyle(.plain)
                            .help("Show the recent tool calls for this session")
                        }
                    }
                } else if let snippet = session.recap, !snippet.isEmpty {
                    Text(snippet)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }

                if showHistory {
                    historyFeed
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, prominent ? 10 : 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(hovering ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .help(jumpHint)
        .onHover { hovering = $0 }
        .onTapGesture {
            TerminalJump.jump(to: session)
            store.expanded = false
            // Clicking a finished session acknowledges it — clear the card.
            if session.status == .done {
                store.remove(id: session.id)
            }
        }
        .contextMenu {
            Toggle("Approve from notch", isOn: Binding(
                get: { session.approveFromNotch },
                set: { on in store.update(id: session.id) { $0.approveFromNotch = on } }
            ))
            Button("Remove") { store.remove(id: session.id) }
        }
    }

    // MARK: - Pieces

    /// agent-notch row icon: mascot walking in place while running, green
    /// pixel checkmark when finished.
    @ViewBuilder
    private var leadingIcon: some View {
        switch session.status {
        case .done:
            PixelCheckView()
        case .waiting:
            if session.agent == .codex {
                PetSpriteView(animating: false, height: 20)
            } else {
                CrabView(animating: true, scale: 0.85, tint: SessionStatus.waiting.color)
            }
        default:
            if session.agent == .codex {
                PetSpriteView(animating: session.status == .working, height: 20)
            } else {
                CrabView(animating: session.status == .working, scale: 0.85)
            }
        }
    }

    private var dimmed: Bool {
        session.status == .done && session.acknowledged
    }

    /// Tooltip carries the FULL prompt (row titles are truncated) plus where a
    /// click will take you.
    private var jumpHint: String {
        let where_ = TerminalJump.displayName(for: session.termProgram) ?? "its terminal"
        let project = session.projectName.map { " · \($0)" } ?? ""
        var lines: [String] = []
        if let prompt = session.prompt, prompt.count > 40 { lines.append(prompt) }
        lines.append("Click to jump to \(where_)\(project)")
        return lines.joined(separator: "\n\n")
    }

    @ViewBuilder
    private var statusLine: some View {
        switch session.status {
        case .working:
            Text(activityText)
                .font(.system(size: 10.5))
                .foregroundStyle(SessionStatus.working.color)
                .lineLimit(1)
        case .done:
            Text("Done — click to jump")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SessionStatus.done.color)
        case .waiting:
            Text(session.recap?.isEmpty == false ? session.recap! : "Needs your input")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(SessionStatus.waiting.color)
                .lineLimit(1)
        case .ended:
            Text("Ended")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var activityText: String {
        guard let last = session.activity.last else {
            // Hook-less sessions (Codex) have no tool feed — show the latest
            // transcript snippet instead.
            if let recap = session.recap, !recap.isEmpty { return recap }
            return "Working…"
        }
        switch last.toolName {
        case "Edit", "Write", "NotebookEdit":
            return "Writing \(stripTool(last.summary))"
        case "Read":
            return "Reading \(stripTool(last.summary))"
        case "Bash":
            return "Running \(stripTool(last.summary))"
        case "Grep":
            return "Searching \(stripTool(last.summary))"
        default:
            return last.summary
        }
    }

    private func stripTool(_ summary: String) -> String {
        guard let open = summary.firstIndex(of: "("), summary.hasSuffix(")") else { return summary }
        return String(summary[summary.index(after: open)..<summary.index(before: summary.endIndex)])
    }

}
