import SwiftUI

/// Top-level notch content: collapsed pill ↔ expanded session list / request,
/// with Dynamic-Island-style spring + blur morphs between states.
struct NotchRootView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var metrics: PanelMetrics
    @State private var hovering = false
    @State private var lastHoverChange = Date.distantPast
    @State private var lastExpand = Date.distantPast
    @State private var everHovered = false
    /// STATIC on purpose: as an instance property this publisher was recreated
    /// on every SwiftUI rebuild, so its 1s countdown restarted constantly and
    /// the collapse watchdog effectively never fired.
    private static let collapseCheck = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// A pending request OPENS the panel (EventHandler sets `expanded`), but no
    /// longer pins it open forever — an unanswered question used to sit across
    /// the top of the screen with no way to dismiss it. It now tucks back into
    /// an orange mascot after a grace period and re-opens on hover.
    private var isExpanded: Bool {
        store.expanded && store.toast == nil
    }

    /// How long an attention-opened panel stays up untouched.
    private let attentionGrace: TimeInterval = 12

    private var showsToast: Bool { store.toast != nil }

    /// Collapsed state is agent-notch style: NO black cover — the native notch
    /// stays visible and mascots walk beside it on a transparent bar. The
    /// black island shape only exists while expanded or showing a toast.
    private var showsBlackShape: Bool { isExpanded || showsToast }

    private var bottomRadius: CGFloat {
        if isExpanded { return 32 }
        return 16
    }

    /// Size of the concave top wings (the upside-down-bell swoop).
    private var topRadius: CGFloat {
        if isExpanded { return 26 }
        if showsToast { return 10 }
        return 0
    }

    /// Overdraw only matters where the black is drawn. Generous on purpose:
    /// anything above the window is harmlessly clipped by the window itself,
    /// but it must comfortably exceed any inset macOS applies to hosted
    /// content near the screen edge.
    private var topOverdraw: CGFloat { showsBlackShape ? 40 : 0 }

    private var shadowOpacity: Double {
        if isExpanded { return 0.55 }
        if showsToast { return 0.35 }
        return 0
    }

    private var morph: AnyTransition {
        .modifier(active: BlurModifier(radius: 8), identity: BlurModifier(radius: 0))
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.96, anchor: .top))
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if showsToast, let toast = store.toast {
                    ToastPillView(toast: toast)
                        .transition(morph)
                } else if isExpanded {
                    ExpandedPanelView()
                        .onHover(perform: handleHover)
                        .contextMenu { IslandContextMenu() }
                        .transition(morph)
                } else {
                    // Hover is handled INSIDE the mascot bar, on the visible
                    // mascots only — the invisible positioning spacer must
                    // never be a hover target.
                    MascotBarView(onHover: handleHover)
                        .transition(morph)
                }
            }
            // Reserve room for the flare wings so content stays in the body.
            .padding(.horizontal, topRadius)
            // Clip the CONTENT first (no overdraw here) so rows/diffs stay
            // inside the rounded body...
            .clipShape(NotchShape(bottomRadius: showsBlackShape ? bottomRadius : 0,
                                  topRadius: showsBlackShape ? topRadius : 0))
            // Report the island's true frame so the AppKit top-guard matches.
            .background(GeometryReader { geo in
                Color.clear.onAppear { metrics.islandFrame = geo.frame(in: .global) }
                    .onChange(of: geo.frame(in: .global)) { _, f in metrics.islandFrame = f }
            })
            // ...then paint the black BEHIND it, unclipped, so its overdraw
            // can extend past the top of the container. A clipShape applied
            // after the background masks to the view's bounds and silently
            // ate the overdraw — which is why the sliver kept coming back.
            .background(
                // The black is toggled by PRESENCE, never by fill colour: a
                // clear → black fill interpolates through translucent black,
                // and the bright menu bar showing through the top edge reads
                // as a gap between the island and the screen edge on every
                // hover. `.transition(.identity)` also suppresses SwiftUI's
                // default fade-in, so the shape is opaque on its first frame
                // while its geometry still grows with the container.
                Group {
                    if showsBlackShape {
                        NotchShape(bottomRadius: bottomRadius, topRadius: topRadius,
                                   topOverdraw: topOverdraw)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(shadowOpacity),
                                    radius: isExpanded ? 20 : 8,
                                    y: isExpanded ? 8 : 3)
                            .transition(.identity)
                    }
                }
            )
            .overlay(
                // Hairline edge so the expanded island separates cleanly from
                // dark content behind it. Invisible while collapsed.
                NotchShape(bottomRadius: bottomRadius, topRadius: topRadius,
                           topOverdraw: topOverdraw)
                    .stroke(Color.white.opacity(isExpanded ? 0.14 : 0), lineWidth: 1)
            )
            Spacer(minLength: 0)
        }
        // Fill the whole panel and center the island horizontally — an
        // NSHostingView left-aligns an undersized root, which pushed the
        // island off the notch.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Cancel any safe-area inset macOS re-applies to hosted content near
        // the screen edge; without this the island floats a few points below
        // the top and shows a sliver of desktop (measured live at 4.5 pt).
        .padding(.top, -metrics.contentInsetTop)
        .ignoresSafeArea(.all)
        // Watchdog: reliably collapse whenever nothing needs attention, the
        // mouse is outside the panel, and ~1s has passed since the last hover
        // change. Clicking inside the expanded panel keeps `hovering` true,
        // so it never collapses under the cursor.
        .onChange(of: store.expanded) { _, expanded in
            if expanded {
                lastExpand = Date()
                everHovered = false
            }
        }
        // Fallback watchdog for panels opened without the mouse (menu item /
        // attention): those keep a grace period so they aren't yanked shut
        // before the pointer ever arrives. Mouse-driven collapse is handled
        // instantly in onHover above.
        .onReceive(Self.collapseCheck) { _ in
            guard store.expanded, !hovering, !everHovered else { return }
            // Requests get a longer look-at-me window than an incidental open.
            let grace: TimeInterval = store.attentionCount > 0 ? attentionGrace : 4
            if Date().timeIntervalSince(lastExpand) > grace {
                store.expanded = false
            }
        }
        // Esc dismisses the panel, like any other transient macOS surface.
        .background(
            Button("") { store.expanded = false }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isExpanded)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: showsToast)
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: store.activeSessions)
    }

    /// Shared hover handler: entering visible content expands (or keeps the
    /// panel open); leaving snaps it shut after a tiny debounce.
    private func handleHover(_ over: Bool) {
        hovering = over
        lastHoverChange = Date()
        if over {
            everHovered = true
            if store.expanded { return }
            // Dwell before opening: passing through the strip on the way to a
            // menu-bar item or window control must not pop the panel. The
            // pointer has to still be there after the delay.
            let armedAt = lastHoverChange
            DispatchQueue.main.asyncAfter(deadline: .now() + HoverTuning.openDelay) {
                if hovering, lastHoverChange == armedAt, store.toast == nil {
                    store.expanded = true
                }
            }
        } else {
            // Snappy on mouse-out, but a request you're deciding on shouldn't
            // vanish the instant the pointer drifts off it.
            let delay: TimeInterval = store.attentionCount > 0 ? 1.5 : 0.2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if !hovering, store.expanded { store.expanded = false }
            }
        }
    }
}

