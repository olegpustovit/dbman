@testable import DBCore
import Foundation
import XCTest

final class SSHTunnelTests: XCTestCase {
    override func tearDown() { SSHTunnelProcess.executable = "/usr/bin/ssh"; SSHTunnelProcess.readyTimeout = 20 }

    func testParsing() throws {
        let t = try XCTUnwrap(SSHTunnel(parsing: " ubuntu@cx2-satdb.tail022925.ts.net:2222 "))
        XCTAssertEqual([t.user, t.host], ["ubuntu", "cx2-satdb.tail022925.ts.net"]); XCTAssertEqual(t.port, 2222)
        XCTAssertEqual(t.display, "ubuntu@cx2-satdb.tail022925.ts.net:2222")
        let alias = try XCTUnwrap(SSHTunnel(parsing: "ssh://satdb"))
        XCTAssertEqual(alias.host, "satdb"); XCTAssertNil(alias.user); XCTAssertNil(alias.port); XCTAssertEqual(alias.display, "satdb")
        for bad in ["", "a b", "h:99999", "h:x", "@h", "u@", "h/x"] { XCTAssertNil(SSHTunnel(parsing: bad), bad) }
    }

    func testArguments() {
        let a = SSHTunnelProcess.arguments(SSHTunnel(host: "bastion", user: "ubuntu", port: 2222, identityFile: "~/.ssh/id_x"), localPort: 15000, targetHost: "127.0.0.1", targetPort: 5455)
        XCTAssertEqual(Array(a.suffix(2)), ["--", "bastion"])
        for pair in [["-L", "127.0.0.1:15000:127.0.0.1:5455"], ["-p", "2222"], ["-l", "ubuntu"], ["-o", "BatchMode=yes"], ["-o", "ExitOnForwardFailure=yes"], ["-i", NSHomeDirectory() + "/.ssh/id_x"]] {
            XCTAssertTrue(zip(a, a.dropFirst()).contains { [$0, $1] == pair }, "\(pair)")
        }
        let v6 = SSHTunnelProcess.arguments(SSHTunnel(host: "b"), localPort: 1, targetHost: "::1", targetPort: 5432)
        XCTAssertTrue(v6.contains("127.0.0.1:1:[::1]:5432")); XCTAssertFalse(v6.contains("-p")); XCTAssertFalse(v6.contains("-l"))
    }

    func testURLRoundTrip() throws {
        let p = try XCTUnwrap(ConnectionURL.parse("postgres://phenix@127.0.0.1:5455/satellite_launches?ssh=ubuntu@cx2-satdb:22&sshkey=~/.ssh/k"))
        XCTAssertEqual(p.ssh, SSHTunnel(host: "cx2-satdb", user: "ubuntu", port: 22, identityFile: NSHomeDirectory() + "/.ssh/k"))
        XCTAssertEqual([p.host, p.database], ["127.0.0.1", "satellite_launches"]); XCTAssertEqual(p.port, 5455)
        XCTAssertEqual(ConnectionURL.parse(ConnectionURL.format(p))?.ssh, p.ssh)
        XCTAssertNil(ConnectionURL.parse("postgres://u@h/d")?.ssh)
        XCTAssertNil(ConnectionURL.parse("postgres://u@h/d?ssh=bad%20host"))
    }

    /// A stand-in ssh: listens on the -L port like the real forward does.
    private func fakeSSH(_ body: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbman-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("ssh")
        try ("#!/bin/sh\n" + body).write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f.path
    }

    func testOpenWaitsForTheForwardAndCloses() async throws {
        SSHTunnelProcess.executable = try fakeSSH("""
            while [ "$1" != "-L" ]; do shift; done
            port=$(echo "$2" | cut -d: -f2)
            exec /usr/bin/python3 -c "import socket,time;s=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);time.sleep(0.3);s.bind(('127.0.0.1',$port));s.listen(8);time.sleep(60)"
            """)
        let t = try await SSHTunnelProcess.open(SSHTunnel(host: "bastion"), targetHost: "127.0.0.1", targetPort: 5432)
        XCTAssertTrue(t.isAlive); XCTAssertTrue(SSHTunnelProcess.canConnect(t.localPort))
        t.close()
        XCTAssertFalse(t.isAlive)
    }

    func testFailureCarriesSSHsReason() async throws {
        SSHTunnelProcess.executable = try fakeSSH("echo 'Warning: Permanently added x' >&2; echo 'ubuntu@bastion: Permission denied (publickey).' >&2; exit 255")
        do { _ = try await SSHTunnelProcess.open(SSHTunnel(host: "bastion", user: "ubuntu"), targetHost: "127.0.0.1", targetPort: 5432); XCTFail("opened") }
        catch DBError.connection(let m) { XCTAssertTrue(m.hasSuffix("Permission denied (publickey)."), m); XCTAssertTrue(m.contains("ubuntu@bastion"), m) }
    }

    func testTimeout() async throws {
        SSHTunnelProcess.executable = try fakeSSH("sleep 30")
        SSHTunnelProcess.readyTimeout = 0.5
        do { _ = try await SSHTunnelProcess.open(SSHTunnel(host: "bastion"), targetHost: "h", targetPort: 1); XCTFail("opened") }
        catch DBError.connection(let m) { XCTAssertTrue(m.contains("timed out"), m) }
    }

    func testSessionRefusesSQLiteOverSSH() async throws {
        var p = ConnectionProfile(name: "x", engine: .sqlite, filePath: "/tmp/x.sqlite"); p.ssh = SSHTunnel(host: "b")
        do { _ = try await DatabaseSession.connect(p, password: nil); XCTFail("opened") } catch DBError.unsupported {}
    }

    /// Real tunnel, read-only: DBMAN_SSH_PG_URL=postgres://user:pw@127.0.0.1:5455/db?ssh=user@host
    func testRealTunnel() async throws {
        guard let url = ProcessInfo.processInfo.environment["DBMAN_SSH_PG_URL"] else { throw XCTSkip("DBMAN_SSH_PG_URL not set") }
        let (p, pw) = try XCTUnwrap(ConnectionURL.parseWithPassword(url))
        XCTAssertNotNil(p.ssh)
        let s = try await DatabaseSession.connect(p, password: pw)
        XCTAssertTrue(s.isHealthy)
        let r = try await s.readOnlyRun("SELECT 1")
        XCTAssertEqual(r.rows[0][0], .integer(1))
        await s.close()
        XCTAssertFalse(s.tunnel?.isAlive ?? true)
    }
}
