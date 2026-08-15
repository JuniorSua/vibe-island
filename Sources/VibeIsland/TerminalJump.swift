import AppKit
import Foundation

/// Jumps to the terminal tab/pane hosting a session. Precise jump (tab + pane
/// selection by tty) for iTerm2 and Terminal.app via AppleScript; best-effort
/// app activation for everything else.
enum TerminalJump {
    private static let bundleIDs: [String: String] = [
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
        "Alacritty": "org.alacritty",
        "Hyper": "co.zeit.hyper",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "zed": "dev.zed.Zed",
        "Tabby": "org.tabby",
    ]

    private static let displayNames: [String: String] = [
        "iTerm.app": "iTerm2",
        "Apple_Terminal": "Terminal",
        "ghostty": "Ghostty",
        "WarpTerminal": "Warp",
        "WezTerm": "WezTerm",
        "kitty": "kitty",
        "Alacritty": "Alacritty",
        "Hyper": "Hyper",
        "vscode": "VS Code",
        "cursor": "Cursor",
        "zed": "Zed",
        "Tabby": "Tabby",
    ]

    static func isTerminalBundleID(_ bundleID: String) -> Bool {
        bundleIDs.values.contains(bundleID)
    }

    static func displayName(for termProgram: String?) -> String? {
        guard let termProgram, !termProgram.isEmpty else { return nil }
        return displayNames[termProgram] ?? termProgram
    }

    static func jump(to session: Session) {
        let tty = session.tty.flatMap { raw -> String? in
            guard !raw.isEmpty, raw != "??" else { return nil }
            return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
        }

        switch session.termProgram {
        case "iTerm.app":
            if let tty, jumpITerm(tty: tty) { return }
        case "Apple_Terminal":
            if let tty, jumpAppleTerminal(tty: tty) { return }
        case "WezTerm":
            if let tty, jumpWezTerm(tty: tty) { return }
        default:
            break
        }
        activateApp(for: session)
    }

    /// Preferred activation order for the no-termProgram fallback.
    private static let fallbackOrder = ["iTerm.app", "Apple_Terminal", "ghostty",
                                       "WarpTerminal", "WezTerm", "kitty",
                                       "Alacritty", "vscode", "cursor", "zed"]

    private static func activateApp(for session: Session) {
        if let termProgram = session.termProgram,
           let bundleID = bundleIDs[termProgram] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        // No (or unknown) terminal recorded: activate the first running known
        // terminal, in a sensible order.
        for termProgram in fallbackOrder {
            guard let bundleID = bundleIDs[termProgram],
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
            else { continue }
            app.activate()
            return
        }
    }

    // MARK: - Precise adapters

    /// Runs a jump script and returns true ONLY if it actually found and
    /// selected the target (script must `return "found"`). A script that runs
    /// fine but matches nothing must NOT count as success, or the caller would
    /// skip the activation fallback and the click would do nothing.
    private static func runJumpScript(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("VibeIsland: AppleScript error: \(error)")
            return false
        }
        return result.stringValue == "found"
    }

    private static func jumpITerm(tty: String) -> Bool {
        runJumpScript("""
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return "found"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "no"
        """)
    }

    private static func jumpAppleTerminal(tty: String) -> Bool {
        runJumpScript("""
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "found"
                    end if
                end repeat
            end repeat
        end tell
        return "no"
        """)
    }

    private static func jumpWezTerm(tty: String) -> Bool {
        // wezterm cli list --format json → find pane by tty, then activate it.
        guard let wezterm = ["/opt/homebrew/bin/wezterm", "/usr/local/bin/wezterm",
                             "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return false }

        func run(_ args: [String]) -> String? {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: wezterm)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            do { try proc.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }

        guard let json = run(["cli", "list", "--format", "json"]),
              let data = json.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        let ttyName = tty
        guard let pane = panes.first(where: { ($0["tty_name"] as? String) == ttyName }),
              let paneID = pane["pane_id"] as? Int
        else { return false }

        _ = run(["cli", "activate-pane", "--pane-id", String(paneID)])
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.github.wez.wezterm").first {
            app.activate()
        }
        return true
    }
}
