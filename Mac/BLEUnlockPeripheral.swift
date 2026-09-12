import Foundation
import CoreBluetooth

@MainActor
final class BLEUnlockPeripheral: NSObject, ObservableObject {
    @Published var isAdvertising = false
    @Published var status: String = "Bluetooth idle"
    @Published var bluetoothReady = false

    private var manager: CBPeripheralManager!
    private var txCharacteristic: CBMutableCharacteristic?
    private var rxCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []
    private var sessions: [UUID: BLEChannel] = [:]
    private var bufferByCentral: [UUID: Data] = [:]
    private var wantsAdvertising = false

    private let localName: String
    private let deviceID: UUID
    private let displayName: String
    private var isScreenLocked: Bool
    var onEvent: ((BLEChannel.Event) -> Void)?
    var saltProvider: ((HandshakeMode) -> Data?)?

    init(localName: String, deviceID: UUID, displayName: String, isScreenLocked: Bool) {
        self.localName = localName
        self.deviceID = deviceID
        self.displayName = displayName
        self.isScreenLocked = isScreenLocked
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func updateLockState(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        guard wantsAdvertising, manager.state == .poweredOn else { return }
        // Refresh manufacturer data so nearby phones see lock state without reconnecting.
        manager.stopAdvertising()
        manager.startAdvertising(advertisementPayload())
    }

    private func advertisementPayload() -> [String: Any] {
        [
            CBAdvertisementDataLocalNameKey: Self.bleDisplayName(localName),
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: UnlockService.bleServiceUUID)],
            CBAdvertisementDataManufacturerDataKey: DeviceIdentity.manufacturerData(for: deviceID, locked: isScreenLocked)
        ]
    }

    func startAdvertising() {
        wantsAdvertising = true
        guard manager.state == .poweredOn else {
            status = "Waiting for Bluetooth…"
            return
        }
        guard !isAdvertising else {
            manager.startAdvertising(advertisementPayload())
            return
        }

        let rx = CBMutableCharacteristic(
            type: CBUUID(string: UnlockService.bleRXUUID),
            properties: [.write, .writeWithoutResponse],
            value: nil,
            permissions: [.writeable]
        )
        let tx = CBMutableCharacteristic(
            type: CBUUID(string: UnlockService.bleTXUUID),
            properties: [.notify, .read],
            value: nil,
            permissions: [.readable]
        )
        rxCharacteristic = rx
        txCharacteristic = tx

        let service = CBMutableService(type: CBUUID(string: UnlockService.bleServiceUUID), primary: true)
        service.characteristics = [rx, tx]
        manager.removeAllServices()
        manager.add(service)

        manager.startAdvertising(advertisementPayload())
        isAdvertising = true
        status = "Advertising over Bluetooth"
    }

    /// BLE local names are short; keep a readable prefix of the Mac name.
    private static func bleDisplayName(_ name: String) -> String {
        if name.count <= 22 { return name }
        let end = name.index(name.startIndex, offsetBy: 22)
        return String(name[..<end])
    }

    func stopAdvertising() {
        wantsAdvertising = false
        if manager.state == .poweredOn {
            manager.stopAdvertising()
            manager.removeAllServices()
        }
        isAdvertising = false
        subscribedCentrals.removeAll()
        sessions.removeAll()
        bufferByCentral.removeAll()
        status = "Bluetooth stopped"
    }

    fileprivate func notify(_ data: Data, to central: CBCentral?) {
        guard let tx = txCharacteristic else { return }
        let targets = central.map { [$0] } ?? subscribedCentrals
        guard !targets.isEmpty else { return }

        let mtu = max(20, (targets.map(\.maximumUpdateValueLength).min() ?? 182) - 3)
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            let chunk = data.subdata(in: offset..<end)
            manager.updateValue(chunk, for: tx, onSubscribedCentrals: targets)
            offset = end
        }
    }
}

extension BLEUnlockPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            switch peripheral.state {
            case .poweredOn:
                self.bluetoothReady = true
                self.status = "Bluetooth ready"
                if self.wantsAdvertising {
                    self.startAdvertising()
                }
            case .poweredOff:
                self.bluetoothReady = false
                self.isAdvertising = false
                self.status = "Bluetooth is off"
            case .unauthorized:
                self.bluetoothReady = false
                self.status = "Bluetooth permission denied"
            default:
                self.bluetoothReady = false
                self.status = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { @MainActor in
            if let error {
                self.isAdvertising = false
                self.status = "Advertise failed: \(error.localizedDescription)"
            } else {
                self.isAdvertising = true
                self.status = "Advertising over Bluetooth"
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        Task { @MainActor in
            if !self.subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
                self.subscribedCentrals.append(central)
            }
            let channel = self.sessions[central.identifier] ?? BLEChannel(peripheral: self, central: central)
            channel.saltProvider = self.saltProvider
            self.sessions[central.identifier] = channel
            self.status = "iPhone connected via Bluetooth"
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        Task { @MainActor in
            self.subscribedCentrals.removeAll { $0.identifier == central.identifier }
            if let session = self.sessions.removeValue(forKey: central.identifier) {
                self.onEvent?(.closed(session))
            }
            self.bufferByCentral[central.identifier] = nil
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        Task { @MainActor in
            for request in requests {
                defer { peripheral.respond(to: request, withResult: .success) }
                guard let data = request.value, !data.isEmpty else { continue }
                let id = request.central.identifier
                var buffer = self.bufferByCentral[id] ?? Data()
                buffer.append(data)
                let channel = self.sessions[id] ?? BLEChannel(peripheral: self, central: request.central)
                channel.saltProvider = self.saltProvider
                self.sessions[id] = channel
                for line in LineFramer.split(buffer: &buffer) {
                    channel.handleIncomingLine(line)
                }
                self.bufferByCentral[id] = buffer
            }
        }
    }
}

final class BLEChannel: UnlockChannel {
    enum Event {
        case message(BLEChannel, Envelope)
        case closed(BLEChannel)
        case failed(String)
    }

    weak var peripheral: BLEUnlockPeripheral?
    let central: CBCentral
    var secret: Data?
    let secureSession = SecureSession()
    var saltProvider: ((HandshakeMode) -> Data?)?

    init(peripheral: BLEUnlockPeripheral, central: CBCentral) {
        self.peripheral = peripheral
        self.central = central
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
        Task { @MainActor in
            self.peripheral?.notify(data, to: self.central)
        }
    }

    @MainActor
    func handleIncomingLine(_ line: Data) {
        guard let wire = try? ProtocolCodec.decodeWire(from: line) else {
            peripheral?.onEvent?(.failed("Invalid wire message"))
            return
        }
        switch wire.kind {
        case .hsInit:
            guard let mode = wire.mode, let salt = saltProvider?(mode) else {
                peripheral?.onEvent?(.failed("Handshake rejected"))
                return
            }
            do {
                let accept = try secureSession.finishHandshakeAsServer(initMessage: wire, salt: salt)
                sendWire(accept)
            } catch {
                peripheral?.onEvent?(.failed(error.localizedDescription))
            }
        case .sealed:
            do {
                let envelope = try secureSession.open(wire)
                peripheral?.onEvent?(.message(self, envelope))
            } catch {
                peripheral?.onEvent?(.failed("Decrypt failed"))
            }
        case .hsAccept:
            break
        }
    }

    private func sendWire(_ wire: WireMessage) {
        guard let data = try? ProtocolCodec.encodeWire(wire) else { return }
        Task { @MainActor in
            self.peripheral?.notify(data, to: self.central)
        }
    }
}
