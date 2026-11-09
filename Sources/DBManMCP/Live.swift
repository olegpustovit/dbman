import Foundation

public struct Handshake: Equatable, Sendable { public var name: String, version: String, at: Date }

/// Which MCP clients are connected right now, and every `initialize` seen (the Agents window's VERIFY step and "N LIVE" chip).
public final class LiveSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var live: [ObjectIdentifier: Handshake] = [:]
    private var seen: [Handshake] = []
    /// Called after any change, on an arbitrary thread.
    public var onChange: (@Sendable () -> Void)?

    public var clients: [Handshake] { lock.lock(); defer { lock.unlock() }; return live.values.sorted { $0.at < $1.at } }
    /// Handshakes since the app started, newest last. // shortcut: unbounded for one app run, cap if agents reconnect in a loop
    public var handshakes: [Handshake] { lock.lock(); defer { lock.unlock() }; return seen }

    func opened(_ key: ObjectIdentifier, name: String, version: String) {
        let h = Handshake(name: name, version: version, at: Date())
        lock.lock(); live[key] = h; seen.append(h); lock.unlock()
        onChange?()
    }
    func closed(_ key: ObjectIdentifier) {
        lock.lock(); let had = live.removeValue(forKey: key) != nil; lock.unlock()
        if had { onChange?() }
    }
}
