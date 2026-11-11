import Foundation
import Darwin

/// Bounded subprocess capture for background discovery.
enum ProcessCapture {
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        // A regular file avoids full-pipe deadlocks. Never call waitUntilExit
        // from a dispatched reader: timed-out tasks used to leak one blocked
        // utility worker each, eventually exhausting the entire dispatch pool.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("vibe-process-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        p.standardOutput = handle
        p.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return nil }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            p.terminate()
            if finished.wait(timeout: .now() + 0.2) != .success, p.isRunning {
                kill(p.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        return try? String(contentsOf: output, encoding: .utf8)
    }
}
