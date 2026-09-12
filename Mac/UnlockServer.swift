import Foundation
import Network
import AppKit

@MainActor
final class UnlockServer: ObservableObject {
    @Published var isRunning = false
    @Published var lastEvent: String = "Waiting to start…"
    @Published var pairedDeviceName: String?
    @Published var pairingPIN: String = ""
    @Published var statusDetail: String = ""
    @Published var bluetoothOnly: Bool {
        didSet {
            UserDefaults.standard.set(bluetoothOnly, forKey: TransportPreference.bluetoothOnlyKey)
            if isRunning { start() }
        }
    }
    @Published var bleStatus: String = ""
    @Published var isScreenLocked: Bool = ScreenUnlocker.isScreenLocked
    @Published var listenPort: UInt16 = UnlockService.tcpPort
    @Published var reachabilityLines: [String] = []

    private var listener: NWListener?
    private var ble: BLEUnlockPeripheral?
    private var browserName: String = Host.current().localizedName ?? "Mac"
    private let deviceID: UUID = DeviceIdentity.persistentMacID()
    private var activePIN: String = ""
    private var connections: [ObjectIdentifier: ConnectionSession] = [:]
    private var advertisedLocked: Bool?

    init() {
        bluetoothOnly = UserDefaults.standard.bool(forKey: TransportPreference.bluetoothOnlyKey)
        // Deletes only — does not read secrets, so no Keychain ACL dialog / UI freeze.
        KeychainStore.purgeLegacyItems()
        Task { @MainActor in
            self.start()
        }
    }

    var pairingQRJSON: String {
        let host = LatchNetwork.preferredRemoteHost()
        let payload = PairingQRPayload(
            name: browserName,
            pin: activePIN,
            host: host,
            port: UnlockService.tcpPort,
            id: deviceID.uuidString
        )
        if let data = try? ProtocolCodec.encode(payload), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"name\":\"\(browserName)\",\"pin\":\"\(activePIN)\",\"id\":\"\(deviceID.uuidString)\",\"port\":\(UnlockService.tcpPort)}"
    }

    func refreshReachability() {
        listenPort = UnlockService.tcpPort
        let addresses = LatchNetwork.ipv4Addresses()
        reachabilityLines = addresses.map { addr in
            "\(addr.ip):\(UnlockService.tcpPort) · \(addr.label)"
        }
    }

    func start() {
        stopTransports()
        rotatePairingPINIfNeeded()
        refreshPairedState()

        startBluetooth()
        if bluetoothOnly {
            isRunning = true
            lastEvent = "Listening on Bluetooth only as “\(browserName)”"
            reachabilityLines = []
        } else {
            startWiFi()
        }
        refreshReachability()
    }

    func stop() {
        stopTransports()
        isRunning = false
        lastEvent = "Stopped"
    }

    private func stopTransports() {
        listener?.cancel()
        listener = nil
        for session in connections.values {
            session.cancel()
        }
        connections.removeAll()
        ble?.stopAdvertising()
        ble?.onEvent = nil
        ble?.saltProvider = nil
        ble = nil
        bleStatus = ""
    }

    private func handshakeSalt(for mode: HandshakeMode) -> Data? {
        switch mode {
        case .pair:
            guard activePIN != "———", activePIN != "Paired", !activePIN.isEmpty else { return nil }
            return Data(activePIN.utf8)
        case .unlock:
            return try? KeychainStore.data(account: KeychainStore.Key.pairingSecret)
        }
    }