/// Hover feel. Tuned so the island opens only when you clearly aim at it: a
/// short trigger strip hugging the notch (not the whole menu-bar height) plus
/// a dwell delay so a pointer merely passing by on its way to a window control
/// never opens the panel.
enum HoverTuning {
    /// Height of the collapsed hover strip, measured from the screen top.
    /// The notch is 32 pt tall; this keeps the trigger inside its upper part.
    static let stripHeight: CGFloat = 20
    /// Time the pointer must remain in the strip before the panel opens.
    static let openDelay: TimeInterval = 0.35
}

/// Animatable blur used to give pill ↔ panel swaps a Dynamic-Island-style
/// blur morph.
struct BlurModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: radius)
    }
}

/// Black island shape flush with the top edge. The top corners flare outward
/// with concave "wings" that sweep into the screen edge (the upside-down-bell
/// look of the real Dynamic Island); bottom corners are convex-rounded. With
/// topRadius 0 it degenerates to a plain notch cover.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    /// Extra height drawn ABOVE the view's top edge. macOS can inset hosted
    /// SwiftUI content a few points from the screen's top (safe area), which
    /// showed as a sliver of desktop between the island and the display edge;
    /// overdrawing guarantees the black always meets the top.
    var topOverdraw: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let tr = min(topRadius, rect.width / 4)
        let br = min(bottomRadius, (rect.height - tr) / 2)
        // The overdraw is a straight skirt ABOVE the real top edge — the wings
        // must stay anchored at rect.minY. (Shifting the whole shape upward
        // instead pushes the wings off screen and leaves the top corners
        // transparent.)
        let skirtY = rect.minY - topOverdraw
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: skirtY))
        p.addLine(to: CGPoint(x: rect.maxX, y: skirtY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right wing: concave swoop from the top edge into the body side.
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                       control: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.maxY - br))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - tr - br, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + tr + br, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + tr, y: rect.maxY - br),
                       control: CGPoint(x: rect.minX + tr, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + tr, y: rect.minY + tr))
        // Left wing back up to the top-left tip, then up the skirt.
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                       control: CGPoint(x: rect.minX + tr, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: skirtY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Toast

struct ToastPillView: View {
    @EnvironmentObject var metrics: PanelMetrics
    let toast: SessionStore.Toast

    private var tint: Color {
        switch toast.color {
        case .green: return Color(red: 0.35, green: 0.85, blue: 0.45)
        case .red: return Color(red: 0.95, green: 0.4, blue: 0.4)
        case .orange: return SessionStatus.waiting.color
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: toast.symbol)
                .font(.system(size: 11, weight: .bold))
            Text(toast.text)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 24)
        .frame(height: (metrics.hasNotch ? metrics.notchHeight : 30) + 8)
        .frame(minWidth: metrics.hasNotch ? metrics.notchWidth + 60 : 160)
    }
}

