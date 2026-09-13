import Foundation
import Security
import CryptoKit

enum LoginPasswordStorage: String, CaseIterable, Identifiable {
    case keychain
    case disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keychain: return "Keychain"
        case .disk: return "On disk"
        }
    }

    var detail: String {
        switch self {
        case .keychain:
            return "Stored in the macOS Keychain. Readable after the first unlock since boot."
        case .disk:
            return "Encrypted file in ~/Library/Application Support/Latch/. The wrapping key stays in Keychain."
        }
    }

    var savedLabel: String {
        switch self {
        case .keychain: return "Password stored in Keychain"
        case .disk: return "Password stored on disk"
        }
    }
}

/// Pairing secrets stay in Application Support. The Mac login password goes to
/// Keychain or a local file, depending on `LoginPasswordStorage`.
enum KeychainStore {
    private static let service = "com.latch.mac"
    private static let legacyService = "com.macunlock.mac"

    enum Key {
        static let loginPassword = "loginPassword"
        static let pairingSecret = "pairingSecret"
        static let pairingPIN = "pairingPIN"
    }

    static var loginPasswordStorage: LoginPasswordStorage {
        get {
            if let raw = UserDefaults.standard.string(forKey: TransportPreference.loginPasswordStorageKey),
               let value = LoginPasswordStorage(rawValue: raw) {
                return value
            }
            let inferred: LoginPasswordStorage =
                (FileSecret.load(account: Key.loginPassword) != nil && LoginPasswordKeychain.load() == nil)
                ? .disk
                : .keychain
            UserDefaults.standard.set(inferred.rawValue, forKey: TransportPreference.loginPasswordStorageKey)
            return inferred
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: TransportPreference.loginPasswordStorageKey)
        }
    }

    static func set(_ value: Data, account: String) throws {
        if account == Key.loginPassword {
            try storeLoginPassword(value)
            return
        }
        try FileSecret.store(value, account: account)
        purgeKeychainCopies(account: account)
    }

    static func setString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else { throw StoreError.encoding }
        try set(data, account: account)
    }

    static func data(account: String) throws -> Data? {
        if account == Key.loginPassword {
            return loadLoginPassword()
        }
        return FileSecret.load(account: account)
    }

    static func string(account: String) throws -> String? {
        guard let data = try data(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        if account == Key.loginPassword {
            LoginPasswordKeychain.delete()
        }
        FileSecret.delete(account: account)
        if account != Key.loginPassword {
            purgeKeychainCopies(account: account)
        }
    }

    /// Move the saved login password between Keychain and disk. No-op if none is saved yet.
    static func setLoginPasswordStorage(_ storage: LoginPasswordStorage) throws {
        let previous = loginPasswordStorage
        let existing = LoginPasswordKeychain.load() ?? FileSecret.loadLoginPassword()
        loginPasswordStorage = storage
        guard let existing, !existing.isEmpty else { return }
        do {
            try storeLoginPassword(existing)
        } catch {
            loginPasswordStorage = previous
            throw error
        }
    }

    /// Removes leftover pairing items from Keychain (those used to trigger ACL dialogs).
    /// Does not move the login password unless a destination is already chosen.
    static func purgeLegacyItems() {
        for account in [Key.pairingSecret, Key.pairingPIN] {
            purgeKeychainCopies(account: account)
        }
        reconcileLoginPasswordStorage()
    }

    static func migrateLoginPasswordIfNeeded() {
        reconcileLoginPasswordStorage()
    }

    private static func storeLoginPassword(_ value: Data) throws {
        switch loginPasswordStorage {
        case .keychain:
            try LoginPasswordKeychain.store(value)
            FileSecret.deleteLoginPasswordCopies()
        case .disk:
            try FileSecret.storeLoginPassword(value)
            LoginPasswordKeychain.delete()
        }
    }

    private static func loadLoginPassword() -> Data? {
        switch loginPasswordStorage {
        case .keychain:
            return LoginPasswordKeychain.load() ?? FileSecret.loadLoginPassword()
        case .disk:
            return FileSecret.loadLoginPassword() ?? LoginPasswordKeychain.load()
        }
    }

    private static func reconcileLoginPasswordStorage() {
        FileSecret.importLegacyLoginPasswordIfNeeded()
        let preferred = loginPasswordStorage
        let keychain = LoginPasswordKeychain.load()
        let file = FileSecret.loadLoginPassword()
        switch preferred {
        case .keychain:
            if keychain == nil, let file, !file.isEmpty {
                try? LoginPasswordKeychain.store(file)
            }
            if LoginPasswordKeychain.load() != nil {
                FileSecret.deleteLoginPasswordCopies()
            }
        case .disk:
            if file == nil, let keychain, !keychain.isEmpty {
                try? FileSecret.storeLoginPassword(keychain)
            }
            if FileSecret.loadLoginPassword() != nil {
                LoginPasswordKeychain.delete()
            }
        }
    }

    // MARK: - Keychain cleanup

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

    enum StoreError: LocalizedError {
        case encoding
        case status(OSStatus)
        case encryptFailed
        case decryptFailed

        var errorDescription: String? {
            switch self {
            case .encoding:
                return "Could not encode the password."
            case .status(let status):
                if let message = SecCopyErrorMessageString(status, nil) as String?, !message.isEmpty {
                    return message
                }
                return "Keychain error \(status)"
            case .encryptFailed:
                return "Could not encrypt the on-disk password."
            case .decryptFailed:
                return "Could not decrypt the on-disk password."
            }
        }
    }
}

