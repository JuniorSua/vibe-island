import Foundation
import AppKit

/// Zero-config discovery of Codex (GPT) sessions and process-level liveness
/// for Claude sessions. No hooks needed: Codex holds its rollout transcript
/// open while working. `ps` + `lsof` establish ownership; rollout events
/// establish turn state, with a timeout fallback for older transcripts. Adapted from agent-notch (MIT, github.com/realfishsam/
/// agent-notch), with one deliberate difference: we do NOT require a TTY,
/// because T3 Code spawns agents headless and those must still appear.
///
/// Codex sessions are observe-only (there is no hook channel to answer
/// through); they surface as working / done rows with prompt + model.
final class CodexWatcher {
    static let shared = CodexWatcher()

    private let queue = DispatchQueue(label: "vibeisland.codexwatcher", qos: .utility)
    private var timer: Timer?
    private var scanning = false
    private var readers: [String: CodexTranscriptReader] = [:]

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = 1
        timer = t
        RunLoop.main.add(t, forMode: .common)
        poll()
    }

    // MARK: - Poll

    private struct RolloutState {
        var id: String            // "codex-<threadID>"
        var title: String
        var prompt: String?
        var model: String?
        var snippet: String?
        var cwd: String?
        var tty: String?
        var termProgram: String?
        var turnStartedAt: Date?
        var busy: Bool
        var processAlive: Bool
        var lastWrite: Date
    }

    private func poll() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            let procs = Self.agentProcesses()
            let codexPids = procs.filter { $0.kind == "codex" }.map(\.pid)
            let chunks = Self.lsofChunks(pids: codexPids)

            // rollout path → owning process info
            var owners: [String: (tty: String?, cwd: String?)] = [:]
            for p in procs where p.kind == "codex" {
                guard let lsof = chunks[p.pid] else { continue }
                let cwd = Self.cwd(fromLsof: lsof)
                for path in Self.paths(inLsof: lsof, containing: "/sessions/") {
                    owners[path] = (p.tty, cwd)
                }
            }

            let states = self.recentRollouts(owners: owners)
            let claudeCount = procs.filter { $0.kind == "claude" }.count

            DispatchQueue.main.async {
                self.apply(states, claudeProcessCount: claudeCount)
                self.scanning = false
            }
        }
    }

    // MARK: - Apply to the store (main actor)

    @MainActor
    private func apply(_ states: [RolloutState], claudeProcessCount: Int) {
        let store = SessionStore.shared

        for st in states {
            if let existing = store.session(id: st.id) {
                let newStatus: SessionStatus
                if st.busy {
                    newStatus = .working
                } else if existing.status == .working {
                    // Explicit completion, or a conservative legacy timeout.
                    newStatus = .done
                } else if !st.processAlive && existing.status == .done,
                          Date().timeIntervalSince(st.lastWrite) > 600 {
                    newStatus = .ended
                } else {
                    newStatus = existing.status
                }
                let modelChanged = existing.model != st.model && st.model != nil
                let titleChanged = existing.title != st.title && st.prompt != nil
                let recapChanged = existing.recap != st.snippet && st.snippet != nil
                let newTurn = st.busy && (existing.status != .working ||
                    st.turnStartedAt.map { $0 > existing.startedAt } == true)
                let locationChanged = st.termProgram != nil && st.termProgram != existing.termProgram
                if newStatus != existing.status || modelChanged || titleChanged || recapChanged || newTurn || locationChanged {
                    if newStatus != existing.status {
                        Diagnostics.log("[codex] \(st.id) \(existing.status.rawValue) → \(newStatus.rawValue)")
                    }
                    store.update(id: st.id) { s in
                        s.status = newStatus
                        if newTurn {
                            s.startedAt = st.turnStartedAt ?? Date()
                            s.acknowledged = false
                            s.recap = st.snippet
                        }
                        if let program = st.termProgram { s.termProgram = program }
                        if let m = st.model { s.model = m }
                        if st.prompt != nil { s.title = st.title; s.prompt = st.prompt }
                        if let sn = st.snippet { s.recap = sn }
                        if s.tty == nil { s.tty = st.tty }
                        if s.cwd == nil { s.cwd = st.cwd }
                    }
                }
            } else if st.busy {
                // Only surface a codex session once it is actually working —
                // stale rollouts from earlier in the day stay invisible.
                let session = Session(
                    id: st.id,
                    agent: .codex,
                    title: st.title,
                    prompt: st.prompt,
                    cwd: st.cwd,
                    termProgram: st.termProgram,
                    termSession: nil,
                    tty: st.tty,
                    status: .working,
                    startedAt: st.turnStartedAt ?? Date(),
                    lastEventAt: Date(),
                    recap: st.snippet,
                    model: st.model
                )
                store.upsert(session)
                Diagnostics.log("[codex] discovered \(st.id)")
            }
        }

        // Codex sessions whose rollout vanished from the scan (deleted file,
        // aged out mid-turn) must not stay "working" forever.
        let seen = Set(states.map(\.id))
        for s in store.sessions where s.agent == .codex && s.status == .working && !seen.contains(s.id) {
            store.update(id: s.id) { $0.status = .done }
        }

        // Claude reaper: hook sessions stuck "working" whose process world
        // says otherwise. Conservative: if no claude process exists at all,
        // 2 minutes of silence is enough; if some exist (could be this one),
        // require 30 minutes (a live turn emits tool events far more often).
        for s in store.sessions where s.agent == .claudeCode && s.status == .working {
            let quiet = Date().timeIntervalSince(s.lastEventAt)
            if (claudeProcessCount == 0 && quiet > 120) || quiet > 1800 {
                store.update(id: s.id) { $0.status = .ended }
            }
        }
    }

    // MARK: - Process discovery (background queue)

    private static func agentProcesses() -> [(pid: String, tty: String?, kind: String)] {
        guard let out = ProcessCapture.run("/bin/ps", ["-Axo", "pid=,tty=,comm="], timeout: 2.0) else { return [] }
        var result: [(String, String?, String)] = []
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(maxSplits: 2, whereSeparator: \.isWhitespace)
            guard parts.count == 3 else { continue }
            let pid = String(parts[0])
            let tty = parts[1] == "??" ? nil : String(parts[1])
            let command = String(parts[2]).lowercased()
            let first = command
            if first == "claude" || first.hasSuffix("/claude") {
                result.append((pid, tty, "claude"))
            } else if first == "codex" || first.hasSuffix("/codex") {
                result.append((pid, tty, "codex"))
            }
        }
        return result
    }

    /// One lsof for all pids; -Fn output split per-pid on `p<pid>` markers.
    private static func lsofChunks(pids: [String]) -> [String: String] {
        guard !pids.isEmpty,
              let out = ProcessCapture.run("/usr/sbin/lsof",
                            ["-a", "-p", pids.joined(separator: ","), "-Fn"],
                            timeout: 2.0) else { return [:] }
        var chunks: [String: String] = [:]
        var pid: String?
        var cur = ""
        for line in out.split(whereSeparator: \.isNewline) {
            if line.first == "p" {
                if let p = pid { chunks[p] = cur }
                pid = String(line.dropFirst())
                cur = ""
            } else {
                cur += line + "\n"
            }
        }
        if let p = pid { chunks[p] = cur }
        return chunks
    }

    private static func cwd(fromLsof lsof: String) -> String? {
        let lines = lsof.split(whereSeparator: \.isNewline).map(String.init)
        for i in lines.indices where lines[i] == "fcwd" && lines.indices.contains(i + 1) {
            let next = lines[i + 1]
            guard next.first == "n" else { continue }
            let v = String(next.dropFirst()).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("/") { return v }
        }
        return nil
    }

    private static func paths(inLsof lsof: String, containing fragment: String) -> [String] {
        lsof.split(whereSeparator: \.isNewline).compactMap {
            guard $0.first == "n" else { return nil }
            let v = String($0.dropFirst()).trimmingCharacters(in: .whitespaces)
            return v.contains(fragment) && v.hasSuffix(".jsonl") ? v : nil
        }
    }


    // MARK: - Rollout scanning

    private func recentRollouts(owners: [String: (tty: String?, cwd: String?)]) -> [RolloutState] {
        let fm = FileManager.default
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let root = home.appendingPathComponent("sessions")
        var files = Set(owners.keys.map { URL(fileURLWithPath: $0) })
        let now = Date()
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let file as URL in en where file.pathExtension == "jsonl" {
                if let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   now.timeIntervalSince(mtime) < 30 * 60 { files.insert(file) }
            }
        }
        var out: [RolloutState] = []
        readers = readers.filter { files.contains(URL(fileURLWithPath: $0.key)) }
        for file in files {
            guard let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { continue }
            let reader = readers[file.path] ?? CodexTranscriptReader()
            readers[file.path] = reader
            let transcript = reader.read(file)
            guard let id = transcript.id, transcript.parentID == nil else { continue }
            let alive = owners[file.path] != nil
            let title = transcript.prompt.map { EventHandler.titleFrom(prompt: $0) }
                ?? transcript.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
            out.append(RolloutState(
                id: "codex-\(id)", title: title, prompt: transcript.prompt,
                model: transcript.model, snippet: transcript.snippet,
                cwd: transcript.cwd ?? owners[file.path]?.cwd, tty: owners[file.path]?.tty,
                termProgram: transcript.termProgram, turnStartedAt: transcript.turnStartedAt,
                busy: transcript.isBusy(lastWrite: mtime, processAlive: alive, now: now),
                processAlive: alive, lastWrite: mtime
            ))
        }
        return out
    }

}