// MARK: - Collapsed mascot bar (agent-notch style)

/// The native notch stays visible; agents walk beside it on a transparent
/// bar. Per-agent slots: the Claude crab walks while any Claude session
/// works, the Codex pet while a GPT session works; a green blob marks
/// "finished since you last looked" (focusing a terminal clears it). An
/// orange-tinted crab means something is waiting on you.
struct MascotBarView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var metrics: PanelMetrics
    var onHover: (Bool) -> Void = { _ in }

    private var claudeSessions: [Session] {
        store.activeSessions.filter { $0.agent != .codex }
    }
    private var codexSessions: [Session] {
        store.activeSessions.filter { $0.agent == .codex }
    }

    private enum Slot { case working, waiting, doneFresh, none }

    private func slot(for sessions: [Session]) -> Slot {
        if sessions.contains(where: { $0.status == .waiting }) { return .waiting }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        if sessions.contains(where: { $0.status == .done && !$0.acknowledged }) { return .doneFresh }
        return .none
    }

    var body: some View {
        let claude = slot(for: claudeSessions)
        let codex = slot(for: codexSessions)

        if claude == .none && codex == .none {
            // No mascots, but the notch itself must stay hoverable/clickable
            // so the island opens even when no agents are running. Fully
            // transparent — the bare notch looks untouched — and sized to the
            // notch only, so nothing beyond it reacts. (Note: this can only
            // receive events while the panel window is ordered in.)
            Color.clear
                .frame(width: metrics.hasNotch ? metrics.notchWidth : 150,
                       height: min(metrics.hasNotch ? metrics.notchHeight : 24,
                                   HoverTuning.stripHeight))
                .frame(height: metrics.hasNotch ? metrics.notchHeight : 24, alignment: .top)
                .contentShape(Rectangle())
                .onHover(perform: onHover)
                .onTapGesture { store.expanded = true }
                .contextMenu { IslandContextMenu() }
        } else {
            let slotsWidth = width(claude) + width(codex)
                + (claude != .none && codex != .none ? 8 : 0)
            let notchZone = metrics.hasNotch ? metrics.notchWidth + 10 : 0
            // Layout-based positioning (an .offset would escape the container's
            // clip): a leading spacer sized so the hover zone starts at the
            // notch's left edge once the whole group is centered.
            HStack(spacing: 0) {
                if metrics.hasNotch {
                    Color.clear.frame(width: slotsWidth + 10, height: 1)
                }
                HStack(spacing: 0) {
                    // Hovering the notch itself counts — that's what people
                    // aim at — but the transparent area beyond this zone
                    // stays inert.
                    if notchZone > 0 {
                        Color.clear.frame(width: notchZone)
                    }
                    HStack(spacing: 8) {
                        slotView(claude, isCodex: false)
                        slotView(codex, isCodex: true)
                    }
                }
                .frame(height: max(metrics.notchHeight, 24))
                // Mascots draw at full height, but only the strip along the
                // very top is a hover target — the lower part of the notch
                // area stays inert so nearby controls remain clickable.
                .contentShape(Rectangle().path(in: CGRect(
                    x: 0, y: 0,
                    width: 100_000,
                    height: HoverTuning.stripHeight)))
                .onHover(perform: onHover)
                .onTapGesture { store.expanded = true }
                .contextMenu { IslandContextMenu() }
                .help("Vibe Island — click to open, right-click for settings")
            }
            .fixedSize()
        }
    }

    private func width(_ s: Slot) -> CGFloat {
        switch s {
        case .none: return 0
        case .doneFresh: return 20
        default: return 30
        }
    }

    @ViewBuilder
    private func slotView(_ slot: Slot, isCodex: Bool) -> some View {
        switch slot {
        case .working:
            if isCodex {
                PetSpriteView(animating: true, height: 24)
            } else {
                CrabView(animating: true)
            }
        case .waiting:
            // Pulses so an unanswered request still catches the eye once the
            // panel has tucked itself away.
            Group {
                if isCodex {
                    PetSpriteView(animating: false, height: 24)
                } else {
                    CrabView(animating: true, tint: SessionStatus.waiting.color)
                }
            }
            .modifier(AttentionPulse())
        case .doneFresh:
            GreenBlobView()
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Expanded panel

struct ExpandedPanelView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var metrics: PanelMetrics

    /// A pending interactive request takes over the whole panel. When several
    /// agents ask at once the rest queue up behind it (surfaced in the header
    /// so they aren't invisible).
    private var pendingSession: Session? {
        store.activeSessions.first { $0.pendingRequest != nil }
    }

    private var pendingCount: Int {
        store.activeSessions.filter { $0.pendingRequest != nil }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep content out of the physical notch cutout.
            if metrics.hasNotch {
                Color.clear.frame(height: metrics.notchHeight)
            }

            if let session = pendingSession, let request = session.pendingRequest {
                RequestView(session: session, request: request,
                            queuedBehind: pendingCount - 1)
                    .padding(14)
            } else {
                UsageStripView()
                if store.activeSessions.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(store.activeSessions.enumerated()), id: \.element.id) { i, session in
                                SessionRowView(session: session, prominent: i == 0)
                                if i < store.activeSessions.count - 1 {
                                    DitherSeparatorView()
                                        .padding(.leading, 44)
                                        .padding(.trailing, 10)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 360)
                    // ⌘1…⌘9 jump straight to a session's terminal without
                    // reaching for the mouse.
                    .background(
                        ForEach(Array(store.activeSessions.prefix(9).enumerated()), id: \.element.id) { i, session in
                            Button("") {
                                TerminalJump.jump(to: session)
                                store.expanded = false
                                if session.status == .done { store.remove(id: session.id) }
                            }
                            .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                        }
                    )
                }
            }
        }
        .padding(.bottom, 8)
        .frame(width: max(560, metrics.notchWidth + 340))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !HookInstaller.isInstalled {
            // "No agents working" is a lie when the plumbing simply isn't
            // connected — say so, and offer the one-click fix.
            VStack(spacing: 7) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("Claude Code isn't connected")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(SessionStatus.waiting.color)
                Text("Sessions can't appear until the notifier is installed.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                Button {
                    try? HookInstaller.install()
                } label: {
                    Text("Set up now")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                }
                .buttonStyle(LightButtonStyle())
                Text("Restart running sessions afterwards.")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        } else {
            standardEmptyState
        }
    }

    private var standardEmptyState: some View {
        VStack(spacing: 5) {
            Text("No agents working")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text("Start Claude Code in any terminal — sessions appear here.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 20)
    }
}

// MARK: - Usage strip

/// "✦ 5h 11% 4h1m │ 7d 2% 6h1m" — local approximation of Claude quota windows.
struct UsageStripView: View {
    @ObservedObject private var usage = UsageMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(red: 0.95, green: 0.55, blue: 0.25))
            if usage.fiveHour == nil && usage.sevenDay == nil {
                Text("usage —")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                if let five = usage.fiveHour {
                    windowLabel(name: "5h", window: five)
                }
                if usage.fiveHour != nil && usage.sevenDay != nil {
                    Text("│")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.2))
                }
                if let seven = usage.sevenDay {
                    windowLabel(name: "7d", window: seven)
                }
            }
            Spacer()
            Text("⌘1–9 jump  ·  ⌥⌘I toggle")
                .font(.system(size: 8.5))
                .foregroundStyle(.white.opacity(0.22))
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .help("Claude usage: share of your busiest 5-hour block and 7-day total in the last 14 days, with time until the window resets. Computed locally from your own transcripts.")
    }

    private func windowLabel(name: String, window: UsageWindow) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .foregroundStyle(.white.opacity(0.5))
            if let pct = window.percent {
                Text("\(pct)%")
                    .fontWeight(.bold)
                    .foregroundStyle(pct >= 80
                        ? SessionStatus.waiting.color
                        : Color(red: 0.35, green: 0.85, blue: 0.55))
            }
            Text(window.resetIn)
                .foregroundStyle(.white.opacity(0.3))
        }
        .font(.system(size: 10, design: .monospaced))
    }
}
