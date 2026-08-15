import SwiftUI
import AppKit

/// Right-click menu attached to the island itself. Crowded menu bars push the
/// status item off screen on notched Macs, so the island has to be able to
/// reach these actions on its own.
struct IslandContextMenu: View {
    @EnvironmentObject var store: SessionStore

    private static let petIDs = ["codex", "dewey", "fireball", "rocky",
                                "seedy", "stacky", "bsod", "null-signal"]

    private var petConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-notch/pet")
    }

    private var currentPet: String {
        (try? String(contentsOf: petConfigURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codex"
    }

    var body: some View {
        Section(statusSummary) {
            Button("Clear Finished Sessions") { store.clearFinished() }
        }

        Menu("Codex Pet") {
            ForEach(Self.petIDs, id: \.self) { id in
                Button {
                    try? FileManager.default.createDirectory(
                        at: petConfigURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? id.write(to: petConfigURL, atomically: true, encoding: .utf8)
                } label: {
                    Text(id == currentPet
                         ? "✓ \(id.replacingOccurrences(of: "-", with: " ").capitalized)"
                         : id.replacingOccurrences(of: "-", with: " ").capitalized)
                }
            }
        }

        Divider()

        if HookInstaller.isInstalled {
            Button("Reinstall Claude Hooks") { try? HookInstaller.install() }
            Button("Uninstall Hooks") { try? HookInstaller.uninstall() }
        } else {
            Button("Install Claude Hooks") { try? HookInstaller.install() }
        }

        Divider()
        Button("Quit Vibe Island") { NSApp.terminate(nil) }
    }

    private var statusSummary: String {
        let working = store.activeSessions.filter { $0.status == .working }.count
        let waiting = store.attentionCount
        let hooks = HookInstaller.isInstalled ? "hooks on" : "hooks OFF"
        if working + waiting == 0 { return "Idle · \(hooks)" }
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        return parts.joined(separator: " · ") + " · \(hooks)"
    }
}