// MARK: - Transcript parsing (shared with Claude model extraction)

/// Reads agent transcript JSONL heads/tails for metadata. Formats:
/// - Codex head: {"payload":{"id":…,"cwd":…,"parent_thread_id":…}}
/// - Codex user line: {"payload":{"type":"user_message","message":…}}
/// - Claude user line: {"type":"user","message":{"content":…}}
/// - model: any line containing "model":"…"
enum TranscriptInfo {
    static func codexMeta(of file: URL) -> (id: String, cwd: String?, parentID: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return (file.lastPathComponent, nil, nil) }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 262_144)
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\n").first,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = obj["payload"] as? [String: Any]
        else { return (file.deletingPathExtension().lastPathComponent, nil, nil) }
        return (
            (payload["id"] as? String) ?? file.deletingPathExtension().lastPathComponent,
            payload["cwd"] as? String,
            payload["parent_thread_id"] as? String
        )
    }

    static func tail(of file: URL) -> (model: String?, prompt: String?, snippet: String?) {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return (nil, nil, nil) }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let readLen: UInt64 = min(size, 131_072)
        try? fh.seek(toOffset: size - readLen)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return (nil, nil, nil) }

        var model: String?, prompt: String?, snippet: String?
        for line in text.split(separator: "\n").reversed() {
            if model == nil, let r = line.range(of: #""model":"([^"]+)""#, options: .regularExpression) {
                model = String(line[r].dropFirst(9).dropLast(1))
                    .replacingOccurrences(of: "claude-", with: "")
            }
            if prompt == nil || snippet == nil,
               let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                if prompt == nil, let p = userPrompt(obj) { prompt = p }
                if snippet == nil, let s = lastText(obj) { snippet = s }
            }
            if model != nil && prompt != nil && snippet != nil { break }
        }
        return (model, prompt, snippet)
    }

    static func model(of path: String) -> String? {
        tail(of: URL(fileURLWithPath: path)).model
    }

    private static func userPrompt(_ obj: [String: Any]) -> String? {
        if let payload = obj["payload"] as? [String: Any],
           payload["type"] as? String == "user_message",
           let m = payload["message"] as? String { return clean(m) }
        if obj["type"] as? String == "user", let msg = obj["message"] as? [String: Any] {
            if let c = msg["content"] as? String { return clean(c) }
            if let arr = msg["content"] as? [[String: Any]] {
                for part in arr where part["type"] as? String == "text" {
                    if let t = part["text"] as? String { return clean(t) }
                }
            }
        }
        return nil
    }

    private static func lastText(_ obj: [String: Any]) -> String? {
        var content: Any?
        if let msg = obj["message"] as? [String: Any] { content = msg["content"] }
        if content == nil, let payload = obj["payload"] as? [String: Any] {
            content = payload["content"] ?? (payload["message"] as? [String: Any])?["content"]
        }
        if let s = content as? String { return clean(s) }
        if let arr = content as? [[String: Any]] {
            for part in arr.reversed() {
                if let t = part["text"] as? String { return clean(t) }
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("<") || t.hasPrefix("{") { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 90 { t = String(t.prefix(90)) + "…" }
        return t
    }
}
