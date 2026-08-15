import Foundation
import Combine

struct UsageWindow: Equatable {
    var percent: Int?       // nil if unknown
    var resetIn: String     // "4h1m" / "58m" / "2d3h"
}

/// Approximates Claude Code subscription usage locally by scanning transcript
/// JSONL files under ~/.claude/projects. Percentages are utilization relative
/// to the busiest comparable window in the last 14 days (no network, no keys).
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var fiveHour: UsageWindow?
    @Published private(set) var sevenDay: UsageWindow?

    private var isScanning = false
    private var timer: Timer?

    func start() {
        rescan()
        let t = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rescan() }
        }
        t.tolerance = 30
        timer = t
    }

    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task.detached(priority: .utility) {
            let events = Self.collectEvents()
            let (five, seven) = Self.compute(events: events, now: Date())
            await MainActor.run {
                self.fiveHour = five
                self.sevenDay = seven
                self.isScanning = false
            }
        }
    }

    // MARK: - Scanning

    private struct TokenEvent {
        var date: Date
        var tokens: Int
    }

    nonisolated private static func collectEvents() -> [TokenEvent] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys:
            [.contentModificationDateKey, .fileSizeKey]) else { return [] }

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso = ISO8601DateFormatter()
        let cutoff = Date().addingTimeInterval(-15 * 86400)

        var events: [TokenEvent] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let mod = vals.contentModificationDate, mod > cutoff,
                  (vals.fileSize ?? 0) < 50_000_000,
                  let data = try? Data(contentsOf: url) else { continue }

            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
                let line = data[start..<end]
                guard !line.isEmpty,
                      let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (obj["type"] as? String) == "assistant",
                      let ts = obj["timestamp"] as? String,
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any]
                else { continue }
                guard let date = isoFrac.date(from: ts) ?? iso.date(from: ts) else { continue }
                let tokens = (usage["input_tokens"] as? Int ?? 0)
                    + (usage["output_tokens"] as? Int ?? 0)
                    + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                if tokens > 0 { events.append(TokenEvent(date: date, tokens: tokens)) }
            }
        }
        return events.sorted { $0.date < $1.date }
    }

    // MARK: - Windows

    nonisolated private static func compute(events: [TokenEvent], now: Date)
        -> (UsageWindow?, UsageWindow?) {
        guard !events.isEmpty else { return (nil, nil) }

        // 5h session blocks (ccusage-style): a block starts at an event's
        // timestamp floored to the hour, and ends 5h later or after a 5h gap.
        struct Block { var start: Date; var tokens: Int; var lastEvent: Date }
        var blocks: [Block] = []
        for e in events {
            if var b = blocks.last,
               e.date < b.start.addingTimeInterval(5 * 3600),
               e.date.timeIntervalSince(b.lastEvent) < 5 * 3600 {
                b.tokens += e.tokens
                b.lastEvent = e.date
                blocks[blocks.count - 1] = b
            } else {
                let floored = Date(timeIntervalSince1970:
                    (e.date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
                blocks.append(Block(start: floored, tokens: e.tokens, lastEvent: e.date))
            }
        }

        var five: UsageWindow?
        if let current = blocks.last, now < current.start.addingTimeInterval(5 * 3600) {
            let history = blocks.filter { $0.start > now.addingTimeInterval(-14 * 86400) }
            var percent: Int?
            if history.count >= 2, let peak = history.map(\.tokens).max(), peak > 0 {
                percent = min(100, max(1, Int((Double(current.tokens) / Double(peak)) * 100)))
            }
            let resetIn = current.start.addingTimeInterval(5 * 3600).timeIntervalSince(now)
            five = UsageWindow(percent: percent, resetIn: format(resetIn))
        }

        // Trailing 7-day window.
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        let inWindow = events.filter { $0.date > weekAgo }
        var seven: UsageWindow?
        if let oldest = inWindow.first {
            let total = inWindow.reduce(0) { $0 + $1.tokens }
            // Peak trailing-7d sum sampled at each block boundary in the last 14d.
            var peak = 0
            for b in blocks where b.start > now.addingTimeInterval(-14 * 86400) {
                let s = events
                    .filter { $0.date > b.start.addingTimeInterval(-7 * 86400) && $0.date <= b.start }
                    .reduce(0) { $0 + $1.tokens }
                peak = max(peak, s)
            }
            peak = max(peak, total)
            var percent: Int?
            if blocks.count >= 2, peak > 0 {
                percent = min(100, max(1, Int((Double(total) / Double(peak)) * 100)))
            }
            let resetIn = oldest.date.addingTimeInterval(7 * 86400).timeIntervalSince(now)
            seven = UsageWindow(percent: percent, resetIn: format(resetIn))
        }
        return (five, seven)
    }

    nonisolated private static func format(_ interval: TimeInterval) -> String {
        let mins = max(0, Int(interval) / 60)
        if mins >= 1440 {
            let d = mins / 1440, h = (mins % 1440) / 60
            return h == 0 ? "\(d)d" : "\(d)d\(h)h"
        }
        if mins >= 60 {
            let h = mins / 60, m = mins % 60
            return m == 0 ? "\(h)h" : "\(h)h\(m)m"
        }
        return "\(mins)m"
    }
}
