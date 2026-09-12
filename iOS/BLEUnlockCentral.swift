import Foundation
import CoreBluetooth

@MainActor
final class BLEUnlockCentral: NSObject, ObservableObject {
    struct Peer: Identifiable, Hashable {
        let id: UUID
        let name: String
        let deviceID: String?
        let lockState: MacLockState
    }

    @Published var peers: [Peer] = []
    @Published var status: String = "Bluetooth idle"
    @Published var isReady = false

    private var manager: CBCentralManager!
    private var wantsScanning = false
    private var seen: [UUID: (name: String, deviceID: String?, lockState: MacLockState)] = [:]

    private var activePeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var receiveBuffer = Data()
    private var pendingContinuation: CheckedContinuation<Envelope, Error>?
    private var acceptPredicate: ((Envelope) -> Bool)?
    private var pendingBuild: (() throws -> Envelope)?
    private var session: SecureSession?
    private var handshakeSalt: Data?
    private var handshakeMode: HandshakeMode?
    private var didSendHandshake = false

    override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        wantsScanning = true
        guard manager.state == .poweredOn else {
            status = "Waiting for Bluetooth…"
            return
        }
        manager.scanForPeripherals(
            withServices: [CBUUID(string: UnlockService.bleServiceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        status = "Scanning for Mac over Bluetooth…"
    }

    func stopScanning() {
        wantsScanning = false
        if manager.state == .poweredOn {
            manager.stopScan()
        }
        status = "Bluetooth scan stopped"
    }

    func sendExpecting(
        peripheralID: UUID,
        mode: HandshakeMode,
        salt: Data,
        build: @escaping () throws -> Envelope,
        accept: @escaping (Envelope) -> Bool
    ) async throws -> Envelope {
        cancelPending(with: CancellationError())
        receiveBuffer = Data()
        acceptPredicate = accept
        pendingBuild = build
        handshakeSalt = salt
        handshakeMode = mode
        session = SecureSession()
        didSendHandshake = false

        guard let peripheral = activePeripheral(matching: peripheralID) ?? retrieve(peripheralID) else {
            throw BLEError.notFound
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Envelope, Error>) in
            self.pendingContinuation = cont
            self.activePeripheral = peripheral
            peripheral.delegate = self

            if peripheral.state == .connected, self.rxCharacteristic != nil, self.txCharacteristic != nil {
                self.beginEncryptedExchange(on: peripheral)
            } else {
                self.rxCharacteristic = nil
                self.txCharacteristic = nil
                self.manager.connect(peripheral, options: nil)
                self.status = "Connecting over Bluetooth…"
            }
        }
    }

    func cancel() {
        cancelPending(with: CancellationError())
        if let peripheral = activePeripheral {
            manager.cancelPeripheralConnection(peripheral)
        }
        activePeripheral = nil
        rxCharacteristic = nil
        txCharacteristic = nil
        session = nil
    }

    private func beginEncryptedExchange(on peripheral: CBPeripheral) {
        guard !didSendHandshake,
              let session,
              let mode = handshakeMode,
              txCharacteristic != nil,
              rxCharacteristic != nil else { return }
        didSendHandshake = true
        let hs = session.makeHandshakeInit(mode: mode)
        do {
            try writeWire(hs, to: peripheral)
            status = "Securing Bluetooth link…"
        } catch {
            finish(.failure(error))
        }
    }

    private func cancelPending(with error: Error) {
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(throwing: error)
        }
        pendingBuild = nil
        acceptPredicate = nil
    }

    private func finish(_ result: Result<Envelope, Error>) {
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        pendingBuild = nil
        acceptPredicate = nil
        cont.resume(with: result)
    }

    private func retrieve(_ id: UUID) -> CBPeripheral? {
        manager.retrievePeripherals(withIdentifiers: [id]).first
    }

    private func activePeripheral(matching id: UUID) -> CBPeripheral? {
        if let active = activePeripheral, active.identifier == id { return active }
        return nil
    }