// MARK: - Generic Keychain blobs (password + wrapping key)

private enum GenericKeychain {
    static let service = "com.latch.mac"
    static let legacyService = "com.macunlock.mac"

    static func store(_ value: Data, account: String, label: String, comment: String) throws {
        do {
            try addOrUpdate(value, account: account, label: label, comment: comment, dataProtection: true)
            delete(account: account, service: service, dataProtection: false)
        } catch {
            try addOrUpdate(value, account: account, label: label, comment: comment, dataProtection: false)
            delete(account: account, service: service, dataProtection: true)
        }
        delete(account: account, service: legacyService, dataProtection: true)
        delete(account: account, service: legacyService, dataProtection: false)
    }

    static func load(account: String) -> Data? {
        if let data = copy(account: account, service: service, dataProtection: true) { return data }
        if let data = copy(account: account, service: service, dataProtection: false) { return data }
        return nil
    }

    static func delete(account: String) {
        delete(account: account, service: service, dataProtection: true)
        delete(account: account, service: service, dataProtection: false)
        delete(account: account, service: legacyService, dataProtection: true)
        delete(account: account, service: legacyService, dataProtection: false)
    }

    private static func addOrUpdate(
        _ value: Data,
        account: String,
        label: String,
        comment: String,
        dataProtection: Bool
    ) throws {
        let query = baseQuery(account: account, service: service, dataProtection: dataProtection)
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label
        add[kSecAttrComment as String] = comment

        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return }
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: value]
            let updated = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw KeychainStore.StoreError.status(updated) }
            return
        }
        throw KeychainStore.StoreError.status(status)
    }

    private static func copy(account: String, service: String, dataProtection: Bool) -> Data? {
        var query = baseQuery(account: account, service: service, dataProtection: dataProtection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func delete(account: String, service: String, dataProtection: Bool) {
        SecItemDelete(baseQuery(account: account, service: service, dataProtection: dataProtection) as CFDictionary)
    }

    private static func baseQuery(account: String, service: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }
}

// MARK: - Mac login password (Keychain)

/// Data-protection Keychain first (no ACL prompts). `AfterFirstUnlockThisDeviceOnly`
/// stays readable after ⌃⌘Q so Latch can type the password on the lock screen.
private enum LoginPasswordKeychain {
    private static let account = KeychainStore.Key.loginPassword

    static func store(_ value: Data) throws {
        try GenericKeychain.store(
            value,
            account: account,
            label: "Latch Mac login password",
            comment: "Typed into the lock screen when you unlock from iPhone."
        )
        FileSecret.deleteLoginPasswordCopies()
    }

    static func load() -> Data? {
        GenericKeychain.load(account: account)
    }

    static func delete() {
        GenericKeychain.delete(account: account)
    }
}

// MARK: - AES-GCM for the on-disk password file

private enum DiskPasswordCrypto {
    static let magic = Data("LTC1".utf8)
    private static let wrapAccount = "loginPasswordWrapKey"

    static func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: wrapKey())
        guard let combined = sealed.combined else { throw KeychainStore.StoreError.encryptFailed }
        return magic + combined
    }

    static func decrypt(_ file: Data) throws -> Data {
        guard isEncrypted(file) else { return file }
        let combined = Data(file.dropFirst(magic.count))
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: wrapKey())
        } catch {
            throw KeychainStore.StoreError.decryptFailed
        }
    }

    static func isEncrypted(_ file: Data) -> Bool {
        file.starts(with: magic)
    }

    private static func wrapKey() throws -> SymmetricKey {
        if let data = GenericKeychain.load(account: wrapAccount), data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainStore.StoreError.encryptFailed }
        let data = Data(bytes)
        try GenericKeychain.store(
            data,
            account: wrapAccount,
            label: "Latch disk password wrapping key",
            comment: "AES-GCM key for the on-disk login password file."
        )
        return SymmetricKey(data: data)
    }
}

