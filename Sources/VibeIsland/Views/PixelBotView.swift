import SwiftUI

/// Tiny pixel-art robot mascot, tinted by session status, with subtle frame
/// animation while the agent is working (blink + antenna flicker).
struct PixelBotView: View {
    var color: Color
    var animating: Bool

    private static let pixel: CGFloat = 1.8

    // 11×8 grids; 0 empty, 1 body, 2 eye pixels (transparent = eye holes).
    private static let frameOpen: [[Int]] = [
        [0,0,0,0,0,1,0,0,0,0,0],
        [0,0,0,0,0,1,0,0,0,0,0],
        [0,1,1,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,1,1,1,1,1],
        [1,1,2,2,1,1,1,2,2,1,1],
        [1,1,2,2,1,1,1,2,2,1,1],
        [1,1,1,1,1,1,1,1,1,1,1],
        [0,1,1,2,2,2,2,2,1,1,0],
    ]
    private static let frameBlink: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,1,0,0,0,0,0],
        [0,1,1,1,1,1,1,1,1,1,0],
        [1,1,1,1,1,1,1,1,1,1,1],
        [1,1,1,1,1,1,1,1,1,1,1],
        [1,1,2,2,1,1,1,2,2,1,1],
        [1,1,1,1,1,1,1,1,1,1,1],
        [0,1,1,2,2,2,2,2,1,1,0],
    ]

    var body: some View {
        if animating {
            TimelineView(.periodic(from: .now, by: 0.4)) { context in
                let beat = Int(context.date.timeIntervalSince1970 / 0.4)
                grid(beat % 6 == 5 ? Self.frameBlink : Self.frameOpen)
            }
        } else {
            grid(Self.frameOpen)
        }
    }

    private func grid(_ rows: [[Int]]) -> some View {
        VStack(spacing: 0.6) {
            ForEach(0..<rows.count, id: \.self) { y in
                HStack(spacing: 0.6) {
                    ForEach(0..<rows[y].count, id: \.self) { x in
                        Rectangle()
                            .fill(rows[y][x] == 1 ? color : Color.clear)
                            .frame(width: Self.pixel, height: Self.pixel)
                    }
                }
            }
        }
        .frame(width: 26, height: 20)
    }
}
