import AppKit
import Combine
import SwiftUI

/// Physical notch geometry, published so the SwiftUI pill can size itself to
/// exactly cover the black notch cutout (content goes in the side areas).
@MainActor
final class PanelMetrics: ObservableObject {
    static let shared = PanelMetrics()
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
    /// How far macOS is currently insetting hosted content from the top of the
    /// window. Non-zero means the island would float below the screen edge, so
    /// the root view cancels it with negative padding. Re-measured every
    /// heartbeat because the system re-applies it at unpredictable times
    /// (window re-show, key changes, display/space transitions).
    @Published var contentInsetTop: CGFloat = 0
    /// The island's actual on-screen frame, reported by SwiftUI so the AppKit
    /// top-guard can match it exactly instead of guessing.
    @Published var islandFrame: CGRect = .zero
    var hasNotch: Bool { notchWidth > 0 }

    /// Last good reading per display. `auxiliaryTopLeftArea` / `safeAreaInsets`
    /// are NOT reliable moment to moment — macOS returns nil/zero during
    /// display wake, space switches, fullscreen transitions and early launch.
    /// Treating one of those blips as "this display has no notch" used to move
    /// the whole panel below the menu bar, which is the recurring gap above
    /// the island. Once a display is known to be notched it stays notched.
    private struct NotchInfo { var width: CGFloat; var height: CGFloat }
    private static var known: [CGDirectDisplayID: NotchInfo] = [:]

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? 0
    }

    /// True if this display is known to have a notch, even if it is currently
    /// misreporting.
    static func isNotched(_ screen: NSScreen) -> Bool {
        if screen.safeAreaInsets.top > 0 { return true }
        return known[displayID(of: screen)] != nil
    }

    func update(for screen: NSScreen) {
        let id = Self.displayID(of: screen)
        let inset = screen.safeAreaInsets.top

        // Fresh, trustworthy reading → cache it.
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            if width > 0 {
                Self.known[id] = NotchInfo(width: width, height: inset)
                notchWidth = width
                notchHeight = inset
                return
            }
        }

        // Degraded reading → fall back to what we already know about this
        // display rather than declaring it notchless.
        if let cached = Self.known[id] {
            if notchWidth != cached.width || notchHeight != cached.height {
                NSLog("VibeIsland: screen reported no notch (inset=\(inset), auxAreas=\(screen.auxiliaryTopLeftArea != nil)) — using cached \(cached.width)x\(cached.height)")
            }
            notchWidth = cached.width
            notchHeight = cached.height
            return
        }

        // Genuinely notchless display (or never seen a good reading yet).
        if inset > 0 {
            // Notched but the aux areas are unavailable: keep the height and
            // assume a typical notch width so content still clears the cutout.
            notchWidth = 180
            notchHeight = inset
        } else {
            notchWidth = 0
            notchHeight = 0
        }
    }
}

/// Tiny always-present window covering ONLY the physical notch, so hovering
/// the notch opens the island even when the main panel is hidden (idle). It is
/// deliberately notch-sized: the notch cutout contains no menu-bar items, so
/// this can never swallow a click the user meant for the menu bar.
final class HoverCatcherView: NSView {
    var onEnter: (() -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
}

/// Non-activating, always-on-top panel anchored to the notch (or top-center on
/// non-notch displays). Never steals focus from the user's current app, but can
/// become key so ⌘Y/⌘N/⌘1-4 shortcuts work while an approval is showing.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Allow the panel to sit flush with the top of the screen, overlapping the
    /// menu bar / notch area — AppKit would otherwise push it down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor
final class NotchPanelController {
    static var shared: NotchPanelController?

    let panel: NotchPanel
    private let store = SessionStore.shared
    private let metrics = PanelMetrics.shared
    private var visibilitySub: AnyCancellable?
    private var heartbeat: Timer?
    private var geometrySampler: Timer?
    /// Kept typed so `safeAreaRegions` (an NSHostingView API) stays reachable.
    private var hostingView: NSHostingView<AnyView>?
    /// Plain AppKit black strip pinned to the very top of the window, drawn
    /// over the island's own top edge while the panel is open. SwiftUI layout
    /// near the screen edge has proven unreliable (macOS re-applies a safe-area
    /// inset at unpredictable times); this guarantees the island always meets
    /// the top no matter what SwiftUI does.
    private let topGuard = NSView()
    private let topGuardShape = CAShapeLayer()
    private var hoverCatcher: NSPanel?

    private let expandedSize = CGSize(width: 680, height: 460)