    private func startWiFi() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            parameters.allowLocalEndpointReuse = true
            guard let port = NWEndpoint.Port(rawValue: UnlockService.tcpPort) else {
                lastEvent = "Invalid Latch TCP port"
                return
            }
            let listener = try NWListener(using: parameters, on: port)
            isScreenLocked = ScreenUnlocker.isScreenLocked
            listener.service = makeBonjourService()
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.listenPort = UnlockService.tcpPort
                        self.refreshReachability()
                        let vpnHint = LatchNetwork.ipv4Addresses().contains(where: \.isTailscale)
                            ? " · Tailscale ready"
                            : ""
                        self.lastEvent = "Listening on port \(UnlockService.tcpPort) (LAN + VPN)\(vpnHint)"
                        self.advertisedLocked = self.isScreenLocked
                    case .failed(let error):
                        self.lastEvent = "Network failed: \(error.localizedDescription) — Bluetooth still available"
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.accept(connection)
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            lastEvent = "Network could not start: \(error.localizedDescription)"
            isRunning = ble?.isAdvertising == true
        }
    }

    private func makeBonjourService() -> NWListener.Service {
        var txt = NWTXTRecord()
        txt["id"] = deviceID.uuidString
        txt["name"] = browserName
        txt["locked"] = isScreenLocked ? "1" : "0"
        txt["port"] = String(UnlockService.tcpPort)
        if let host = LatchNetwork.preferredRemoteHost() {
            txt["host"] = host
        }
        let serviceName = DeviceIdentity.serviceLabel(for: deviceID)
        return NWListener.Service(name: serviceName, type: UnlockService.type, txtRecord: txt)
    }

    /// Poll from the menu-bar timer; refreshes Bonjour TXT + BLE ads when lock state changes.
    func refreshLockState() {
        let locked = ScreenUnlocker.isScreenLocked
        if locked != isScreenLocked {
            isScreenLocked = locked
        }
        if advertisedLocked != locked {
            advertisedLocked = locked
            if listener != nil {
                listener?.service = makeBonjourService()
            }
        }
        ble?.updateLockState(locked)
    }

    private func startBluetooth() {
        let serviceName = DeviceIdentity.serviceLabel(for: deviceID)
        isScreenLocked = ScreenUnlocker.isScreenLocked
        let peripheral = BLEUnlockPeripheral(
            localName: serviceName,
            deviceID: deviceID,
            displayName: browserName,
            isScreenLocked: isScreenLocked
        )
        peripheral.saltProvider = { [weak self] mode in
            self?.handshakeSalt(for: mode)
        }
        peripheral.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleBLE(event)
            }
        }
        ble = peripheral
        peripheral.startAdvertising()
        bleStatus = peripheral.status
        advertisedLocked = isScreenLocked
    }

    func refreshBLEStatus() {
        bleStatus = ble?.status ?? bleStatus
    }

    func resetPairing() {
        KeychainStore.delete(account: KeychainStore.Key.pairingSecret)
        pairedDeviceName = nil
        rotatePairingPIN(force: true)
        lastEvent = "Pairing cleared. Scan the new QR code from your iPhone."
    }

    func rotatePairingPIN(force: Bool = false) {
        if !force, let existing = try? KeychainStore.string(account: KeychainStore.Key.pairingPIN), !existing.isEmpty,
           (try? KeychainStore.data(account: KeychainStore.Key.pairingSecret)) == nil {
            activePIN = existing
            pairingPIN = existing
            return
        }
        let pin = AuthCrypto.randomPIN()
        activePIN = pin
        pairingPIN = pin
        try? KeychainStore.setString(pin, account: KeychainStore.Key.pairingPIN)
    }

    private func rotatePairingPINIfNeeded() {
        if (try? KeychainStore.data(account: KeychainStore.Key.pairingSecret)) != nil {
            activePIN = "———"
            pairingPIN = "Paired"
            return
        }
        rotatePairingPIN(force: false)
    }

    private func refreshPairedState() {
        if (try? KeychainStore.data(account: KeychainStore.Key.pairingSecret)) != nil {
            pairedDeviceName = "Paired iPhone/iPad"
            statusDetail = "Ready to unlock when your device authenticates."
        } else {
            pairedDeviceName = nil
            statusDetail = "Not paired yet — open Latch on iOS and scan the QR code."
        }
    }

    private func accept(_ connection: NWConnection) {
        let session = ConnectionSession(connection: connection) { [weak self] event in
            Task { @MainActor in
                self?.handleTCP(event)
            }
        }
        session.saltProvider = { [weak self] mode in
            self?.handshakeSalt(for: mode)
        }
        connections[ObjectIdentifier(session)] = session
        session.start()
        lastEvent = "Client connected over Wi‑Fi"
    }

    private func handleTCP(_ event: ConnectionSession.Event) {
        switch event {
        case .closed(let session):
            connections.removeValue(forKey: ObjectIdentifier(session))
        case .message(let session, let envelope):
            Task { @MainActor in
                await process(envelope, on: session)
            }
        case .failed(let message):
            lastEvent = message
        }
    }

    private func handleBLE(_ event: BLEChannel.Event) {
        refreshBLEStatus()
        switch event {
        case .closed:
            break
        case .message(let channel, let envelope):
            Task { @MainActor in
                await process(envelope, on: channel)
            }
        case .failed(let message):
            lastEvent = message
        }
    }

    private func process(_ envelope: Envelope, on channel: UnlockChannel) async {
        switch envelope.type {
        case .hello, .ping:
            channel.send(Envelope(type: .pong))

        case .pairRequest:
            guard let payloadData = envelope.payload,
                  let pin = String(data: payloadData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !pin.isEmpty else {
                channel.sendFail("Missing PIN")
                return
            }
            guard pin == activePIN, activePIN != "———", activePIN != "Paired" else {
                channel.sendFail("Incorrect PIN")
                lastEvent = "Pairing failed — wrong PIN"
                return
            }

            let secret = AuthCrypto.randomSecret()
            do {
                try KeychainStore.set(secret, account: KeychainStore.Key.pairingSecret)
                try KeychainStore.setString(activePIN, account: KeychainStore.Key.pairingPIN)
                } catch {
                    channel.sendFail("Could not store pairing secret: \(error.localizedDescription)")
                    return
                }

            let accept = PairAcceptPayload(deviceName: browserName, secret: secret, deviceID: deviceID.uuidString)
            var response = Envelope(type: .pairAccept, payload: try? ProtocolCodec.encode(accept))
            do {
                try AuthCrypto.sign(&response, secret: secret)
            } catch {
                channel.sendFail("Sign failed")
                return
            }
            channel.send(response)
            channel.secret = secret
            refreshPairedState()
            activePIN = "———"
            pairingPIN = "Paired"
            lastEvent = "Paired successfully"

        case .unlockRequest:
            guard let secret = try? KeychainStore.data(account: KeychainStore.Key.pairingSecret) else {
                channel.sendFail("Not paired")
                return
            }
            switch AuthCrypto.verifyDetailed(envelope, secret: secret) {
            case .ok:
                break
            case .stale:
                channel.sendFail("Auth failed: request expired — check Mac & iPhone clocks")
                lastEvent = "Rejected unlock — stale timestamp"
                return
            case .missingMAC:
                channel.sendFail("Auth failed: missing signature")
                lastEvent = "Rejected unlock — missing MAC"
                return
            case .badMAC:
                channel.sendFail("Auth failed: bad signature — reset pairing on both devices")
                lastEvent = "Rejected unlock — bad signature (re-pair needed)"
                return
            }

            if let payloadData = envelope.payload,
               let req = try? ProtocolCodec.decode(UnlockRequestPayload.self, from: payloadData) {
                lastEvent = "Unlock from \(req.deviceName) via \(req.method)"
            } else {
                lastEvent = "Unlock request received"
            }

            do {
                let outcome = try ScreenUnlocker.unlock()
                var ok = Envelope(type: .unlockOK)
                try AuthCrypto.sign(&ok, secret: secret)
                channel.send(ok)
                switch outcome {
                case .unlocked:
                    lastEvent = "Mac unlocked"
                case .alreadyUnlocked:
                    lastEvent = "Already unlocked — skipped password"
                }
            } catch {
                channel.sendFail(error.localizedDescription)
                lastEvent = "Unlock failed: \(error.localizedDescription)"
            }

        case .lockRequest:
            guard let secret = try? KeychainStore.data(account: KeychainStore.Key.pairingSecret) else {
                channel.sendFail("Not paired")
                return
            }
            switch AuthCrypto.verifyDetailed(envelope, secret: secret) {
            case .ok:
                break
            case .stale:
                channel.sendFail("Auth failed: request expired — check Mac & iPhone clocks")
                lastEvent = "Rejected lock — stale timestamp"
                return
            case .missingMAC:
                channel.sendFail("Auth failed: missing signature")
                lastEvent = "Rejected lock — missing MAC"
                return
            case .badMAC:
                channel.sendFail("Auth failed: bad signature — reset pairing on both devices")
                lastEvent = "Rejected lock — bad signature (re-pair needed)"
                return
            }

            if let payloadData = envelope.payload,
               let req = try? ProtocolCodec.decode(LockRequestPayload.self, from: payloadData) {
                lastEvent = "Lock from \(req.deviceName) via \(req.method)"
            } else {
                lastEvent = "Lock request received"
            }

            do {
                let outcome = try ScreenUnlocker.lock()
                var ok = Envelope(type: .lockOK)
                try AuthCrypto.sign(&ok, secret: secret)
                channel.send(ok)
                switch outcome {
                case .locked:
                    lastEvent = "Mac locked"
                case .alreadyLocked:
                    lastEvent = "Already locked"
                }
                refreshLockState()
            } catch {
                channel.sendFail(error.localizedDescription)
                lastEvent = "Lock failed: \(error.localizedDescription)"
            }

        case .statusRequest:
            guard let secret = try? KeychainStore.data(account: KeychainStore.Key.pairingSecret) else {
                channel.sendFail("Not paired")
                return
            }
            switch AuthCrypto.verifyDetailed(envelope, secret: secret) {
            case .ok:
                break
            case .stale, .missingMAC, .badMAC:
                channel.sendFail("Auth failed")
                return
            }
            refreshLockState()
            let payload = StatusPayload(locked: isScreenLocked, name: browserName)
            do {
                var ok = Envelope(type: .statusOK, payload: try ProtocolCodec.encode(payload))
                try AuthCrypto.sign(&ok, secret: secret)
                channel.send(ok)
            } catch {
                channel.sendFail(error.localizedDescription)
            }

        default:
            break
        }
    }
}

