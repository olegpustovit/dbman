import Foundation

/// The Unix socket between `dbman-mcp` (agent side) and the app (SPEC §1.1). Shared so both sides compute the same path.
public enum UnixSocket {
    /// `<store dir>/mcp.sock`. sun_path holds 104 bytes: a longer path falls back to a short per-user one derived from it
    /// (FNV-1a: stable across processes, unlike Swift's seeded Hasher).
    public static func path(storeDir: String) -> String {
        let p = storeDir + "/mcp.sock"
        guard p.utf8.count >= 104 else { return p }
        let h = p.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "/tmp/dbman-\(getuid())-\(String(h, radix: 16)).sock"
    }

    private static func addr(_ path: String) -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &a.sun_path) { _ = $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        return a
    }
    private static func socket() -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 { var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        return fd
    }

    /// A connected fd, or nil if nobody is accepting. Refuses a socket file owned by someone else (the /tmp fallback is world-writable).
    public static func connect(_ path: String) -> Int32? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_uid == getuid() else { return nil }
        let fd = socket()
        guard fd >= 0 else { return nil }
        var a = addr(path)
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        if ok == 0 { return fd }
        close(fd); return nil
    }

    /// Binds and listens, mode 0600. Throws if another process is already listening there; replaces a stale file.
    public static func listen(_ path: String) throws -> Int32 {
        if let live = connect(path) { close(live); throw StoreError(message: "DBMan is already listening on \(path)") }
        unlink(path)
        let fd = socket()
        var a = addr(path)
        let old = umask(0o177); defer { umask(old) }
        let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard fd >= 0, ok == 0, Darwin.listen(fd, 16) == 0 else { let e = String(cString: strerror(errno)); close(fd); throw StoreError(message: "Cannot listen on \(path): \(e)") }
        return fd
    }
}
