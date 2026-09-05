import SwiftUI
import AppKit

/// agent-notch's visual kit, ported to SwiftUI (source: vendor/agent-notch,
/// MIT). The Claude Code launch-banner mascot drawn from its real block
/// characters, the official Codex pet spritesheets, the "freshly done" green
/// blob, the green pixel checkmark, and the dither separator.
enum MascotKit {
    static let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34)

    // Two frames — the feet alternate so it walks.
    static let crabFrames: [[String]] = [
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▘▘ ▝▝  "],
        [" ▐▛███▜▌ ",
         "▝▜█████▛▘",
         "  ▝▝ ▘▘  "],
    ]
    // quadrant bits: (upper-left, upper-right, lower-left, lower-right)
    static let quadrants: [Character: (Bool, Bool, Bool, Bool)] = [
        "█": (true, true, true, true),
        "▐": (false, true, false, true),
        "▌": (true, false, true, false),
        "▛": (true, true, true, false),
        "▜": (true, true, false, true),
        "▙": (true, false, true, true),
        "▟": (false, true, true, true),
        "▘": (true, false, false, false),
        "▝": (false, true, false, false),
        "▖": (false, false, true, false),
        "▗": (false, false, false, true),
        " ": (false, false, false, false),
    ]

    static func hashNoise(_ i: Int, _ j: Int, _ extra: Int, step: Int) -> Double {
        let n = sin(Double(i * 374761 + j * 668265 + extra * 97 + step * 982451) * 0.0001) * 43758.5453
        return n - n.rounded(.down)
    }
}

// MARK: - Claude crab (walking block-character mascot)

struct CrabView: View {
    var animating: Bool
    var scale: CGFloat = 1.0
    var tint: Color = MascotKit.claudeOrange

    var body: some View {
        Group {
            if animating {
                // Frames only change ~3x/sec (walk step every 0.4s); redrawing
                // at 10fps tripled the app's CPU for identical pixels.
                TimelineView(.periodic(from: .now, by: 0.3)) { ctx in
                    canvas(t: ctx.date.timeIntervalSince1970)
                }
            } else {
                canvas(t: 0)
            }
        }
        .frame(width: 30 * scale, height: 21 * scale)
    }

    private func canvas(t: TimeInterval) -> some View {
        Canvas { ctx, size in
            let subW: CGFloat = 1.6 * scale, subH: CGFloat = 3.2 * scale
            let walk = Int(t * 2.5)
            let frame = MascotKit.crabFrames[animating ? walk % 2 : 0]
            let bob: CGFloat = (animating && walk % 2 == 0) ? -0.5 : 0.5
            let x0: CGFloat = (size.width - CGFloat(frame[0].count * 2) * subW) / 2
            let y0 = size.height / 2 - CGFloat(frame.count * 2) * subH / 2 + bob
            let step = Int(t * 3)
            for (j, line) in frame.enumerated() {
                for (i, ch) in line.enumerated() {
                    guard let q = MascotKit.quadrants[ch] else { continue }
                    let cells = [(q.0, 0, 0), (q.1, 1, 0), (q.2, 0, 1), (q.3, 1, 1)]
                    for (on, qx, qy) in cells where on {
                        let r = MascotKit.hashNoise(i, j, qx + qy * 2, step: step)
                        let isFeet = j == frame.count - 1
                        let alpha = isFeet ? 1.0 : 0.8 + 0.2 * r
                        let rect = CGRect(x: x0 + CGFloat(i * 2 + qx) * subW,
                                          y: y0 + CGFloat(j * 2 + qy) * subH,
                                          width: subW - 0.3, height: subH - 0.4)
                        ctx.fill(Path(rect), with: .color(tint.opacity(alpha)))
                    }
                }
            }
        }
    }
}

// MARK: - Codex pet (official spritesheets, user-selectable)

/// Pet chosen via ~/.config/agent-notch/pet (codex, dewey, fireball, rocky,
/// seedy, stacky, bsod, null-signal) — same config file as agent-notch, so
/// existing setups carry over. Re-read every few seconds.
enum PetStore {
    private static var frameCache: [String: [NSImage]] = [:]
    private static var choice = "codex"
    private static var lastCheck = Date.distantPast

    static func currentPetID() -> String {
        if Date().timeIntervalSince(lastCheck) > 3 {
            lastCheck = Date()
            let cfg = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/agent-notch/pet")
            if let id = try? String(contentsOf: cfg, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
                choice = id
            }
        }
        return choice
    }

