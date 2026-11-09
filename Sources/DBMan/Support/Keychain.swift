import DBCore
import Foundation
import Security

/// Connection passwords. Release: login Keychain. DEBUG: a 0600 file, because every ad-hoc-signed
/// dev rebuild is a "new app" to the Keychain and would trigger an access prompt on each launch.
enum Keychain {
    #if DEBUG
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DBMan/dev-secrets.json")
    private static func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }
    private static func store(_ m: [String: String]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? JSONEncoder().encode(m).write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func password(for p: ConnectionProfile) -> String? { load()[p.id.uuidString] }
    static func save(_ password: String, for p: ConnectionProfile) { var m = load(); m[p.id.uuidString] = password; store(m) }
    static func delete(for p: ConnectionProfile) { var m = load(); m[p.id.uuidString] = nil; store(m) }
    #else
    private static func query(_ p: ConnectionProfile) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.dbman.connections",
         kSecAttrAccount as String: p.id.uuidString]
    }

    static func password(for p: ConnectionProfile) -> String? {
        var q = query(p)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String, for p: ConnectionProfile) {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(p) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(p)
            q[kSecValueData as String] = data
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    static func delete(for p: ConnectionProfile) { SecItemDelete(query(p) as CFDictionary) }
    #endif
}