// MARK: - Pairing secrets (Application Support files)

private enum FileSecret {
    private static var supportBase: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    private static var directory: URL {
        let base = supportBase
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
        // Pairing only — loginPassword is handled separately so a leftover
        // MacUnlock copy cannot recreate the file after a Keychain migration.
        for key in [KeychainStore.Key.pairingSecret, KeychainStore.Key.pairingPIN] {
            let src = legacy.appendingPathComponent(key + ".secret")
            let dst = dir.appendingPathComponent(key + ".secret")
            guard FileManager.default.fileExists(atPath: src.path),
                  !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dst)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        importLegacyLoginPasswordIfNeeded()
    }

    /// Copy MacUnlock/loginPassword.secret into Latch if needed, then delete the legacy file
    /// so it cannot be copied back after a Keychain migration.
    static func importLegacyLoginPasswordIfNeeded() {
        let src = supportBase.appendingPathComponent("MacUnlock/loginPassword.secret")
        let dst = supportBase.appendingPathComponent("Latch/loginPassword.secret")
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if !fm.fileExists(atPath: dst.path) {
            try? fm.copyItem(at: src, to: dst)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
        }
        try? fm.removeItem(at: src)
    }

    private static func fileURL(for account: String) -> URL {
        directory.appendingPathComponent(account + ".secret")
    }

    static func store(_ value: Data, account: String) throws {
        if account == KeychainStore.Key.loginPassword {
            try storeLoginPassword(value)
            return
        }
        let url = fileURL(for: account)
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func storeLoginPassword(_ plaintext: Data) throws {
        let url = fileURL(for: KeychainStore.Key.loginPassword)
        let sealed = try DiskPasswordCrypto.encrypt(plaintext)
        try sealed.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let legacy = supportBase.appendingPathComponent("MacUnlock/loginPassword.secret")
        try? FileManager.default.removeItem(at: legacy)
    }

    static func load(account: String) -> Data? {
        if account == KeychainStore.Key.loginPassword {
            return loadLoginPassword()
        }
        let url = fileURL(for: account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func loadLoginPassword() -> Data? {
        let url = fileURL(for: KeychainStore.Key.loginPassword)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            let plaintext = try DiskPasswordCrypto.decrypt(data)
            if !DiskPasswordCrypto.isEncrypted(data) {
                try? storeLoginPassword(plaintext)
            }
            return plaintext
        } catch {
            return nil
        }
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: fileURL(for: account))
        if account == KeychainStore.Key.loginPassword {
            deleteLoginPasswordCopies()
        }
    }

    static func deleteLoginPasswordCopies() {
        let fm = FileManager.default
        let latch = supportBase.appendingPathComponent("Latch/loginPassword.secret")
        let legacy = supportBase.appendingPathComponent("MacUnlock/loginPassword.secret")
        try? fm.removeItem(at: latch)
        try? fm.removeItem(at: legacy)
    }
}