    /// Row 1 of the sheet (8 frames of 192×208) sliced once per pet.
    static func frames(for id: String) -> [NSImage] {
        if let cached = frameCache[id] { return cached }
        guard let url = Bundle.module.url(forResource: "pet-\(id)", withExtension: "webp",
                                          subdirectory: "pets"),
              let sheet = NSImage(contentsOf: url) else {
            frameCache[id] = []
            return []
        }
        let fw: CGFloat = 192, fh: CGFloat = 208, sheetH: CGFloat = 1872
        var out: [NSImage] = []
        for i in 0..<8 {
            let src = NSRect(x: CGFloat(i) * fw, y: sheetH - 2 * fh, width: fw, height: fh)
            let frame = NSImage(size: NSSize(width: fw, height: fh))
            frame.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            sheet.draw(in: NSRect(x: 0, y: 0, width: fw, height: fh),
                       from: src, operation: .sourceOver, fraction: 1)
            frame.unlockFocus()
            out.append(frame)
        }
        frameCache[id] = out
        return out
    }
}

struct PetSpriteView: View {
    var animating: Bool
    var height: CGFloat = 26

    var body: some View {
        Group {
            if animating {
                TimelineView(.periodic(from: .now, by: 0.12)) { ctx in
                    frameImage(at: ctx.date)
                }
            } else {
                frameImage(at: nil)
            }
        }
    }

    @ViewBuilder
    private func frameImage(at date: Date?) -> some View {
        let frames = PetStore.frames(for: PetStore.currentPetID())
        if frames.isEmpty {
            CrabView(animating: animating, tint: AgentKind.codex.brandColor)
        } else {
            let idx = date.map { Int($0.timeIntervalSince1970 / 0.12) % frames.count } ?? 0
            Image(nsImage: frames[idx])
                .resizable()
                .interpolation(.none)
                .aspectRatio(192.0 / 208.0, contentMode: .fit)
                .frame(height: height)
        }
    }
}

// MARK: - Attention pulse

/// Slow breathing glow for "an agent is waiting on you". Driven by a timeline
/// rather than a repeating SwiftUI animation so it can't get stuck mid-cycle
/// when the view is rebuilt.
struct AttentionPulse: ViewModifier {
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 15.0)) { ctx in
            let phase = ctx.date.timeIntervalSince1970 * 1.6
            let t = (sin(phase) + 1) / 2                       // 0…1
            content
                .opacity(0.6 + 0.4 * t)
                .scaleEffect(0.94 + 0.06 * t)
        }
    }
}

// MARK: - Green blob ("finished since you last looked")

struct GreenBlobView: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            Canvas { g, size in
                let cell: CGFloat = 2.5, grid = 7
                let c = CGFloat(grid) / 2
                let step = Int(ctx.date.timeIntervalSince1970 * 2)
                let x0 = (size.width - CGFloat(grid) * cell) / 2
                let y0 = (size.height - CGFloat(grid) * cell) / 2
                for i in 0..<grid {
                    for j in 0..<grid {
                        let dx = CGFloat(i) + 0.5 - c, dy = CGFloat(j) + 0.5 - c
                        let dist = sqrt(dx * dx + dy * dy)
                        let r = MascotKit.hashNoise(i, j, 0, step: step)
                        guard r > 0.1 + dist / c * 0.8 else { continue }
                        g.fill(Path(CGRect(x: x0 + CGFloat(i) * cell, y: y0 + CGFloat(j) * cell,
                                           width: cell - 0.5, height: cell - 0.5)),
                               with: .color(.green.opacity(0.5 + 0.5 * r)))
                    }
                }
            }
        }
        .frame(width: 20, height: 20)
    }
}

// MARK: - Green pixel checkmark (done rows)

struct PixelCheckView: View {
    private static let bitmap = [
        "......#",
        ".....##",
        "#...##.",
        "##.##..",
        ".###...",
        "..#....",
    ]

    var body: some View {
        Canvas { ctx, size in
            let rows = Self.bitmap.count, cols = Self.bitmap[0].count
            let cell = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            let x0 = (size.width - CGFloat(cols) * cell) / 2
            let y0 = (size.height - CGFloat(rows) * cell) / 2
            for (j, line) in Self.bitmap.enumerated() {
                for (i, ch) in line.enumerated() where ch == "#" {
                    ctx.fill(Path(CGRect(x: x0 + CGFloat(i) * cell, y: y0 + CGFloat(j) * cell,
                                         width: cell - 0.4, height: cell - 0.4)),
                             with: .color(Color(red: 0.35, green: 0.85, blue: 0.45)))
                }
            }
        }
        .frame(width: 16, height: 14)
    }
}

// MARK: - Dither separator (their row divider)

struct DitherSeparatorView: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 2
            var i = 0
            var x: CGFloat = 0
            while x < size.width {
                let r = MascotKit.hashNoise(i, 7, 0, step: 0)
                if r > 0.45 {
                    ctx.fill(Path(CGRect(x: x, y: size.height / 2 - 1, width: cell - 0.6, height: cell - 0.6)),
                             with: .color(.white.opacity(0.10 + 0.10 * r)))
                }
                x += cell
                i += 1
            }
        }
        .frame(height: 3)
    }
}
