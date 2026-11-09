import DBStore
import Foundation
import MCP
import System

/// Accepts agent shims on the Unix socket; one `Server` per connection, over the socket as a newline-delimited JSON-RPC stream.
public final class MCPListener: @unchecked Sendable {
    private let service: MCPService
    private var fd: Int32 = -1
    private let path: String

    public init(service: MCPService, path: String) { self.service = service; self.path = path }

    public func start() throws {
        fd = try UnixSocket.listen(path)
        let lfd = fd
        Thread.detachNewThread { [service] in
            while true {
                let c = accept(lfd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return } // closed by stop()
                var uid = uid_t(), gid = gid_t()
                guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
                Task { await Self.serve(c, service) }
            }
        }
    }

    public func stop() { close(fd); unlink(path) }

    private static func serve(_ c: Int32, _ service: MCPService) async {
        // shortcut: the SDK's stdio transport polls non-blocking fds every 10 ms when idle; upgrade to a DispatchSource transport if that shows up in energy use
        let t = StdioTransport(input: FileDescriptor(rawValue: c), output: FileDescriptor(rawValue: c))
        if let server = try? await service.start(transport: t) {
            await server.waitUntilCompleted()
            await server.stop()
        }
        close(c)
    }
}
