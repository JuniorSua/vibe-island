import AppKit
import Carbon.HIToolbox

/// A single system-wide hotkey (⌥⌘I by default) that peeks the panel from any
/// app. Uses Carbon's RegisterEventHotKey, which — unlike a global NSEvent
/// monitor — needs no Accessibility permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var action: (() -> Void)?

    /// Default: ⌥⌘I ("island").
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_I),
                  modifiers: UInt32 = UInt32(cmdKey | optionKey),
                  action: @escaping () -> Void) {
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // The C callback can't capture context; it routes through the shared
        // instance instead.
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            HotKeyCenter.shared.fire()
            return noErr
        }, 1, &spec, nil, &eventHandler)
        guard status == noErr else {
            NSLog("VibeIsland: hotkey handler install failed (\(status))")
            return
        }

        let id = EventHotKeyID(signature: OSType(0x56494245), id: 1)  // 'VIBE'
        let regStatus = RegisterEventHotKey(keyCode, modifiers, id,
                                           GetApplicationEventTarget(), 0, &hotKeyRef)
        if regStatus != noErr {
            NSLog("VibeIsland: hotkey registration failed (\(regStatus)) — likely taken by another app")
        }
    }

    fileprivate func fire() {
        action?()
    }
}
