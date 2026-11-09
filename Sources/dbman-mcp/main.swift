import DBStore
import Darwin
import Foundation

// stdio <-> DBMan's Unix socket. Holds no credentials and parses nothing but a request id on failure (SPEC §1.1).
// If DBMan isn't listening it launches it in the background, retries ~5 s, then answers every request with APP_LOCKED.

setvbuf(stdout, nil, _IONBF, 0)
signal(SIGPIPE, SIG_IGN)

let env = ProcessInfo.processInfo.environment
#if DEBUG
let customStore = env["DBMAN_STORE"] // same DEBUG-only override as the app's Store.defaultURL
#else
let customStore: String? = nil
#endif
let storeDir = customStore.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DBMan").path
let socketPath = UnixSocket.path(storeDir: storeDir)

/// `…/DBMan.app/Contents/Helpers/dbman-mcp` → that app; otherwise DBMAN_APP (dev checkout) or the registered bundle id.
func launchApp() {
    let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var args = ["-g", "-j"]
    if let store = customStore { args += ["--env", "DBMAN_STORE=\(store)"] }
    if let app = env["DBMAN_APP"] ?? (bundle.pathExtension == "app" ? bundle.path : nil) { args.append(app) } else { args += ["-b", "com.dbman.app"] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = args
    try? p.run()
}

func connect() -> Int32? {
    if let fd = UnixSocket.connect(socketPath) { return fd }
    launchApp()
    for _ in 0..<50 { // ~5 s
        usleep(100_000)
        if let fd = UnixSocket.connect(socketPath) { return fd }
    }
    return nil
}

/// Both ends of the pipe: copy until either side closes.
func pump(_ from: Int32, _ to: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(from, &buf, buf.count)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return }
        var off = 0
        while off < n {
            let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
            if w < 0 && errno == EINTR { continue }
            if w <= 0 { return }
            off += w
        }
    }
}

if let fd = connect() {
    let done = DispatchSemaphore(value: 0)
    for (a, b) in [(STDIN_FILENO, fd), (fd, STDOUT_FILENO)] {
        Thread.detachNewThread { pump(a, b); done.signal() }
    }
    done.wait() // stdin EOF (agent exited) or socket closed (DBMan quit)
    exit(0)
}

// DBMan is unreachable: stay alive so the client gets a typed error instead of a dead pipe.
FileHandle.standardError.write(Data("dbman-mcp: DBMan is not running and could not be started (socket \(socketPath))\n".utf8))
while let line = readLine() {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = obj["id"] else { continue } // notifications get no reply
    let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": "APP_LOCKED (DBMan is not running and could not be started; open DBMan once and retry)"]]
    if let d = try? JSONSerialization.data(withJSONObject: reply) { print(String(decoding: d, as: UTF8.self)) }
}