    private func writeWire(_ wire: WireMessage, to peripheral: CBPeripheral) throws {
        guard let rx = rxCharacteristic else { throw BLEError.notReady }
        guard let data = try? ProtocolCodec.encodeWire(wire) else { throw BLEError.encoding }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            peripheral.writeValue(chunk, for: rx, type: .withResponse)
            offset = end
        }
    }

    private func handleLine(_ line: Data, peripheral: CBPeripheral) {
        guard let wire = try? ProtocolCodec.decodeWire(from: line), let session else { return }
        switch wire.kind {
        case .hsAccept:
            guard let salt = handshakeSalt else {
                finish(.failure(BLEError.notReady))
                return
            }
            do {
                try session.finishHandshakeAsClient(accept: wire, salt: salt)
                guard let build = pendingBuild else { throw BLEError.notReady }
                pendingBuild = nil
                let envelope = try build()
                let sealed = try session.seal(envelope)
                try writeWire(sealed, to: peripheral)
                status = "Sent encrypted request"
            } catch {
                finish(.failure(error))
            }
        case .sealed:
            do {
                let envelope = try session.open(wire)
                if envelope.type == .hello || envelope.type == .pong { return }
                guard let accept = acceptPredicate, accept(envelope) else { return }
                finish(.success(envelope))
            } catch {
                finish(.failure(error))
            }
        default:
            break
        }
    }

    private func publishPeers() {
        peers = seen.map {
            Peer(id: $0.key, name: $0.value.name, deviceID: $0.value.deviceID, lockState: $0.value.lockState)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if peers.isEmpty {
            status = "No Mac found over Bluetooth. Is Latch running nearby?"
        } else {
            status = "Found \(peers.count) Mac\(peers.count == 1 ? "" : "s") over Bluetooth"
        }
    }
}

extension BLEUnlockCentral: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.isReady = true
                self.status = "Bluetooth ready"
                if self.wantsScanning {
                    self.startScanning()
                }
            case .poweredOff:
                self.isReady = false
                self.status = "Bluetooth is off"
            case .unauthorized:
                self.isReady = false
                self.status = "Bluetooth permission denied"
            default:
                self.isReady = false
                self.status = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let advertised = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? peripheral.name
                ?? "Mac"
            var deviceID: String?
            var lockState: MacLockState = .unknown
            if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
               let parsed = DeviceIdentity.parseManufacturerData(mfg) {
                deviceID = parsed.uuid.uuidString
                if let locked = parsed.locked {
                    lockState = locked ? .locked : .unlocked
                }
            } else if let short = DeviceIdentity.shortID(from: nil, name: advertised) {
                deviceID = short
            }
            self.seen[peripheral.identifier] = (advertised, deviceID, lockState)
            self.publishPeers()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.status = "Connected — discovering…"
            peripheral.discoverServices([CBUUID(string: UnlockService.bleServiceUUID)])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.finish(.failure(error ?? BLEError.connectFailed))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if self.pendingContinuation != nil {
                self.finish(.failure(error ?? BLEError.disconnected))
            }
            self.rxCharacteristic = nil
            self.txCharacteristic = nil
            self.didSendHandshake = false
        }
    }
}

extension BLEUnlockCentral: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: UnlockService.bleServiceUUID) }) else {
                self.finish(.failure(BLEError.notReady))
                return
            }
            peripheral.discoverCharacteristics(
                [CBUUID(string: UnlockService.bleRXUUID), CBUUID(string: UnlockService.bleTXUUID)],
                for: service
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                self.finish(.failure(error))
                return
            }
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == CBUUID(string: UnlockService.bleRXUUID) {
                    self.rxCharacteristic = characteristic
                } else if characteristic.uuid == CBUUID(string: UnlockService.bleTXUUID) {
                    self.txCharacteristic = characteristic
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            guard self.rxCharacteristic != nil, self.txCharacteristic != nil else {
                self.finish(.failure(BLEError.notReady))
                return
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                if self.pendingContinuation != nil {
                    self.finish(.failure(error))
                }
                return
            }
            guard characteristic.isNotifying else { return }
            self.beginEncryptedExchange(on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let data = characteristic.value else { return }
            self.receiveBuffer.append(data)
            for line in LineFramer.split(buffer: &self.receiveBuffer) {
                self.handleLine(line, peripheral: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.finish(.failure(error))
            }
        }
    }
}

enum BLEError: LocalizedError {
    case notFound
    case notReady
    case encoding
    case connectFailed
    case disconnected
    case badSignature

    var errorDescription: String? {
        switch self {
        case .notFound: return "Mac not found over Bluetooth."
        case .notReady: return "Bluetooth link is not ready."
        case .encoding: return "Could not encode the request."
        case .connectFailed: return "Bluetooth connection failed."
        case .disconnected: return "Bluetooth disconnected."
        case .badSignature: return "Invalid server signature."
        }
    }
}
