import Foundation
import Security

struct PairedMac: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var secret: Data
    var pairedAt: Date
    /// Hostname or IP for Tailscale / VPN / LAN when Bonjour is unavailable.
    var remoteHost: String?
    var remotePort: UInt16?

    var shortID: String {
        DeviceIdentity.shortID(from: id, name: nil) ?? id
    }

    var resolvedRemotePort: UInt16 {
        remotePort ?? UnlockService.tcpPort
    }
}

enum PairedMacStore {
    private static let service = "com.latch.ios"
    private static let legacyService = "com.macunlock.ios"
    private static let account = "pairedMacs.v2"
    // Legacy single-Mac keys (migrated on first load).
    private static let legacySecret = "pairingSecret"
    private static let legacyName = "macName"

    static func loadAll() -> [PairedMac] {
        if let data = keychainData(account: account),
           let list = try? JSONDecoder().decode([PairedMac].self, from: data) {
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        return migrateLegacyIfNeeded()
    }

    static func saveAll(_ macs: [PairedMac]) throws {
        let data = try JSONEncoder().encode(macs)
        try setKeychainData(data, account: account)
        // Clear legacy keys after successful multi-device save.
        deleteKeychain(account: legacySecret)
        deleteKeychain(account: legacyName)
    }

    @discardableResult
    static func upsert(
        id: String,
        name: String,
        secret: Data,
        remoteHost: String? = nil,
        remotePort: UInt16? = nil
    ) throws -> PairedMac {
        var list = loadAll()
        var mac = PairedMac(
            id: id,
            name: name,
            secret: secret,
            pairedAt: Date(),
            remoteHost: remoteHost,
            remotePort: remotePort
        )
        if let idx = list.firstIndex(where: { matches($0, id: id) }) {
            let existing = list[idx]
            if mac.remoteHost == nil { mac.remoteHost = existing.remoteHost }
            if mac.remotePort == nil { mac.remotePort = existing.remotePort }
            list[idx] = mac
        } else {
            list.append(mac)
        }
        try saveAll(list)
        return mac
    }

    static func setRemote(id: String, host: String?, port: UInt16?) throws {
        var list = loadAll()
        guard let idx = list.firstIndex(where: { matches($0, id: id) }) else {
            throw StoreError.status(errSecItemNotFound)
        }
        let trimmed = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        list[idx].remoteHost = (trimmed?.isEmpty == false) ? trimmed : nil
        list[idx].remotePort = port
        try saveAll(list)
    }

    static func remove(id: String) throws {
        var list = loadAll()
        list.removeAll { matches($0, id: id) }
        try saveAll(list)
    }

    static func removeAll() {
        deleteKeychain(account: account)
        deleteKeychain(account: legacySecret)
        deleteKeychain(account: legacyName)
    }

    static func find(matching discovered: DiscoveredMac) -> PairedMac? {
        let list = loadAll()
        let short = DeviceIdentity.shortID(from: discovered.deviceIdentity, name: discovered.name)
        return list.first { mac in
            if let short, mac.shortID == short { return true }
            if let identity = discovered.deviceIdentity,
               mac.id.caseInsensitiveCompare(identity) == .orderedSame { return true }
            return mac.name.caseInsensitiveCompare(discovered.name) == .orderedSame
        }
    }

    static func find(id: String) -> PairedMac? {
        loadAll().first { matches($0, id: id) }
    }

    private static func matches(_ mac: PairedMac, id: String) -> Bool {
        if mac.id.caseInsensitiveCompare(id) == .orderedSame { return true }
        let a = DeviceIdentity.shortID(from: mac.id, name: nil)
        let b = DeviceIdentity.shortID(from: id, name: nil)
        return a != nil && a == b
    }

    private static func migrateLegacyIfNeeded() -> [PairedMac] {
        guard let secret = keychainData(account: legacySecret) else { return [] }
        let name = keychainString(account: legacyName) ?? "Mac"
        let mac = PairedMac(id: "legacy-\(name)", name: name, secret: secret, pairedAt: Date())
        try? saveAll([mac])
        return [mac]
    }

    // MARK: - Keychain primitives

    private static func setKeychainData(_ value: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.status(status) }
    }

    private static func keychainData(account: String) -> Data? {
        if let data = keychainData(account: account, service: service) {
            return data
        }
        if let legacy = keychainData(account: account, service: legacyService) {
            try? setKeychainData(legacy, account: account)
            deleteKeychain(account: account, service: legacyService)
            return legacy
        }
        return nil
    }

    private static func keychainData(account: String, service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func keychainString(account: String) -> String? {
        guard let data = keychainData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteKeychain(account: String) {
        deleteKeychain(account: account, service: service)
        deleteKeychain(account: account, service: legacyService)
    }

    private static func deleteKeychain(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum StoreError: Error {
        case status(OSStatus)
    }
}
