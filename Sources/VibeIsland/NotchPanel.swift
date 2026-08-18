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
    /// Global frame of the walking-mascot cluster, so the chat bubble can point
    /// its tail up at the exact logo the user is hovering.
    @Published var mascotFrame: CGRect = .zero
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

    private var armed = false

    /// Same dwell rule as the SwiftUI side: the pointer must still be inside
    /// after the delay, so passing through never opens the panel.
    override func mouseEntered(with event: NSEvent) {
        armed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + HoverTuning.openDelay) { [weak self] in
            guard let self, self.armed else { return }
            self.onEnter?()
        }
    }

    override func mouseExited(with event: NSEvent) { armed = false }
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
    private var hoverCatcher: NSPanel?

    private let expandedSize = CGSize(width: 680, height: 460)

    /// The window is deliberately taller than it needs to be and positioned so
    /// this many points hang ABOVE the physical top of the display. macOS clips
    /// the overhang. The black backdrop fills the whole window, so however the
    /// content inside gets inset, shifted or animated, there is always opaque
    /// black from above the screen edge downward — a top gap is impossible.
    static let overhang: CGFloat = 60

    /// Pure AppKit backdrop: a CAShapeLayer traced from the island's real
    /// outline (published by SwiftUI) but ALWAYS extended to the window's top.
    /// No layout, no animation, no SwiftUI involvement in the top edge.
    private let backdrop = NSView()
    private let backdropShape = CAShapeLayer()

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

        let containerSize = CGSize(width: expandedSize.width,
                                   height: expandedSize.height + Self.overhang)
        let container = NSView(frame: NSRect(origin: .zero, size: containerSize))
        container.wantsLayer = true

        // Backdrop first (bottom of the z-order), filled later from the
        // island's reported outline. Its top always equals the window's top,
        // which is above the screen.
        backdrop.wantsLayer = true
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.layer?.addSublayer(backdropShape)
        backdropShape.fillColor = NSColor.black.cgColor
        backdropShape.isHidden = true
        container.addSubview(backdrop)

        // SwiftUI content occupies the on-screen part of the window only: it
        // starts `overhang` below the window's top, i.e. exactly at the
        // physical screen edge. It never has to know the edge exists.
        hosting.frame = NSRect(x: 0, y: 0,
                               width: containerSize.width,
                               height: expandedSize.height)
        hosting.autoresizingMask = [.width]
        container.addSubview(hosting)
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
                    self?.updateBackdrop()
                }
            }
        setupHoverCatcher()
        updateVisibility()
        startVisibilityHeartbeat()
        startPassThroughTracking()
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
            // Idle-only: when mascots are on screen, hovering the notch must
            // do nothing — the bubble belongs to the mascot, and the full
            // panel opens by click / hotkey / an actual request.
            guard self.store.activeSessions.isEmpty else { return }
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
        // Only the upper strip of the notch is a trigger (see HoverTuning).
        let h = min(metrics.hasNotch ? metrics.notchHeight : 24, HoverTuning.stripHeight)
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
        updateBackdrop()
        layoutHoverCatcher()

        let width = max(expandedSize.width, metrics.notchWidth + 200)
        // Window is `overhang` taller; its top sits ABOVE the physical screen.
        let size = CGSize(width: width, height: expandedSize.height + Self.overhang)
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
        // Bottom of the window = screen top − visible height; the extra
        // `overhang` on top pokes past the screen edge and is clipped by macOS.
        let y = screen.frame.maxY - expandedSize.height
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.frame != frame {
            if panel.isVisible, abs(panel.frame.maxY - (screen.frame.maxY + Self.overhang)) > 0.5 {
                Diagnostics.log("correcting drifted panel: was maxY \(panel.frame.maxY), expected \(screen.frame.maxY + Self.overhang)")
            }
            panel.setFrame(frame, display: true, animate: false)
        }
        _ = animated
    }

    /// The window is a large transparent canvas (680×460) so SwiftUI can
    /// animate the island inside it. Whenever the pointer is NOT over the
    /// visible island, the whole window becomes click-through so menu-bar
    /// items and window controls underneath stay usable. Re-evaluated on a
    /// fast timer because the pointer can move without any SwiftUI event.
    private var passThroughTimer: Timer?
    private func startPassThroughTracking() {
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.updatePassThrough()
        }
        RunLoop.main.add(t, forMode: .common)
        passThroughTimer = t
    }

    private func updatePassThrough() {
        guard panel.isVisible else { return }
        let island = metrics.islandFrame
        // While collapsed, the mascot strip is the only interactive area and
        // sits within the reported frame as well.
        guard !island.isEmpty else { panel.ignoresMouseEvents = false; return }
        let mouse = NSEvent.mouseLocation                     // screen coords
        let inWindow = panel.convertPoint(fromScreen: mouse)  // window coords
        // islandFrame is reported in SwiftUI "global" space = window space
        // with a top-left origin; flip to AppKit's bottom-left origin.
        // hosting view is `expandedSize.height` tall at the bottom of the
        // window; island coords are top-left within it.
        let flipped = CGRect(x: island.minX,
                             y: expandedSize.height - island.maxY,
                             width: island.width, height: island.height)
        let over = flipped.insetBy(dx: -4, dy: -4).contains(inWindow)
        if panel.ignoresMouseEvents == over {
            panel.ignoresMouseEvents = !over
        }
    }

    /// Keeps hosted content pinned to the very top of the window. macOS
    /// re-applies a safe-area inset to windows that overlap the menu bar at
    /// unpredictable moments — that inset is the recurring sliver of desktop
    /// above the island. We (a) clear it again and (b) publish whatever
    /// remains so the root view can cancel it with negative padding.
    /// Rebuild the backdrop from the island's outline. Called on every store
    /// change and heartbeat. The path: window-top edge (above the screen) →
    /// straight down to where the visible island's flare wings begin → the
    /// island's own outline. Hidden while collapsed (mascots only).
    private func updateBackdrop() {
        let open = store.expanded && store.toast == nil
        let island = metrics.islandFrame           // SwiftUI global = hosting coords, top-left origin
        guard open, island.width > 100 else {
            backdropShape.isHidden = true
            return
        }
        backdropShape.isHidden = false

        let H = backdrop.bounds.height             // includes overhang
        let hostH = expandedSize.height
        // Convert island (top-left origin within hosting) → AppKit bottom-left
        // origin within the container (hosting sits at the bottom).
        let left = island.minX
        let right = island.maxX
        let bottom = hostH - island.maxY           // AppKit y of island bottom
        let screenTop = hostH                      // AppKit y of the physical screen edge
        let tr: CGFloat = 26                       // NotchRootView.topRadius (expanded)
        let br: CGFloat = 32                       // NotchRootView.bottomRadius (expanded)

        let path = CGMutablePath()
        // Above the screen: full island width, all the way to the window top.
        path.move(to: CGPoint(x: left, y: H))
        path.addLine(to: CGPoint(x: right, y: H))
        path.addLine(to: CGPoint(x: right, y: screenTop))
        // Right flare wing (concave), then body side, bottom corners, left side.
        path.addQuadCurve(to: CGPoint(x: right - tr, y: screenTop - tr),
                          control: CGPoint(x: right - tr, y: screenTop))
        path.addLine(to: CGPoint(x: right - tr, y: bottom + br))
        path.addQuadCurve(to: CGPoint(x: right - tr - br, y: bottom),
                          control: CGPoint(x: right - tr, y: bottom))
        path.addLine(to: CGPoint(x: left + tr + br, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left + tr, y: bottom + br),
                          control: CGPoint(x: left + tr, y: bottom))
        path.addLine(to: CGPoint(x: left + tr, y: screenTop - tr))
        path.addQuadCurve(to: CGPoint(x: left, y: screenTop),
                          control: CGPoint(x: left + tr, y: screenTop))
        path.closeSubpath()
        backdropShape.frame = backdrop.bounds
        backdropShape.path = path
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

    /// The mascot's rect in SCREEN coordinates.
    ///
    /// SwiftUI reports `mascotFrame` in the hosting view's space (top-left
    /// origin). The hosting view sits at the BOTTOM of a container that is
    /// `overhang` points taller than the screen area, so using those numbers
    /// directly — as the old in-window bubble did — drew the popup `overhang`
    /// points too low. Convert properly: flip Y, then hosting → window →
    /// screen.
    func mascotScreenRect() -> CGRect? {
        guard let hosting = hostingView else { return nil }
        let r = metrics.mascotFrame
        guard r.width > 4, r.height > 4 else { return nil }
        // NSHostingView is a FLIPPED view (top-left origin), so SwiftUI's
        // rect is already in its coordinate space — flipping by hand here
        // double-flips and throws the popup hundreds of points down the
        // screen. Only flip if the host is not flipped.
        let inHosting = hosting.isFlipped
            ? r
            : NSRect(x: r.minX, y: hosting.bounds.height - r.maxY,
                     width: r.width, height: r.height)
        let inWindow = hosting.convert(inHosting, to: nil)
        return panel.convertToScreen(inWindow)
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
