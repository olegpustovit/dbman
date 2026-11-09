import Darwin
import Foundation

/// One `ssh -N -L` child forwarding a free loopback port to the database as seen from the SSH host.
/// Uses the system ssh in batch mode: keys, agent, ~/.ssh/config and known_hosts are the user's own; it never prompts.
public final class SSHTunnelProcess: @unchecked Sendable {
    public static var executable = "/usr/bin/ssh"
    /// How long `open` waits for the forward to accept connections.
    public static var readyTimeout: TimeInterval = 20

    public let tunnel: SSHTunnel
    public let localPort: Int
    private let process: Process
    private let errors = Pipe()
    private let lock = NSLock()
    private var stderrText = ""

    /// The ssh arguments (pure; tested). `--` keeps a hostile host string from being read as an option.
    public static func arguments(_ t: SSHTunnel, localPort: Int, targetHost: String, targetPort: Int) -> [String] {
        var a = ["-N", "-T",
                 "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                 "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
                 "-L", "127.0.0.1:\(localPort):\(targetHost.contains(":") ? "[\(targetHost)]" : targetHost):\(targetPort)"]
        if let p = t.port { a += ["-p", String(p)] }
        if let i = t.identityFile { a += ["-i", (i as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"] }
        if let u = t.user { a += ["-l", u] }
        return a + ["--", t.host]
    }

    private init(tunnel: SSHTunnel, localPort: Int, process: Process) {
        self.tunnel = tunnel; self.localPort = localPort; self.process = process
    }

    /// Starts ssh and waits until the forward accepts a TCP connection; throws `DBError.connection` with ssh's own reason otherwise.
    public static func open(_ t: SSHTunnel, targetHost: String, targetPort: Int) async throws -> SSHTunnelProcess {
        guard !t.host.isEmpty, !t.host.hasPrefix("-") else { throw DBError.connection("SSH host is empty or invalid") }
        let port = try freeLoopbackPort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments(t, localPort: port, targetHost: targetHost, targetPort: targetPort)
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        let tp = SSHTunnelProcess(tunnel: t, localPort: port, process: p)
        p.standardError = tp.errors
        tp.errors.fileHandleForReading.readabilityHandler = { [weak tp] h in
            let d = h.availableData
            guard let tp, !d.isEmpty else { h.readabilityHandler = nil; return }
            tp.lock.withLock { tp.stderrText += String(decoding: d, as: UTF8.self); if tp.stderrText.count > 8000 { tp.stderrText = String(tp.stderrText.suffix(4000)) } }
        }
        do { try p.run() } catch { throw DBError.connection("Could not start ssh: \(error.localizedDescription)") }
        Registry.shared.add(tp)
        // the wait is user-visible: keep App Nap from stretching the 100 ms polls into seconds
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Opening SSH tunnel")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let started = Date()
        let deadline = started.addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if !p.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000) // let stderr drain
                tp.close()
                throw DBError.connection("SSH tunnel via \(t.display) failed: \(tp.reason ?? "ssh exited with status \(p.terminationStatus)")")
            }
            if canConnect(port) { return tp }
            if Task.isCancelled { tp.close(); throw DBError.cancelled }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        tp.close()
        throw DBError.connection("SSH tunnel via \(t.display) timed out after \(Int(Date().timeIntervalSince(started).rounded())) s\(tp.reason.map { ": \($0)" } ?? "")")
    }

    public var isAlive: Bool { !lock.withLock { closed } && process.isRunning }
    private var closed = false

    /// Last meaningful stderr line (ssh's error), without warnings about known_hosts.
    public var reason: String? {
        let lines = lock.withLock { stderrText }.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Warning: Permanently added") }
        return lines.last
    }

    /// SIGTERM now, SIGKILL 2 s later if ssh is still up. Never blocks: `waitUntilExit` can deadlock when called from the main thread.
    public func close() {
        lock.withLock { closed = true }
        Registry.shared.remove(self)
        guard process.isRunning else { errors.fileHandleForReading.readabilityHandler = nil; return }
        let p = process, pid = p.processIdentifier
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
    }

    /// Kills every live tunnel (app termination).
    public static func closeAll() { Registry.shared.all().forEach { $0.close() } }

    // MARK: helpers

    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var items: [ObjectIdentifier: SSHTunnelProcess] = [:]
        func add(_ t: SSHTunnelProcess) { lock.withLock { items[ObjectIdentifier(t)] = t } }
        func remove(_ t: SSHTunnelProcess) { _ = lock.withLock { items.removeValue(forKey: ObjectIdentifier(t)) } }
        func all() -> [SSHTunnelProcess] { lock.withLock { Array(items.values) } }
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = in_port_t(UInt16(port).bigEndian)
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        return a
    }

    static func freeLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DBError.connection("No socket for the SSH tunnel") }
        defer { Darwin.close(fd) }
        var a = loopback(0)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw DBError.connection("No free local port for the SSH tunnel") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: a.sin_port))
    }

    static func canConnect(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var a = loopback(port)
        return withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}
