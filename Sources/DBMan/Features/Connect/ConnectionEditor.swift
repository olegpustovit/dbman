import AppKit
import DBCore
import Halftone
import SwiftUI

/// Editor for one profile, or a blank draft when `profile` is nil. Edits stay local until SAVE, TEST or CONNECT.
struct ConnectionEditor: View {
    let profile: ConnectionProfile?
    let onSaved: (UUID) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    @State private var id: UUID
    @State private var engine: Engine
    @State private var urlText: String
    @State private var urlNote: String?
    @State private var urlBad = false
    @State private var host: String
    @State private var port: String
    @State private var database: String
    @State private var user: String
    @State private var password: String
    @State private var filePath: String
    @State private var sslMode: SSLMode
    @State private var sslRootCert: String?
    @State private var sshOn: Bool
    @State private var sshTarget: String
    @State private var sshKey: String?
    @State private var environment: EnvironmentTag
    @State private var openReadOnly: Bool
    @State private var stageWrites: Bool
    @State private var problem: String?
    @State private var reached: String?
    @State private var testing = false

    init(profile: ConnectionProfile?, onSaved: @escaping (UUID) -> Void) {
        let p = profile ?? ConnectionProfile(name: "", engine: .postgres)
        self.profile = profile
        self.onSaved = onSaved
        _id = State(initialValue: p.id)
        _engine = State(initialValue: p.engine)
        _urlText = State(initialValue: profile == nil ? "" : ConnectionURL.format(p))
        _host = State(initialValue: p.host)
        _port = State(initialValue: String(p.port))
        _database = State(initialValue: p.database)
        _user = State(initialValue: p.user)
        _password = State(initialValue: profile.flatMap { Keychain.password(for: $0) } ?? "")
        _filePath = State(initialValue: p.filePath ?? "")
        _sslMode = State(initialValue: p.sslMode)
        _sslRootCert = State(initialValue: p.sslRootCert)
        _sshOn = State(initialValue: p.ssh != nil)
        _sshTarget = State(initialValue: p.ssh?.display ?? "")
        _sshKey = State(initialValue: p.ssh?.identityFile)
        _environment = State(initialValue: p.environment)
        _openReadOnly = State(initialValue: p.openReadOnly)
        _stageWrites = State(initialValue: p.stageWrites)
    }

    private var isSQLite: Bool { engine == .sqlite }
    private var sslOptions: [(value: SSLMode, title: String)] { SSLMode.allCases.map { (value: $0, title: $0.rawValue.uppercased()) } }
    private var envOptions: [(value: EnvironmentTag, title: String)] { EnvironmentTag.allCases.filter { $0 != .system }.map { (value: $0, title: $0.rawValue.uppercased()) } }

    var body: some View {
        HTFrame(title: "CONNECTION", tail: "\(app.profile(id)?.name ?? "NEW") · \(engine.displayName.uppercased())") {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        urlBlock
                        HStack(spacing: 6) {
                            OptionTile(title: "POSTGRES SYSTEMS", subtitle: "PORT 5432 · TLS · PG 12–17", isSelected: engine == .postgres) { pick(.postgres) }
                            OptionTile(title: "MYSQL SYSTEMS", subtitle: "PORT 3306 · MYSQL 8 · MARIADB", isSelected: engine == .mysql) { pick(.mysql) }
                            OptionTile(title: "SQLITE FILES", subtitle: "LOCAL FILE · READ-WRITE", isSelected: engine == .sqlite) { pick(.sqlite) }
                        }
                        fields
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
        }
        .onChange(of: urlText) { _, text in parseURL(text) }
        .task { if let url = DevHooks.connectURL { urlText = url; try? await Task.sleep(for: .milliseconds(300)); test() } }
    }

