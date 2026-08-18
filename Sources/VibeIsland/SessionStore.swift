import Foundation
import Combine

@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [Session] = []
    @Published var expanded: Bool = false
    /// Debug-only: force the hover chat bubble on for a screenshot test.
    @Published var debugForceBubble: Bool = false

    /// Bumped every 30s so time-based UI (elapsed labels, done-session expiry)
    /// re-evaluates even when no events arrive.
    @Published private(set) var tick = 0

    /// Short confirmation shown in the collapsed island after resolving a
    /// request (e.g. "✓ Production").
    struct Toast: Equatable {
        var symbol: String
        var text: String
        var color: ToastColor
        enum ToastColor: Equatable { case green, red, orange }
    }
    @Published var toast: Toast?
    private var toastGeneration = 0

    func showToast(_ toast: Toast, for seconds: Double = 2.6) {
        toastGeneration += 1
        let generation = toastGeneration
        self.toast = toast
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if self.toastGeneration == generation { self.toast = nil }
        }
    }

    /// Session id → (connection token, reply callback) for a held PreToolUse connection.
    private var pendingReplies: [String: (token: UUID, reply: (String) -> Void)] = [:]

    private let saveURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VibeIsland", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }()

    private init() {
        load()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick += 1
            }
        }
        timer.tolerance = 3
    }

    // MARK: - Derived

    var attentionCount: Int { sessions.filter { $0.status == .waiting }.count }
    var activeSessions: [Session] {
        let cutoff = Date().addingTimeInterval(-5 * 60)
        return sessions
            .filter { s in
                if s.status == .ended { return false }
                // Hide done sessions after 5 minutes; they stay in `sessions`
                // for persistence, just not displayed.
                if s.status == .done && s.lastEventAt < cutoff { return false }
                return true
            }
            .sorted { a, b in
                // waiting > working > done, then most recent first.
                func rank(_ s: SessionStatus) -> Int {
                    switch s {
                    case .waiting: return 0
                    case .working: return 1
                    case .done: return 2
                    case .ended: return 3
                    }
                }
                if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
                return a.lastEventAt > b.lastEventAt
            }
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    // MARK: - Mutation

    func upsert(_ session: Session) {
        if let i = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[i] = session
        } else {
            sessions.append(session)
        }
        save()
    }

    func update(id: String, _ mutate: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sessions[i])
        sessions[i].lastEventAt = Date()
        save()
    }

    func remove(id: String) {
        sessions.removeAll { $0.id == id }
        pendingReplies.removeValue(forKey: id)
        save()
    }

    func clearFinished() {
        sessions.removeAll { $0.status == .done || $0.status == .ended }
        save()
    }

    /// "Finished since you last looked" — activating a terminal acknowledges
    /// done sessions and clears their green blob in the mascot bar.
    func acknowledgeFinished() {
        var changed = false
        for i in sessions.indices where sessions[i].status == .done && !sessions[i].acknowledged {
            sessions[i].acknowledged = true
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Held connections (approval / question / plan)

    /// Hold a hook connection until the user acts. Returns a token identifying
    /// this connection; a newer hold for the same session releases the old one.
    func hold(sessionID: String, reply: @escaping (String) -> Void) -> UUID {
        pendingReplies[sessionID]?.reply("{}")
        let token = UUID()
        pendingReplies[sessionID] = (token, reply)
        return token
    }

    /// Resolve the pending request for a session with a raw JSON hook response.
    func resolve(sessionID: String, response: String) {
        pendingReplies.removeValue(forKey: sessionID)?.reply(response)
        update(id: sessionID) { s in
            s.pendingRequest = nil
            if s.status == .waiting { s.status = .working }
        }
    }

    /// Called when a held hook connection dies before the user answered.
    /// Only clears state if the dead connection is still the current holder.
    func abandonPending(sessionID: String, token: UUID) {
        guard pendingReplies[sessionID]?.token == token else { return }
        pendingReplies.removeValue(forKey: sessionID)
        update(id: sessionID) { s in
            s.pendingRequest = nil
            if s.status == .waiting { s.status = .working }
        }
    }

    // MARK: - Persistence

    /// Keep history bounded — the store grew into the hundreds over a week of
    /// use, which bloats every save and the launch parse.
    private static let historyCap = 150

    private func prune() {
        guard sessions.count > Self.historyCap else { return }
        let keep = sessions
            .sorted { $0.lastEventAt > $1.lastEventAt }
            .prefix(Self.historyCap)
        let keepIDs = Set(keep.map(\.id))
        sessions.removeAll { !keepIDs.contains($0.id) }
    }

    private func save() {
        prune()
        let snapshot = sessions
        let url = saveURL
        Task.detached(priority: .utility) {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var loaded = try? dec.decode([Session].self, from: data) else { return }
        // Anything restored from disk is no longer live: mark stale sessions ended,
        // and drop pending requests (their hook connections are gone).
        for i in loaded.indices {
            loaded[i].pendingRequest = nil
            if loaded[i].status == .working || loaded[i].status == .waiting {
                loaded[i].status = .ended
            }
        }
        sessions = loaded
        prune()
    }
}
