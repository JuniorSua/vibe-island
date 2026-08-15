import AppKit

// Headless setup: `VibeIsland --install-hooks` / `--uninstall-hooks` run the
// installer and exit, without starting the UI.
if CommandLine.arguments.contains("--install-hooks") {
    do {
        try HookInstaller.install()
        print("Vibe Island hooks installed into ~/.claude/settings.json")
        exit(0)
    } catch {
        print("Hook install failed: \(error)")
        exit(1)
    }
}
if CommandLine.arguments.contains("--uninstall-hooks") {
    do {
        try HookInstaller.uninstall()
        print("Vibe Island hooks removed from ~/.claude/settings.json")
        exit(0)
    } catch {
        print("Hook uninstall failed: \(error)")
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