    /// Prefer a display that is known to be notched (cached, so a misreporting
    /// moment can't send the island to another screen), then the built-in,
    /// then main.
    private var targetScreen: NSScreen {
        if let s = NSScreen.screens.first(where: { PanelMetrics.isNotched($0) }) { return s }
        if let builtIn = NSScreen.screens.first(where: {
            CGDisplayIsBuiltin(PanelMetrics.displayID(of: $0)) != 0
        }) { return builtIn }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    init() {
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.becomesKeyOnlyIfNeeded = true

        let root = NotchRootView()
            .environmentObject(store)
            .environmentObject(metrics)
        let hosting = NSHostingView(rootView: AnyView(root))
        hostingView = hosting
        // macOS insets hosted SwiftUI content away from the screen's top edge
        // (safe area) — that leaves a visible sliver of background between the
        // island and the physical top. The island must be flush.
        hosting.safeAreaRegions = []

        let container = NSView(frame: NSRect(origin: .zero, size: expandedSize))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        topGuard.wantsLayer = true
        topGuard.layer?.addSublayer(topGuardShape)
        topGuardShape.fillColor = NSColor.black.cgColor
        topGuard.isHidden = true
        container.addSubview(topGuard)          // sits above the SwiftUI content
        panel.contentView = container

        NotchPanelController.shared = self
        layout(animated: false)

        // When completely idle (no active agents, not opened via the menu),
        // remove the overlay entirely so only Apple's native notch remains.
        // It reappears the moment an agent session becomes active.
        visibilitySub = store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateVisibility()
                    self?.updateTopGuard()
                }
            }
        setupHoverCatcher()
        updateVisibility()
        startVisibilityHeartbeat()
    }

