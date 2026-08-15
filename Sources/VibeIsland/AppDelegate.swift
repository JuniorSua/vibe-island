import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController: NotchPanelController!
    private let eventServer = EventServer()
    private var badgeTimer: Timer?
    private var statusHeaderItem: NSMenuItem!

    private static let petIDs = ["codex", "dewey", "fireball", "rocky",
                                "seedy", "stacky", "bsod", "null-signal"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = NotchPanelController()
        eventServer.start()
        setupStatusItem()
        UsageMonitor.shared.start()
        CodexWatcher.shared.start()
        offerHookInstallIfNeeded()

        // ⌥⌘I peeks the panel from anywhere — the island is invisible when
        // idle, so there needs to be a way in without hunting for the notch.
        HotKeyCenter.shared.register { [weak self] in
            Task { @MainActor in
                let store = SessionStore.shared
                store.expanded.toggle()
                if store.expanded { self?.panelController.showForAttention() }
            }
        }
        startBadgeUpdates()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.panelController.layout(animated: false) }
        }

        // Focusing a terminal acknowledges finished agents (clears the green
        // blob) — agent-notch behavior.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier,
                  TerminalJump.isTerminalBundleID(bundleID)
            else { return }
            Task { @MainActor in SessionStore.shared.acknowledgeFinished() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventServer.stop()
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack",
                accessibilityDescription: "Vibe Island"
            )
        }

        let menu = NSMenu()
        menu.delegate = self

        // Live status header — tells you at a glance whether the plumbing is
        // healthy without digging through logs.
        statusHeaderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)
        menu.addItem(.separator())

        let showItem = menu.addItem(withTitle: "Show Panel  ⌥⌘I",
                                    action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(withTitle: "Clear Finished Sessions", action: #selector(clearFinished), keyEquivalent: "").target = self
        menu.addItem(.separator())

        // Codex pet picker (agent-notch's ~/.config/agent-notch/pet file).
        let petItem = NSMenuItem(title: "Codex Pet", action: nil, keyEquivalent: "")
        let petMenu = NSMenu()
        for id in Self.petIDs {
            let item = NSMenuItem(title: id.replacingOccurrences(of: "-", with: " ").capitalized,
                                  action: #selector(choosePet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            petMenu.addItem(item)
        }
        petItem.submenu = petMenu
        menu.addItem(petItem)
        menu.addItem(.separator())

        let soundItem = NSMenuItem(title: "Sound Alerts", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = SoundEngine.shared.enabled ? .on : .off
        menu.addItem(soundItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Install Claude Code Hooks", action: #selector(installHooks), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Uninstall Hooks", action: #selector(uninstallHooks), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Vibe Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // MARK: - Pets

    @objc private func choosePet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agent-notch/pet")
        try? FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? id.write(to: cfg, atomically: true, encoding: .utf8)
    }

    // MARK: - Menu bar badge

    /// The menu bar mirrors the island: a count while agents work, an orange
    /// dot when one needs you — visible even on an external display where the
    /// notch isn't.
    private func startBadgeUpdates() {
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshBadge() }
        }
        t.tolerance = 0.5
        badgeTimer = t
        Task { @MainActor in refreshBadge() }
    }

    @MainActor
    private func refreshBadge() {
        guard let button = statusItem?.button else { return }
        let store = SessionStore.shared
        let waiting = store.attentionCount
        let working = store.activeSessions.filter { $0.status == .working }.count
        let done = store.activeSessions.filter { $0.status == .done && !$0.acknowledged }.count

        if waiting > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(waiting)",
                attributes: [.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold)])
            button.toolTip = "\(waiting) agent\(waiting == 1 ? "" : "s") waiting for you"
        } else if working > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(working)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)])
            button.toolTip = "\(working) agent\(working == 1 ? "" : "s") working"
        } else if done > 0 {
            button.attributedTitle = NSAttributedString(
                string: " ✓",
                attributes: [.foregroundColor: NSColor.systemGreen,
                             .font: NSFont.systemFont(ofSize: 10, weight: .bold)])
            button.toolTip = "\(done) finished — click to review"
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = "Vibe Island — no agents running"
        }
    }

    @objc private func showPanel() {
        Task { @MainActor in
            SessionStore.shared.expanded = true
            panelController.showForAttention()
        }
    }

    @objc private func clearFinished() {
        Task { @MainActor in SessionStore.shared.clearFinished() }
    }

    @objc private func toggleSound(_ sender: NSMenuItem) {
        SoundEngine.shared.enabled.toggle()
        sender.state = SoundEngine.shared.enabled ? .on : .off
    }

    @objc private func installHooks() {
        do {
            try HookInstaller.install()
            notify(title: "Hooks installed",
                   text: "Claude Code sessions will now appear in the notch. Restart running sessions to pick up the hooks.")
        } catch {
            notify(title: "Hook install failed", text: "\(error)")
        }
    }

    @objc private func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            notify(title: "Hooks removed", text: "Vibe Island hooks were removed from ~/.claude/settings.json.")
        } catch {
            notify(title: "Uninstall failed", text: "\(error)")
        }
    }

    // MARK: - First-launch setup

    private func offerHookInstallIfNeeded() {
        guard ProcessInfo.processInfo.environment["VIBE_NO_SETUP"] == nil else { return }
        guard !HookInstaller.isInstalled else { return }
        let alert = NSAlert()
        alert.messageText = "Connect Claude Code to the notch?"
        alert.informativeText = """
        For sessions to show up in the island, Claude Code needs to tell Vibe \
        Island what it's doing. This adds a small notifier to Claude Code's \
        settings (~/.claude/settings.json) — it runs on your Mac only, sends \
        nothing to the internet, and adds no noticeable overhead. A backup of \
        your settings is kept, and "Uninstall Hooks" in the menu bar removes \
        it completely.
        """
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            installHooks()
        }
    }

    private func notify(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

// MARK: - Menu status header

extension AppDelegate: NSMenuDelegate {
    /// Refreshed each time the menu opens: hook health, live counts, and the
    /// selected pet — the answers to "is this thing actually working?".
    func menuWillOpen(_ menu: NSMenu) {
        Task { @MainActor in
            let store = SessionStore.shared
            let working = store.activeSessions.filter { $0.status == .working }.count
            let waiting = store.attentionCount
            let done = store.activeSessions.filter { $0.status == .done }.count

            var lines: [String] = []
            lines.append(HookInstaller.isInstalled
                ? "✓ Claude hooks installed"
                : "⚠︎ Claude hooks not installed")
            lines.append("Listening on 127.0.0.1:\(EventServer.port)")
            if working + waiting + done == 0 {
                lines.append("No agents running")
            } else {
                var parts: [String] = []
                if working > 0 { parts.append("\(working) working") }
                if waiting > 0 { parts.append("\(waiting) waiting") }
                if done > 0 { parts.append("\(done) done") }
                lines.append(parts.joined(separator: " · "))
            }

            let text = lines.joined(separator: "\n")
            self.statusHeaderItem.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor])

            // Tick the active pet in the submenu.
            if let petMenu = menu.items.first(where: { $0.title == "Codex Pet" })?.submenu {
                let current = (try? String(contentsOf: FileManager.default
                    .homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/agent-notch/pet"), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "codex"
                for item in petMenu.items {
                    item.state = (item.representedObject as? String) == current ? .on : .off
                }
            }
        }
    }
}
