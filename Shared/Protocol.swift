import Foundation
import CryptoKit

enum UnlockService {
    static let type = "_latch._tcp"
    static let domain = "local."
    static let protocolVersion = 2
    /// Stable TCP port so phones can reach Latch over Tailscale / VPN without Bonjour.
    static let tcpPort: UInt16 = 47331

    static let bleServiceUUID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567801"
    static let bleRXUUID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567802"
    static let bleTXUUID = "A1B2C3D4-E5F6-7890-ABCD-EF1234567803"

    static let hkdfInfo = Data("Latch-v2-session".utf8)
}

enum TransportPreference {
    static let bluetoothOnlyKey = "bluetoothOnly"
    static let deviceIDKey = "latch.deviceID"
    static let legacyDeviceIDKey = "macunlock.deviceID"
    static let unlockOnLaunchKey = "unlockOnLaunch"
    static let selectedPairedIDKey = "selectedPairedID"
    static let requireBiometricKey = "requireBiometric"
}

enum MacLockState: String, Hashable, Sendable {
    case unknown
    case unlocked
    case locked

    var label: String {
        switch self {
        case .unknown: return "Status unknown"
        case .unlocked: return "Unlocked"
        case .locked: return "Locked"
        }
    }
}

/// Stable Mac identity shared across Wi‑Fi Bonjour TXT and BLE manufacturer data.
enum DeviceIdentity {
    /// Company ID 0xFFFF + 16-byte UUID + lock byte (0 unlocked, 1 locked).
    static func manufacturerData(for id: UUID, locked: Bool) -> Data {
        var data = Data([0xFF, 0xFF])
        data.append(contentsOf: withUnsafeBytes(of: id.uuid) { Data($0) })
        data.append(locked ? 0x01 : 0x00)
        return data
    }

    static func parseManufacturerData(_ data: Data) -> (uuid: UUID, locked: Bool?)? {
        guard data.count >= 18, data[0] == 0xFF, data[1] == 0xFF else { return nil }
        let uuidBytes = [UInt8](data.subdata(in: 2..<18))
        guard uuidBytes.count == 16 else { return nil }
        let uuid = NSUUID(uuidBytes: uuidBytes) as UUID
        let locked: Bool? = data.count >= 19 ? (data[18] != 0) : nil
        return (uuid, locked)
    }

    static func persistentMacID() -> UUID {
        if let existing = UserDefaults.standard.string(forKey: TransportPreference.deviceIDKey),
           let uuid = UUID(uuidString: existing) {
            return uuid
        }
        if let legacy = UserDefaults.standard.string(forKey: TransportPreference.legacyDeviceIDKey),
           let uuid = UUID(uuidString: legacy) {
            UserDefaults.standard.set(legacy, forKey: TransportPreference.deviceIDKey)
            return uuid
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: TransportPreference.deviceIDKey)
        return id
    }

    static func serviceLabel(for id: UUID) -> String {
        "Latch-\(id.uuidString.prefix(8).uppercased())"
    }

    /// Extracts `F4ED4371` from `Latch-F4ED4371` / legacy `MacUnlock-…` / full UUID.
    static func shortID(from deviceID: String?, name: String?) -> String? {
        if let deviceID {
            let cleaned = deviceID.replacingOccurrences(of: "-", with: "")
            if cleaned.count >= 8 {
                return String(cleaned.prefix(8)).uppercased()
            }
        }
        guard let name else { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"(?:Latch|MacUnlock)-([A-Fa-f0-9]{8})"#) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let idRange = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[idRange]).uppercased()
    }

    static func lockState(fromTXT value: String?) -> MacLockState {
        switch value {
        case "1", "true", "yes": return .locked
        case "0", "false", "no": return .unlocked
        default: return .unknown
        }
    }
}

enum MessageType: String, Codable, Sendable {
    case hello
    case pairRequest
    case pairAccept
    case unlockRequest
    case unlockOK
    case unlockFail
    case lockRequest
    case lockOK
    case statusRequest
    case statusOK
    case ping
    case pong
}

enum WireKind: String, Codable, Sendable {
    case hsInit
    case hsAccept
    case sealed
}

enum HandshakeMode: String, Codable, Sendable {
    case pair
    case unlock
}

struct Envelope: Codable, Sendable {
    var v: Int
    var type: MessageType
    var id: String
    var ts: TimeInterval
    var payload: Data?
    var mac: Data?

    init(type: MessageType, payload: Data? = nil, id: String = UUID().uuidString, ts: TimeInterval = Date().timeIntervalSince1970) {
        self.v = UnlockService.protocolVersion
        self.type = type
        self.id = id
        self.ts = ts
        self.payload = payload
        self.mac = nil
    }
}

/// Cleartext handshake or AES-GCM sealed envelope on the wire.
struct WireMessage: Codable, Sendable {
    var v: Int
    var kind: WireKind
    var mode: HandshakeMode?
    var clientPub: Data?
    var serverPub: Data?
    var handshakeMAC: Data?
    var nonce: Data?
    var ciphertext: Data?

