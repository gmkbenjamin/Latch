import Foundation
import CryptoKit

enum SecureSessionError: LocalizedError {
    case notEstablished
    case badHandshake
    case decryptFailed
    case encryptFailed
    case unexpectedWire

    var errorDescription: String? {
        switch self {
        case .notEstablished: return "Encrypted session is not ready."
        case .badHandshake: return "Secure handshake failed."
        case .decryptFailed: return "Could not decrypt message."
        case .encryptFailed: return "Could not encrypt message."
        case .unexpectedWire: return "Unexpected message on the wire."
        }
    }
}

/// Curve25519 ECDH + HKDF + AES-GCM session used by Wi‑Fi and Bluetooth.
final class SecureSession: @unchecked Sendable {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private(set) var symmetricKey: SymmetricKey?
    private(set) var mode: HandshakeMode?

    var isEstablished: Bool { symmetricKey != nil }

    init() {
        privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    var publicKeyData: Data {
        Data(privateKey.publicKey.rawRepresentation)
    }

    // MARK: - Client

    func makeHandshakeInit(mode: HandshakeMode) -> WireMessage {
        self.mode = mode
        var msg = WireMessage(kind: .hsInit, mode: mode)
        msg.clientPub = publicKeyData
        return msg
    }

    func finishHandshakeAsClient(accept: WireMessage, salt: Data) throws {
        guard accept.kind == .hsAccept, let serverPub = accept.serverPub else {
            throw SecureSessionError.badHandshake
        }
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: serverKey)

        if mode == .unlock {
            guard let mac = accept.handshakeMAC,
                  Self.isValidMAC(secret: salt, clientPub: publicKeyData, serverPub: serverPub, mac: mac) else {
                throw SecureSessionError.badHandshake
            }
        }

        symmetricKey = Self.deriveKey(shared: shared, salt: salt)
    }

    // MARK: - Server

    func finishHandshakeAsServer(initMessage: WireMessage, salt: Data) throws -> WireMessage {
        guard initMessage.kind == .hsInit,
              let clientPub = initMessage.clientPub,
              let mode = initMessage.mode else {
            throw SecureSessionError.badHandshake
        }
        self.mode = mode
        let clientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: clientPub)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: clientKey)
        symmetricKey = Self.deriveKey(shared: shared, salt: salt)

        var accept = WireMessage(kind: .hsAccept, mode: mode)
        accept.clientPub = clientPub
        accept.serverPub = publicKeyData
        if mode == .unlock {
            accept.handshakeMAC = Self.makeMAC(secret: salt, clientPub: clientPub, serverPub: publicKeyData)
        }
        return accept
    }

    // MARK: - Seal / Open

    func seal(_ envelope: Envelope) throws -> WireMessage {
        guard let key = symmetricKey else { throw SecureSessionError.notEstablished }
        let plaintext = try ProtocolCodec.encodeEnvelope(envelope)
        let boxed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = boxed.combined else { throw SecureSessionError.encryptFailed }
        // combined = nonce (12) + ciphertext + tag (16)
        var msg = WireMessage(kind: .sealed)
        msg.nonce = Data(combined.prefix(12))
        msg.ciphertext = Data(combined.dropFirst(12))
        return msg
    }

    func open(_ wire: WireMessage) throws -> Envelope {
        guard let key = symmetricKey else { throw SecureSessionError.notEstablished }
        guard wire.kind == .sealed,
              let nonceData = wire.nonce,
              let body = wire.ciphertext,
              body.count >= 16 else {
            throw SecureSessionError.decryptFailed
        }
        var combined = Data()
        combined.append(nonceData)
        combined.append(body)
        let box = try AES.GCM.SealedBox(combined: combined)
        let plaintext = try AES.GCM.open(box, using: key)
        return try ProtocolCodec.decodeEnvelope(from: plaintext)
    }

    // MARK: - Key derivation

    private static func deriveKey(shared: SharedSecret, salt: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: UnlockService.hkdfInfo,
            outputByteCount: 32
        )
    }

    private static func makeMAC(secret: Data, clientPub: Data, serverPub: Data) -> Data {
        let key = SymmetricKey(data: secret)
        var material = Data()
        material.append(clientPub)
        material.append(serverPub)
        return Data(HMAC<SHA256>.authenticationCode(for: material, using: key))
    }

    private static func isValidMAC(secret: Data, clientPub: Data, serverPub: Data, mac: Data) -> Bool {
        let expected = makeMAC(secret: secret, clientPub: clientPub, serverPub: serverPub)
        guard expected.count == mac.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<expected.count {
            diff |= expected[i] ^ mac[i]
        }
        return diff == 0
    }
}
