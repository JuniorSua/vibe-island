import AppKit
import SwiftUI

/// The hover popup, as its OWN small window.
///
/// It used to be a SwiftUI overlay inside the big island window, which caused
/// three bugs at once: it inherited the window's 60pt top overhang (so it drew
/// too low), the island window turns click-through when the pointer isn't over
/// the island (so the popup never saw the pointer leave, and swallowed nothing
/// — clicks fell through it), and hover state lived in SwiftUI where those two
/// interacted badly.
///
/// Here it is simple and self-contained:
///   • position is computed in real screen coordinates from the mascot's rect
///   • visibility is driven by polling the pointer, not by SwiftUI hover events
///   • it is click-through UNLESS the agent is asking something, in which case
///     it accepts clicks so the answer buttons work
@MainActor
final class BubbleController {
    static var shared: BubbleController?

    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let store = SessionStore.shared

    private var poll: Timer?
    private var clickMonitor: Any?
    private var enteredAt: Date?
    private var leftAt: Date?
    private var shown = false
    /// While set, pointer-based hiding is suspended (debug screenshots only).
    private var debugUntil: Date?

    /// Pointer must rest on the mascot this long before the popup appears.
    private let dwell: TimeInterval = 0.18
    /// Grace after leaving, so you can move from the mascot onto the popup.
    private let leaveGrace: TimeInterval = 0.35

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 90),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true          // info-only by default

        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.safeAreaRegions = []
        panel.contentView = hosting

        BubbleController.shared = self
        start()
    }

    private func start() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t

        // Any click outside the popup dismisses it immediately.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    // MARK: - Per-tick decision

    private func tick() {
        if let until = debugUntil {
            if Date() < until { return }        // leave the debug flash alone
            debugUntil = nil
            hide()
            return
        }
        guard let mascot = NotchPanelController.shared?.mascotScreenRect(),
              let session = bubbleSession,
              !store.expanded, store.toast == nil else {
            hide()
            return
        }

        let mouse = NSEvent.mouseLocation
        let hotZone = mascot.insetBy(dx: -6, dy: -6)
        let overMascot = hotZone.contains(mouse)
        let overBubble = shown && panel.frame.insetBy(dx: -4, dy: -4).contains(mouse)

        if overMascot || overBubble {
            leftAt = nil
            if enteredAt == nil { enteredAt = Date() }
            if !shown, Date().timeIntervalSince(enteredAt!) >= dwell {
                show(session: session, under: mascot)
            } else if shown {
                refresh(session: session, under: mascot)
            }
        } else {
            enteredAt = nil
            if shown {
                if leftAt == nil { leftAt = Date() }
                if Date().timeIntervalSince(leftAt!) >= leaveGrace { hide() }
            }
        }
    }

    private var bubbleSession: Session? {
        let live = store.activeSessions
        return live.first { $0.status == .waiting }
            ?? live.first { $0.status == .working }
            ?? live.first { $0.status == .done && !$0.acknowledged }
            ?? live.first
    }

    // MARK: - Show / refresh / hide

    private func show(session: Session, under mascot: CGRect) {
        shown = true
        refresh(session: session, under: mascot)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func refresh(session: Session, under mascot: CGRect) {
        // Interactive only when the agent is actually asking something.
        let interactive = session.pendingRequest != nil
        panel.ignoresMouseEvents = !interactive

        hosting.rootView = AnyView(
            SpeechBubbleView(session: session) { [weak self] json, toast in
                guard let self else { return }
                self.store.resolve(sessionID: session.id, response: json)
                self.store.showToast(toast)
                self.hide()
            }
            .environmentObject(store)
        )

        let size = hosting.fittingSize
        let w = max(size.width, 240), h = size.height
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mascot.origin) })
                ?? NSScreen.main else { return }
        // Directly beneath the mascot, nudged inside the screen edges.
        var x = mascot.midX - w / 2
        x = min(max(x, screen.frame.minX + 8), screen.frame.maxX - w - 8)
        let y = mascot.minY - h - 2
        let f = NSRect(x: x.rounded(), y: y.rounded(), width: w, height: h)
        panel.setFrame(f, display: true)
        Diagnostics.log("[bubble] placed at \(NSStringFromRect(f)) under mascot \(NSStringFromRect(mascot)) gap=\(mascot.minY - f.maxY)")
    }

    private func hide() {
        guard shown else { return }
        shown = false
        enteredAt = nil
        leftAt = nil
        panel.ignoresMouseEvents = true
        panel.orderOut(nil)
    }

    /// Debug/testing: show it without a pointer, self-expiring.
    func debugFlash(seconds: TimeInterval = 4) {
        let mr = NotchPanelController.shared?.mascotScreenRect()
        Diagnostics.log("[bubble] mascotScreenRect=\(mr.map { NSStringFromRect($0) } ?? "nil") session=\(bubbleSession?.id ?? "nil") expanded=\(store.expanded)")
        guard let mascot = mr, let session = bubbleSession else { return }
        debugUntil = Date().addingTimeInterval(seconds)
        show(session: session, under: mascot)
    }
}