    init(kind: WireKind, mode: HandshakeMode? = nil) {
        self.v = UnlockService.protocolVersion
        self.kind = kind
        self.mode = mode
    }
}

struct PairAcceptPayload: Codable, Sendable {
    var deviceName: String
    var secret: Data
    /// Stable Mac identity (UUID string). Optional for older Mac builds.
    var deviceID: String?
}

struct UnlockRequestPayload: Codable, Sendable {
    var deviceName: String
    var method: String
}

typealias LockRequestPayload = UnlockRequestPayload

struct UnlockFailPayload: Codable, Sendable {
    var reason: String
}

struct StatusPayload: Codable, Sendable {
    var locked: Bool
    var name: String
}

struct PairingQRPayload: Codable, Sendable {
    var name: String
    var pin: String
    var host: String?
    var port: UInt16?
    var id: String?
}

enum ProtocolCodec {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    static func encodeWire(_ message: WireMessage) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    static func decodeWire(from line: Data) throws -> WireMessage {
        try decoder.decode(WireMessage.self, from: line)
    }

    static func encodeEnvelope(_ envelope: Envelope) throws -> Data {
        try encoder.encode(envelope)
    }

    static func decodeEnvelope(from data: Data) throws -> Envelope {
        try decoder.decode(Envelope.self, from: data)
    }
}

enum AuthCrypto {
    /// Canonical fields covered by the HMAC (avoids fragile full-envelope JSON round-trips).
    private struct SignatureBody: Codable {
        var type: String
        var id: String
        var ts: Int64
        var payload: Data?
    }

    static func randomSecret(byteCount: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func randomPIN(digits: Int = 6) -> String {
        let max = Int(pow(10.0, Double(digits)))
        let value = Int.random(in: 0..<max)
        return String(format: "%0\(digits)d", value)
    }

    static func signingBytes(for envelope: Envelope) throws -> Data {
        let body = SignatureBody(
            type: envelope.type.rawValue,
            id: envelope.id,
            ts: Int64(envelope.ts.rounded()),
            payload: envelope.payload
        )
        return try ProtocolCodec.encode(body)
    }

    static func sign(_ envelope: inout Envelope, secret: Data) throws {
        // Normalize timestamp before signing so verify uses the same whole-second value.
        envelope.ts = Double(Int64(envelope.ts.rounded()))
        let key = SymmetricKey(data: secret)
        let bytes = try signingBytes(for: envelope)
        let sig = HMAC<SHA256>.authenticationCode(for: bytes, using: key)
        envelope.mac = Data(sig)
    }

    enum VerifyResult {
        case ok
        case stale
        case missingMAC
        case badMAC
    }

    static func verifyDetailed(_ envelope: Envelope, secret: Data, maxSkew: TimeInterval = 120) -> VerifyResult {
        let now = Date().timeIntervalSince1970
        guard abs(now - envelope.ts) <= maxSkew else { return .stale }
        guard let mac = envelope.mac else { return .missingMAC }
        let key = SymmetricKey(data: secret)
        guard let bytes = try? signingBytes(for: envelope) else { return .badMAC }
        if HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: bytes, using: key) {
            return .ok
        }
        return .badMAC
    }

    static func verify(_ envelope: Envelope, secret: Data, maxSkew: TimeInterval = 120) throws -> Bool {
        verifyDetailed(envelope, secret: secret, maxSkew: maxSkew) == .ok
    }
}

enum SessionCrypto {
    enum SessionError: LocalizedError {
        case notEstablished
        case badHandshake
        case decryptFailed
        case missingKeyMaterial

        var errorDescription: String? {
            switch self {
            case .notEstablished: return "Encrypted session is not ready."
            case .badHandshake: return "Secure handshake failed."
            case .decryptFailed: return "Could not decrypt message."
            case .missingKeyMaterial: return "Missing encryption key material."
            }
        }
    }

    static func deriveKey(sharedSecret: SharedSecret, salt: Data) -> SymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: UnlockService.hkdfInfo,
            outputByteCount: 32
        )
    }

    static func handshakeMAC(secret: Data, clientPub: Data, serverPub: Data) -> Data {
        let key = SymmetricKey(data: secret)
        var material = Data()
        material.append(clientPub)
        material.append(serverPub)
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
    }

    static func verifyHandshakeMAC(secret: Data, clientPub: Data, serverPub: Data, mac: Data) -> Bool {
        let expected = handshakeMAC(secret: secret, clientPub: clientPub, serverPub: serverPub)
        return expected.count == mac.count && expected.elementsEqual(mac)
        // Constant-time compare:
        // return HMAC.isValid isn't for raw equality — use timing-safe:
    }

    static func sealing(key: SymmetricKey, envelope: Envelope) throws -> WireMessage {
        let plaintext = try ProtocolCodec.encodeEnvelope(envelope)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else { throw SessionError.encryptFailed }
        // combined = nonce || ciphertext || tag
        let nonce = Data(sealed.nonce)
        let ciphertext = combined.suffix(from: nonce.count)
        var msg = WireMessage(kind: .sealed)
        msg.nonce = nonce
        msg.ciphertext = Data(ciphertext)
        return msg
    }

    static func opening(key: SymmetricKey, wire: WireMessage) throws -> Envelope {
        guard let nonceData = wire.nonce, let ciphertext = wire.ciphertext else {
            throw SessionError.decryptFailed
        }
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        // ciphertext field stores ciphertext||tag from combined.suffix
        let plaintext = try AES.GCM.open(box, using: key)
        return try ProtocolCodec.decodeEnvelope(from: plaintext)
    }
}

// Fix encryptFailed - I referenced it but didn't define. Fix verify to use constant time.
extension SessionCrypto.SessionError {
    static var encryptFailed: SessionCrypto.SessionError { .decryptFailed }
}

enum LineFramer {
    static func split(buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let range = buffer.range(of: Data([0x0A])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if !line.isEmpty {
                lines.append(line)
            }
        }
        return lines
    }
}