final class ConnectionSession: UnlockChannel, @unchecked Sendable {
    enum Event {
        case message(ConnectionSession, Envelope)
        case closed(ConnectionSession)
        case failed(String)
    }

    let connection: NWConnection
    var secret: Data?
    let secureSession = SecureSession()
    var saltProvider: ((HandshakeMode) -> Data?)?
    private var buffer = Data()
    private let onEvent: (Event) -> Void

    init(connection: NWConnection, onEvent: @escaping (Event) -> Void) {
        self.connection = connection
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed(let error):
                self.onEvent(.failed(error.localizedDescription))
                self.onEvent(.closed(self))
            case .cancelled:
                self.onEvent(.closed(self))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    func cancel() {
        connection.cancel()
    }

    func send(_ envelope: Envelope) {
        var env = envelope
        if let secret, env.type != .hello, env.type != .pong, env.type != .pairAccept {
            try? AuthCrypto.sign(&env, secret: secret)
        }
        guard secureSession.isEstablished,
              let wire = try? secureSession.seal(env),
              let data = try? ProtocolCodec.encodeWire(wire) else {
            return
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func sendWire(_ wire: WireMessage) {
        guard let data = try? ProtocolCodec.encodeWire(wire) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func handleLine(_ line: Data) {
        guard let wire = try? ProtocolCodec.decodeWire(from: line) else {
            onEvent(.failed("Invalid wire message"))
            return
        }
        switch wire.kind {
        case .hsInit:
            guard let mode = wire.mode,
                  let salt = saltProvider?(mode) else {
                onEvent(.failed("Handshake rejected"))
                cancel()
                return
            }
            do {
                let accept = try secureSession.finishHandshakeAsServer(initMessage: wire, salt: salt)
                sendWire(accept)
            } catch {
                onEvent(.failed(error.localizedDescription))
                cancel()
            }
        case .sealed:
            do {
                let envelope = try secureSession.open(wire)
                onEvent(.message(self, envelope))
            } catch {
                onEvent(.failed("Decrypt failed"))
                cancel()
            }
        case .hsAccept:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content {
                self.buffer.append(content)
                for line in LineFramer.split(buffer: &self.buffer) {
                    self.handleLine(line)
                }
            }
            if isComplete || error != nil {
                self.onEvent(.closed(self))
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }
}
