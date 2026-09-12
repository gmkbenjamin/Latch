import Foundation
import Security

/// Stores Latch secrets on disk under Application Support.
/// Avoids macOS Keychain ACL prompts and data-protection entitlement failures
/// that break pairing on a non-sandboxed menu-bar app.
enum KeychainStore {
    private static let service = "com.latch.mac"
    private static let legacyService = "com.macunlock.mac"

    enum Key {
        static let loginPassword = "loginPassword"
        static let pairingSecret = "pairingSecret"
        static let pairingPIN = "pairingPIN"
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Latch", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        migrateLegacyDirectoryIfNeeded(to: dir, base: base)
        return dir
    }

    private static func migrateLegacyDirectoryIfNeeded(to dir: URL, base: URL) {
        let legacy = base.appendingPathComponent("MacUnlock", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let keys = [Key.loginPassword, Key.pairingSecret, Key.pairingPIN]
        for key in keys {
            let src = legacy.appendingPathComponent(key + ".secret")
            let dst = dir.appendingPathComponent(key + ".secret")
            guard FileManager.default.fileExists(atPath: src.path),
                  !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
    }

    private static func fileURL(for account: String) -> URL {
        directory.appendingPathComponent(account + ".secret")
    }

    static func set(_ value: Data, account: String) throws {
        let url = fileURL(for: account)
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        // Best-effort: remove any old Keychain copies so they stop prompting.
        purgeKeychainCopies(account: account)
    }

    static func setString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw StoreError.encoding }
        try set(data, account: account)
    }

    static func data(account: String) throws -> Data? {
        let url = fileURL(for: account)
        if FileManager.default.fileExists(atPath: url.path) {
            return try Data(contentsOf: url)
        }
        // One-time migrate from data-protection keychain if an older build left something there.
        if let migrated = readKeychainDataProtection(account: account) {
            try? set(migrated, account: account)
            return migrated
        }
        return nil
    }

    static func string(account: String) throws -> String? {
        guard let data = try data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let url = fileURL(for: account)
        try? FileManager.default.removeItem(at: url)
        purgeKeychainCopies(account: account)
    }

    static func purgeLegacyItems() {
        for account in [Key.loginPassword, Key.pairingSecret, Key.pairingPIN] {
            purgeKeychainCopies(account: account)
        }
    }

    // MARK: - Keychain cleanup / migration helpers

    private static func purgeKeychainCopies(account: String) {
        let services = [service, legacyService]
        var queries: [[String: Any]] = []
        for svc in services {
            queries.append([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true
            ])
            queries.append([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account
            ])
        }
        for query in queries {
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func readKeychainDataProtection(account: String) -> Data? {
        for svc in [service, legacyService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
        }
        return nil
    }

    enum StoreError: Error {
        case encoding
    }
}