    /// Always-on notch-sized hover target (see HoverCatcherView).
    private func setupHoverCatcher() {
        let catcher = NSPanel(contentRect: .zero,
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        catcher.isOpaque = false
        catcher.backgroundColor = .clear
        catcher.hasShadow = false
        catcher.hidesOnDeactivate = false
        // Just below the island so it never covers the panel itself.
        catcher.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        catcher.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let view = HoverCatcherView()
        view.onEnter = { [weak self] in
            guard let self else { return }
            self.store.expanded = true
            self.updateVisibility()
        }
        catcher.contentView = view
        hoverCatcher = catcher
        layoutHoverCatcher()
        catcher.orderFrontRegardless()
    }

    private func layoutHoverCatcher() {
        guard let catcher = hoverCatcher else { return }
        let screen = targetScreen
        let w = metrics.hasNotch ? metrics.notchWidth : 150
        let h = metrics.hasNotch ? metrics.notchHeight : 24
        let frame = NSRect(x: (screen.frame.midX - w / 2).rounded(),
                           y: screen.frame.maxY - h,
                           width: w, height: h)
        if catcher.frame != frame { catcher.setFrame(frame, display: false) }
    }

    /// Re-asserted on a slow heartbeat as well as on store changes: after days
    /// of sleep/wake and display reconfiguration a status-level window can stop
    /// being composited while AppKit still reports `isVisible == true`, which
    /// used to leave the island permanently invisible.
    func startVisibilityHeartbeat() {
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.updateVisibility()
        }
        t.tolerance = 0.5
        // Run in .common so the check keeps ticking during menu tracking and
        // scrolling, when a default-mode timer would stall.
        RunLoop.main.add(t, forMode: .common)
        heartbeat = t

        // Periodic geometry sample: if the gap ever comes back, the numbers
        // from that moment are already on disk.
        let sampler = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.panel.isVisible else { return }
            self.logGeometry(tag: "sample")
        }
        sampler.tolerance = 10
        RunLoop.main.add(sampler, forMode: .common)
        geometrySampler = sampler
        Diagnostics.log("--- launched, heartbeat started ---")
    }

    func updateVisibility() {
        let shouldShow = !store.activeSessions.isEmpty
            || store.expanded
            || store.toast != nil
            || store.attentionCount > 0
        if shouldShow {
            // Always re-assert frame + ordering (both are cheap and idempotent)
            // rather than trusting `isVisible`.
            layout(animated: false)
            panel.orderFrontRegardless()
        } else if panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// The panel always reserves the expanded size so SwiftUI can animate
    /// pill ↔ card list inside it; content is top-aligned. On notch screens the
    /// panel top is flush with the screen top so the pill merges with the
    /// physical notch; on other screens it sits just below the menu bar.
    func layout(animated: Bool) {
        let screen = targetScreen
        metrics.update(for: screen)
        enforceTopFlush()
        updateTopGuard()
        layoutHoverCatcher()

        let width = max(expandedSize.width, metrics.notchWidth + 200)
        let size = CGSize(width: width, height: expandedSize.height)
        // Anchor on the notch's true center (auxiliary areas can be slightly
        // asymmetric), falling back to the screen midpoint.
        var centerX = screen.frame.midX
        if let left = screen.auxiliaryTopLeftArea, metrics.hasNotch {
            centerX = screen.frame.minX + left.width + metrics.notchWidth / 2
        }
        let x = (centerX - size.width / 2).rounded()
        // ALWAYS flush with the physical top of the display. Deriving this from
        // `hasNotch` (and therefore from APIs that blink out during wake/space
        // changes) is what dropped the panel below the menu bar and produced
        // the recurring gap above the island. The island is a notch overlay —
        // its top edge is the screen's top edge, unconditionally.
        let y = screen.frame.maxY - size.height
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.frame != frame {
            if panel.isVisible, abs(panel.frame.maxY - screen.frame.maxY) > 0.5 {
                Diagnostics.log("correcting drifted panel top: was \(panel.frame.maxY), screen top \(screen.frame.maxY), screen \(screen.localizedName)")
            }
            panel.setFrame(frame, display: true, animate: false)
        }
        _ = animated
    }

    /// Keeps hosted content pinned to the very top of the window. macOS
    /// re-applies a safe-area inset to windows that overlap the menu bar at
    /// unpredictable moments — that inset is the recurring sliver of desktop
    /// above the island. We (a) clear it again and (b) publish whatever
    /// remains so the root view can cancel it with negative padding.
    /// Cover the top edge of the island with a real AppKit view while it is
    /// open. Width matches the island body exactly, and its top edge is the
    /// window's top edge, so it is invisible when everything is behaving and a
    /// silent repair when it isn't.
    private func updateTopGuard() {
        guard let container = panel.contentView else { return }
        let open = store.expanded && store.toast == nil
        topGuard.isHidden = !open
        guard open else { return }
        let bodyWidth = metrics.islandFrame.width > 100
            ? metrics.islandFrame.width
            : max(560, metrics.notchWidth + 340)
        let height: CGFloat = 20
        topGuard.frame = NSRect(x: ((container.bounds.width - bodyWidth) / 2).rounded(),
                                y: container.bounds.height - height,
                                width: bodyWidth, height: height)

        // Trace the island's own outline (full-width top edge, then the
        // concave flare wings) so the guard is invisible rather than squaring
        // off the swoop.
        let tr: CGFloat = 26                      // must match NotchRootView.topRadius
        let b = topGuard.bounds
        let path = CGMutablePath()
        path.move(to: CGPoint(x: b.minX, y: b.maxY))
        path.addLine(to: CGPoint(x: b.maxX, y: b.maxY))
        path.addQuadCurve(to: CGPoint(x: b.maxX - tr, y: b.maxY - tr),
                          control: CGPoint(x: b.maxX - tr, y: b.maxY))
        path.addLine(to: CGPoint(x: b.maxX - tr, y: b.minY))
        path.addLine(to: CGPoint(x: b.minX + tr, y: b.minY))
        path.addLine(to: CGPoint(x: b.minX + tr, y: b.maxY - tr))
        path.addQuadCurve(to: CGPoint(x: b.minX, y: b.maxY),
                          control: CGPoint(x: b.minX + tr, y: b.maxY))
        path.closeSubpath()
        topGuardShape.frame = b
        topGuardShape.path = path
    }

    private func enforceTopFlush() {
        guard let hosting = panel.contentView else { return }
        // `safeAreaRegions` lives on NSHostingView, not NSView — clear it again
        // in case the system re-applied one.
        clearSafeAreaRegions(hosting)
        let inset = hosting.safeAreaInsets.top
        if abs(metrics.contentInsetTop - inset) > 0.1 {
            Diagnostics.log("content inset changed \(metrics.contentInsetTop) → \(inset); compensating")
            metrics.contentInsetTop = inset
        }
    }

    /// The hosting view's generic parameter is opaque here, so reach it
    /// through the stored reference captured at construction.
    private func clearSafeAreaRegions(_ view: NSView) {
        hostingView?.safeAreaRegions = []
        _ = view
    }

    /// Test-only: displace the panel so the heartbeat's correction can be
    /// observed (simulates the drift seen after sleep/display changes).
    func nudgeForTesting(down: CGFloat) {
        var f = panel.frame
        f.origin.y -= down
        panel.setFrame(f, display: true)
        logGeometry(tag: "nudged")
    }

    /// Diagnostics for the "sliver above the island" class of bugs.
    func logGeometry(tag: String) {
        let screen = targetScreen
        let insets = panel.contentView?.safeAreaInsets ?? .init()
        Diagnostics.log("""
        [\(tag)] panel=\(NSStringFromRect(panel.frame)) \
        screen=\(screen.localizedName)\(NSStringFromRect(screen.frame)) \
        gapAboveWindow=\(screen.frame.maxY - panel.frame.maxY) \
        safeAreaTop=\(insets.top) compensating=\(metrics.contentInsetTop) \
        notch=\(metrics.notchWidth)x\(metrics.notchHeight) visible=\(panel.isVisible)
        """)
    }

    func showForAttention() {
        layout(animated: false)
        panel.orderFrontRegardless()
        // Let keyboard shortcuts reach the approval buttons without activating the app.
        panel.makeKey()
    }
}
