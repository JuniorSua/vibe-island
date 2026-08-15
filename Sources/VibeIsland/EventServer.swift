import AppKit
import Foundation
import Network

/// Lightweight local TCP server on 127.0.0.1 that receives one JSON event per
/// connection (newline-terminated) from agent hook scripts, and replies with a
/// JSON hook response before closing. Fire-and-forget events get "{}" instantly;
/// interactive events (permission / question / plan) hold the connection until
/// the user acts in the notch UI.
final class EventServer {
    static let port: UInt16 = 43917

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "vibeisland.eventserver")

    func start() {
        do {
            let params = NWParameters.tcp
            params.acceptLocalOnly = true
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: Self.port)!
            )
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    NSLog("VibeIsland: event server failed: \(err)")
                    if case .posix(let code) = err, code == .EADDRINUSE {
                        NSLog("VibeIsland: another Vibe Island instance is already running")
                        DispatchQueue.main.async { NSApp.terminate(nil) }
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            NSLog("VibeIsland: event server listening on 127.0.0.1:\(Self.port)")
        } catch {
            NSLog("VibeIsland: could not start event server: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveLine(conn, buffer: Data())
    }

    private func receiveLine(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                self.dispatch(Data(line), conn: conn)
            } else if isComplete || error != nil {
                if buffer.isEmpty {
                    conn.cancel()
                } else {
                    self.dispatch(buffer, conn: conn)
                }
            } else {
                self.receiveLine(conn, buffer: buffer)
            }
        }
    }

    private func dispatch(_ data: Data, conn: NWConnection) {
        let reply: (String) -> Void = { response in
            let out = Data((response + "\n").utf8)
            conn.send(content: out, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
        Task { @MainActor in
            EventHandler.shared.handle(data: data, reply: reply, onHold: { [queue] sessionID, token in
                let abandon = {
                    Task { @MainActor in
                        SessionStore.shared.abandonPending(sessionID: sessionID, token: token)
                    }
                    conn.cancel()
                }
                // nc half-closes after piping its stdin, so isComplete alone is
                // NOT a disconnect — the reply path is still open. Only a hard
                // error means the client died.
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                    if error != nil { abandon() }
                }
                // Heartbeat: a blank line every 15s. If the hook process was
                // killed (timeout, Ctrl-C), the send errors and we clear the
                // stale approval card. The hook script filters blank lines.
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 15, repeating: 15)
                timer.setEventHandler {
                    if conn.state != .ready {
                        timer.cancel()
                        return
                    }
                    conn.send(content: Data("\n".utf8), completion: .contentProcessed { err in
                        if err != nil {
                            timer.cancel()
                            abandon()
                        }
                    })
                }
                timer.resume()
            })
        }
    }
}
