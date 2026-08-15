import Foundation

/// Zero-config setup: writes the hook forwarder script and merges Vibe Island
/// hooks into ~/.claude/settings.json (idempotent), with full uninstall.
enum HookInstaller {
    static let supportDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VibeIsland", isDirectory: true)

    /// The hook script must live at a path WITHOUT spaces — Claude Code runs
    /// hook commands through /bin/sh unquoted, so "Application Support" breaks.
    static var hookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibeisland/vibe-hook.sh")
    }

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// Marker used to recognize our entries in settings.json.
    private static var hookCommand: String { hookScriptURL.path }

    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(hookCommand)
    }

    // MARK: - Install

    static func install() throws {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: hookScriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeHookScript()
        try mergeClaudeHooks()
    }

    /// True if this entry is one of ours (current or stale install location).
    private static func isOurs(_ command: String?) -> Bool {
        command?.contains("vibe-hook.sh") == true
    }

    private static func writeHookScript() throws {
        let script = """
        #!/bin/bash
        # Vibe Island hook forwarder — sends Claude Code hook events to the notch
        # app on 127.0.0.1:\(EventServer.port) and relays any interactive response.
        # If the app is not running, exits instantly with no output (no-op).
        PORT=\(EventServer.port)
        INPUT=$(cat)
        [ -z "$INPUT" ] && exit 0

        # Bail fast when the app is down so hooks add no latency.
        if ! nc -z -G 1 127.0.0.1 $PORT >/dev/null 2>&1; then
            exit 0
        fi

        TTYNAME=$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')
        SAFE_TP=$(printf '%s' "${TERM_PROGRAM:-}" | tr -d '"\\\\')
        SAFE_TS=$(printf '%s' "${ITERM_SESSION_ID:-${TERM_SESSION_ID:-}}" | tr -d '"\\\\')
        SAFE_TTY=$(printf '%s' "${TTYNAME:-}" | tr -d '"\\\\')

        # Blank lines are keep-alive heartbeats from the app; the real response
        # is the last non-empty line.
        RESPONSE=$(printf '{"v":1,"source":"claude-code","term_program":"%s","term_session":"%s","tty":"%s","payload":%s}\\n' \\
            "$SAFE_TP" "$SAFE_TS" "$SAFE_TTY" "$INPUT" | nc -w 3600 127.0.0.1 $PORT 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n 1)

        if [ -n "$RESPONSE" ] && [ "$RESPONSE" != "{}" ]; then
            printf '%s' "$RESPONSE"
        fi
        exit 0
        """
        try script.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)
    }

    private static func mergeClaudeHooks() throws {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: claudeSettingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        let events: [(name: String, matcher: String?, timeout: Int)] = [
            ("SessionStart", nil, 5),
            ("UserPromptSubmit", nil, 5),
            ("PreToolUse", "*", 3600),
            ("PostToolUse", "*", 5),
            ("Notification", nil, 5),
            ("Stop", nil, 5),
            ("SubagentStop", nil, 5),
            ("SessionEnd", nil, 5),
        ]

        for event in events {
            var groups = hooks[event.name] as? [[String: Any]] ?? []
            // Drop any of our entries first (including stale ones from an old
            // install path), then add the current one.
            groups = groups.compactMap { group in
                var group = group
                var inner = (group["hooks"] as? [[String: Any]]) ?? []
                inner.removeAll { isOurs($0["command"] as? String) }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            var group: [String: Any] = [
                "hooks": [["type": "command", "command": hookCommand, "timeout": event.timeout]]
            ]
            if let matcher = event.matcher { group["matcher"] = matcher }
            groups.append(group)
            hooks[event.name] = groups
        }

        root["hooks"] = hooks
        try fm.createDirectory(
            at: claudeSettingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Back up settings.json once before our first write.
        let backup = claudeSettingsURL.appendingPathExtension("vibeisland-backup")
        if fm.fileExists(atPath: claudeSettingsURL.path), !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: claudeSettingsURL, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    // MARK: - Uninstall

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = root["hooks"] as? [String: Any]
        else {
            try? FileManager.default.removeItem(at: hookScriptURL)
            return
        }

        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { group in
                var group = group
                var inner = (group["hooks"] as? [[String: Any]]) ?? []
                inner.removeAll { isOurs($0["command"] as? String) }
                if inner.isEmpty { return nil }
                group["hooks"] = inner
                return group
            }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        let out = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try out.write(to: claudeSettingsURL, options: .atomic)
        try? FileManager.default.removeItem(at: hookScriptURL)
    }
}