    private var urlBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsLabel("CONNECTION_URL", urlBad ? "NOT_RECOGNISED" : urlNote)
            TextField("postgres://user@host:5432/database", text: $urlText)
                .ht(.code)
                .htInput(stroke: HT.C.accent, weight: 1.5)
                .accessibilityLabel("Connection URL")
            Text("Also accepts DSNs, psql commands and file paths. Drop a .sqlite file anywhere in this window.")
                .ht(.bodySmall).foregroundStyle(HT.C.ink3)
        }
    }

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            if isSQLite {
                GridRow {
                    CapsLabel("FILE")
                    HStack(spacing: 6) {
                        TextField("/path/to/database.sqlite", text: $filePath)
                            .ht(.code).htInput()
                            .accessibilityLabel("SQLite file path")
                        Button("Choose…") { chooseFile() }.buttonStyle(.htOutline)
                    }
                    .gridCellColumns(3)
                }
            } else {
                GridRow {
                    CapsLabel("HOST")
                    TextField("localhost", text: $host).ht(.bodySmall).htInput().accessibilityLabel("Host")
                    CapsLabel("PORT")
                    TextField("5432", text: $port).ht(.bodySmall).htInput().frame(width: 70).accessibilityLabel("Port")
                }
                GridRow {
                    CapsLabel("DATABASE")
                    TextField("shop", text: $database).ht(.bodySmall).htInput().accessibilityLabel("Database")
                    CapsLabel("USER")
                    TextField("app", text: $user).ht(.bodySmall).htInput().accessibilityLabel("User")
                }
                GridRow {
                    CapsLabel("PASSWORD")
                    SecureField("stored in Keychain", text: $password).ht(.bodySmall).htInput()
                        .accessibilityLabel("Password").gridCellColumns(3)
                }
                GridRow {
                    CapsLabel("SSL")
                    HTSegmented(selection: $sslMode, options: sslOptions).gridCellColumns(3)
                }
                GridRow {
                    CapsLabel("CA", sslRootCert.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "SYSTEM_TRUST")
                    HStack(spacing: 6) {
                        Button("Choose…") { chooseCA() }.buttonStyle(.htOutline)
                        if sslRootCert != nil { Button("Clear") { sslRootCert = nil }.buttonStyle(.htOutline) }
                    }.gridCellColumns(3)
                }
                GridRow {
                    CapsLabel("SSH")
                    HTToggleChip("TUNNEL THROUGH BASTION", isOn: $sshOn).fixedSize().gridCellColumns(3)
                        .accessibilityLabel("Connect over SSH tunnel")
                }
                if sshOn {
                    GridRow {
                        CapsLabel("VIA")
                        TextField("user@bastion:22 or ~/.ssh/config alias", text: $sshTarget).ht(.code).htInput()
                            .accessibilityLabel("SSH host").gridCellColumns(3)
                    }
                    GridRow {
                        CapsLabel("KEY", sshKey.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "SSH_AGENT · CONFIG")
                        HStack(spacing: 6) {
                            Button("Choose…") { chooseKey() }.buttonStyle(.htOutline)
                            if sshKey != nil { Button("Clear") { sshKey = nil }.buttonStyle(.htOutline) }
                        }.gridCellColumns(3)
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text("HOST and PORT above are as seen from the SSH host (e.g. 127.0.0.1 and the container's published port). DBMan runs your system ssh: keys, agent and ~/.ssh/config apply; it never prompts.")
                            .ht(.bodySmall).foregroundStyle(HT.C.ink3).fixedSize(horizontal: false, vertical: true).gridCellColumns(3)
                    }
                }
            }
            GridRow {
                CapsLabel("TAG")
                HTSegmented(selection: $environment, options: envOptions).gridCellColumns(3)
            }
            GridRow {
                CapsLabel("SAFETY")
                HStack(spacing: 6) {
                    HTToggleChip("OPEN READ-ONLY", isOn: $openReadOnly)
                    HTToggleChip("STAGE WRITES UNTIL COMMIT", isOn: $stageWrites)
                }
                .gridCellColumns(3)
            }
            if environment == .production {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    StatusText(label: "PRODUCTION", value: "OPENS READ-ONLY UNTIL UNLOCKED", tone: .amber).gridCellColumns(3)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(HT.C.ink).frame(height: 1)
            HStack(spacing: 8) {
                Button(testing ? "Testing…" : "Test") { test() }
                    .buttonStyle(.htOutline)
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                    .disabled(testing)
                if let reached { StatusText(label: "REACHED", value: reached) }
                if let problem { StatusText(label: "ERROR", value: problem, tone: .alert) }
                Spacer(minLength: 8)
                Button("Save  ⌘S") { save() }
                    .buttonStyle(.htOutline)
                    .keyboardShortcut("s")
                Button("Connect  ⏎") { connect() }
                    .buttonStyle(.htPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    // MARK: actions

    private func pick(_ e: Engine) {
        if port.isEmpty || port == String(engine.defaultPort) { port = String(e.defaultPort) }
        engine = e
        problem = nil
    }

    /// Fills the fields from a pasted URL/DSN. Only values the text carries are overwritten.
    private func parseURL(_ text: String) {
        urlBad = false
        urlNote = nil
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard let parsed = ConnectionURL.parseWithPassword(text) else { urlBad = true; return }
        let p = parsed.0, pw = parsed.1
        if let saved = app.profile(id), saved.engine != p.engine || saved.host != p.host || saved.port != p.port
            || saved.database != p.database || saved.filePath != p.filePath {
            id = UUID() // different target: new draft, named from the URL on save
            urlNote = "NEW_CONNECTION"
        }
        engine = p.engine
        host = p.host
        port = String(p.port)
        database = p.database
        user = p.user
        sslMode = p.sslMode
        sslRootCert = p.sslRootCert
        if let f = p.filePath { filePath = f }
        if let pw { password = pw }
        if let t = p.ssh { sshOn = true; sshTarget = t.display; sshKey = t.identityFile }
        let fields = p.engine == .sqlite
            ? 1
            : 2 + [!p.database.isEmpty, !p.user.isEmpty, pw != nil, text.contains("sslmode")].filter { $0 }.count
        urlNote = (urlNote.map { $0 + " · " } ?? "") + "PARSED_INTO_\(fields)_FIELDS"
    }

    /// Root certificate (PEM) used to verify the server for verify-full; nil = system trust store.
    private func chooseCA() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the CA certificate (PEM) that signed the server certificate"
        if panel.runModal() == .OK, let url = panel.url { sslRootCert = url.path }
    }

    /// Private key for the SSH hop; nil = whatever ssh picks (agent, ~/.ssh/config IdentityFile, defaults).
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = "Choose the SSH private key for the tunnel"
        if panel.runModal() == .OK, let url = panel.url { sshKey = url.path }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SQLite database"
        if panel.runModal() == .OK, let url = panel.url {
            filePath = url.path
            problem = nil
        }
    }

    /// Checks the form and builds the profile. Sets `problem` and returns nil when something is missing.
    private func validated() -> ConnectionProfile? {
        problem = nil
        let h = host.trimmingCharacters(in: .whitespaces)
        let db = database.trimmingCharacters(in: .whitespaces)
        let u = user.trimmingCharacters(in: .whitespaces)
        let file = filePath.trimmingCharacters(in: .whitespaces)
        var portNumber = 0
        if isSQLite {
            guard !file.isEmpty else { problem = "SQLite file is required."; return nil }
            guard FileManager.default.fileExists(atPath: file) else { problem = "No file at \(file)."; return nil }
        } else {
            guard !h.isEmpty else { problem = "Host is required."; return nil }
            guard let n = Int(port.trimmingCharacters(in: .whitespaces)), (1...65535).contains(n) else {
                problem = "Port must be a number from 1 to 65535."; return nil
            }
            guard !db.isEmpty else { problem = "Database is required."; return nil }
            guard !u.isEmpty else { problem = "User is required."; return nil }
            portNumber = n
        }
        var tunnel: SSHTunnel?
        if sshOn, !isSQLite {
            guard let t = SSHTunnel(parsing: sshTarget, identityFile: sshKey), !t.host.hasPrefix("-") else { problem = "SSH must be [user@]host[:port] or a ~/.ssh/config alias."; return nil }
            tunnel = t
        }
        let name = app.profile(id)?.name
            ?? (isSQLite ? URL(fileURLWithPath: file).lastPathComponent : "\(db)@\(h)")
        return ConnectionProfile(
            id: id, name: name, engine: engine, host: isSQLite ? "" : h, port: portNumber,
            database: isSQLite ? "" : db, user: isSQLite ? "" : u, filePath: isSQLite ? file : nil,
            sslMode: sslMode, environment: environment, openReadOnly: openReadOnly,
            stageWrites: stageWrites, lastOpened: app.profile(id)?.lastOpened, sslRootCert: isSQLite ? nil : sslRootCert, ssh: tunnel)
    }

    private func test() {
        guard let p = validated() else { return }
        let pw = password.isEmpty ? nil : password
        testing = true
        reached = nil
        Task {
            defer { testing = false }
            do {
                reached = try await ConnectionTest.run(p, password: pw)
            } catch {
                problem = "Connection failed: \(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    private func save() -> ConnectionProfile? {
        guard let p = validated() else { return nil }
        app.upsert(p)
        if password.isEmpty { Keychain.delete(for: p) } else { Keychain.save(password, for: p) }
        onSaved(p.id)
        return p
    }

    private func connect() {
        guard let p = save() else { return }
        openWindow(value: p.id)
    }
}


/// TEST: connect, read the server version, close. Shared by this editor and the agent credential sheet.
enum ConnectionTest {
    static func run(_ p: ConnectionProfile, password: String?) async throws -> String {
        let t0 = Date()
        let session = try await DatabaseSession.connect(p, password: password)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let version = (try? await session.schema().serverVersion) ?? ""
        await session.close()
        return "IN \(ms) MS · \(version)"
    }
}
