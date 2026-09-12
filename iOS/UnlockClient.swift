import Foundation
import Network
import UIKit

enum MacTransport: Hashable {
    case wifi(NWEndpoint)
    case bluetooth(UUID)
}

struct DiscoveredMac: Identifiable, Hashable {
    let id: String
    var name: String
    var wifiEndpoint: NWEndpoint?
    var bluetoothID: UUID?
    /// Full UUID or short id when known from Bonjour TXT / BLE ads.
    var deviceIdentity: String?
    var lockState: MacLockState = .unknown
    /// True when reachable via saved Tailscale / VPN / manual host (not Bonjour).
    var viaRemote: Bool = false

    var transportLabel: String {
        switch (wifiEndpoint != nil, bluetoothID != nil, viaRemote) {
        case (true, true, true): return "VPN · Bluetooth"
        case (true, false, true): return "VPN / Tailscale"
        case (true, true, false): return "Wi‑Fi · Bluetooth"
        case (true, false, false): return "Wi‑Fi"
        case (false, true, _): return "Bluetooth"
        default: return "Unavailable"
        }
    }

    var presenceLabel: String {
        switch lockState {
        case .locked, .unlocked:
            return "\(lockState.label) · \(transportLabel)"
        case .unknown:
            return "Online · \(transportLabel)"
        }
    }

    var isOnline: Bool { wifiEndpoint != nil || bluetoothID != nil }

    func preferredTransports(bluetoothOnly: Bool) -> [MacTransport] {
        var list: [MacTransport] = []
        if bluetoothOnly {
            if let bluetoothID { list.append(.bluetooth(bluetoothID)) }
        } else {
            if let wifiEndpoint { list.append(.wifi(wifiEndpoint)) }
            if let bluetoothID { list.append(.bluetooth(bluetoothID)) }
        }
        return list
    }
}

@MainActor
final class MacDiscovery: ObservableObject {
    @Published var peers: [DiscoveredMac] = []
    @Published var status: String = "Searching for Mac…"
    @Published var bluetoothOnly: Bool {
        didSet {
            UserDefaults.standard.set(bluetoothOnly, forKey: TransportPreference.bluetoothOnlyKey)
            restart()
        }
    }

    let wifi = MacBrowser()
    let ble = BLEUnlockCentral()

    init() {
        bluetoothOnly = UserDefaults.standard.bool(forKey: TransportPreference.bluetoothOnlyKey)
    }

    func start() {
        restart()
    }

    func stop() {
        wifi.stop()
        ble.stopScanning()
    }

    private func restart() {
        wifi.stop()
        ble.stopScanning()
        peers = []

        if bluetoothOnly {
            ble.startScanning()
            status = ble.status
        } else {
            wifi.start()
            ble.startScanning()
            refresh()
        }
    }

    func refresh() {
        func stripBonjourSuffix(_ name: String) -> String {
            name.replacingOccurrences(of: #"\s*\(\d+\)$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func isServiceLabel(_ name: String) -> Bool {
            name.range(of: #"^(?:Latch|MacUnlock)-[A-Fa-f0-9]{8}"#, options: .regularExpression) != nil
        }
        func niceName(_ name: String) -> String {
            let cleaned = stripBonjourSuffix(name)
            return isServiceLabel(cleaned) ? cleaned : cleaned
        }
        func mergeLock(_ current: MacLockState, _ incoming: MacLockState) -> MacLockState {
            if incoming == .unknown { return current }
            return incoming
        }

        var byKey: [String: DiscoveredMac] = [:]
        var displayNames: [String: String] = [:] // shortID → computer name

        func upsert(
            deviceID: String?,
            rawName: String,
            wifi: NWEndpoint? = nil,
            ble: UUID? = nil,
            lockState: MacLockState = .unknown,
            viaRemote: Bool = false
        ) {
            let cleaned = stripBonjourSuffix(rawName)
            let short = DeviceIdentity.shortID(from: deviceID, name: cleaned)
            let isConflictCopy = rawName.range(of: #"\(\d+\)$"#, options: .regularExpression) != nil

            if let short, !isServiceLabel(cleaned) {
                displayNames[short] = cleaned
            }

            let key: String
            if let short {
                key = "id:" + short
            } else {
                key = "name:" + cleaned.lowercased()
            }

            var entry = byKey[key] ?? DiscoveredMac(
                id: key,
                name: niceName(cleaned),
                wifiEndpoint: nil,
                bluetoothID: nil,
                deviceIdentity: deviceID ?? short,
                lockState: .unknown,
                viaRemote: false
            )
            if entry.deviceIdentity == nil {
                entry.deviceIdentity = deviceID ?? short
            } else if let deviceID, deviceID.count > (entry.deviceIdentity?.count ?? 0) {
                entry.deviceIdentity = deviceID
            }
            if let short, let better = displayNames[short] {
                entry.name = better
            } else if !isServiceLabel(cleaned), (isServiceLabel(entry.name) || cleaned.count >= entry.name.count) {
                entry.name = cleaned
            }

            entry.lockState = mergeLock(entry.lockState, lockState)
            if let ble { entry.bluetoothID = ble }
            if let wifi {
                if viaRemote {
                    if entry.wifiEndpoint == nil {
                        entry.wifiEndpoint = wifi
                        entry.viaRemote = true
                    }
                } else if entry.wifiEndpoint == nil || !isConflictCopy {
                    entry.wifiEndpoint = wifi
                    entry.viaRemote = false
                }
            }
            byKey[key] = entry
        }

        if !bluetoothOnly {
            for peer in wifi.peers {
                upsert(deviceID: peer.deviceID, rawName: peer.name, wifi: peer.endpoint, lockState: peer.lockState)
            }
            // Saved Tailscale / VPN / LAN hosts when Bonjour can't see the Mac.
            for paired in PairedMacStore.loadAll() {
                guard let host = paired.remoteHost,
                      let endpoint = LatchNetwork.endpoint(host: host, port: paired.resolvedRemotePort) else { continue }
                upsert(
                    deviceID: paired.id,
                    rawName: paired.name,
                    wifi: endpoint,
                    lockState: .unknown,
                    viaRemote: true
                )
            }
        }
        for peer in ble.peers {
            upsert(deviceID: peer.deviceID, rawName: peer.name, ble: peer.id, lockState: peer.lockState)
        }

        // Apply best display names and collapse pure name-keys into id-keys when possible.
        for (key, var entry) in byKey {
            if key.hasPrefix("id:") {
                let short = String(key.dropFirst(3))
                if let better = displayNames[short] {
                    entry.name = better
                    byKey[key] = entry
                }
            }
        }
        for (nameKey, nameEntry) in byKey where nameKey.hasPrefix("name:") {
            if let short = DeviceIdentity.shortID(from: nil, name: nameEntry.name),
               var matched = byKey["id:" + short] {
                if matched.wifiEndpoint == nil { matched.wifiEndpoint = nameEntry.wifiEndpoint }
                if matched.bluetoothID == nil { matched.bluetoothID = nameEntry.bluetoothID }
                if matched.lockState == .unknown { matched.lockState = nameEntry.lockState }
                if !isServiceLabel(nameEntry.name) { matched.name = stripBonjourSuffix(nameEntry.name) }
                byKey["id:" + short] = matched
                byKey.removeValue(forKey: nameKey)
            } else if let match = byKey.first(where: {
                $0.key.hasPrefix("id:") && $0.value.name.lowercased() == stripBonjourSuffix(nameEntry.name).lowercased()
            }) {
                var matched = match.value
                if matched.wifiEndpoint == nil { matched.wifiEndpoint = nameEntry.wifiEndpoint }
                if matched.bluetoothID == nil { matched.bluetoothID = nameEntry.bluetoothID }
                if matched.lockState == .unknown { matched.lockState = nameEntry.lockState }
                byKey[match.key] = matched
                byKey.removeValue(forKey: nameKey)
            }
        }

        // Last resort for a single Mac household: if exactly 2 rows and one is Wi‑Fi-only
        // service-label + one shares transports, merge them.
        if byKey.count == 2 {
            let values = Array(byKey.values)
            if let a = values.first, let b = values.last {
                let aIsLabel = isServiceLabel(a.name)
                let bIsLabel = isServiceLabel(b.name)
                if aIsLabel != bIsLabel || (a.wifiEndpoint != nil && b.bluetoothID != nil) || (b.wifiEndpoint != nil && a.bluetoothID != nil) {
                    var merged = DiscoveredMac(
                        id: a.id.hasPrefix("id:") ? a.id : b.id,
                        name: aIsLabel ? b.name : a.name,
                        wifiEndpoint: a.wifiEndpoint ?? b.wifiEndpoint,
                        bluetoothID: a.bluetoothID ?? b.bluetoothID,
                        deviceIdentity: a.deviceIdentity ?? b.deviceIdentity
                    )
                    if isServiceLabel(merged.name) {
                        merged.name = aIsLabel ? b.name : a.name
                    }
                    byKey = [merged.id: merged]
                }
            }
        }

        peers = byKey.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if bluetoothOnly {
            status = ble.status
        } else if peers.isEmpty {
            status = "Looking over Wi‑Fi and Bluetooth…"
        } else {
            status = "Found \(peers.count) Mac\(peers.count == 1 ? "" : "s")"
        }
    }
}

@MainActor
final class MacBrowser: ObservableObject {
    struct Peer: Identifiable, Hashable {
        let id: String
        let name: String
        let endpoint: NWEndpoint
        let deviceID: String?
        let lockState: MacLockState
    }

    @Published var peers: [Peer] = []
    @Published var status: String = "Searching for Mac…"

    private var browser: NWBrowser?

    func start() {
        stop()
        let descriptor = NWBrowser.Descriptor.bonjour(type: UnlockService.type, domain: UnlockService.domain)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.status = "Looking for Latch…"
                case .failed(let error):
                    self?.status = "Browse failed: \(error.localizedDescription)"
                default:
                    break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.peers = results.compactMap { result in
                    guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                    var deviceID: String?
                    var displayName = name
                    var lockState: MacLockState = .unknown
                    if case let .bonjour(txt) = result.metadata {
                        let dict = txt.dictionary
                        deviceID = dict["id"] ?? txt["id"]
                        if let txtName = dict["name"] ?? txt["name"], !txtName.isEmpty {
                            displayName = txtName
                        }
                        lockState = DeviceIdentity.lockState(fromTXT: dict["locked"] ?? txt["locked"])
                    }
                    if deviceID == nil {
                        deviceID = DeviceIdentity.shortID(from: nil, name: name)
                    }
                    return Peer(
                        id: deviceID ?? name,
                        name: displayName,
                        endpoint: result.endpoint,
                        deviceID: deviceID,
                        lockState: lockState
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if self.peers.isEmpty {
                    self.status = "No Mac found on this Wi‑Fi. Is Latch running?"
                } else {
                    self.status = "Found \(self.peers.count) Mac\(self.peers.count == 1 ? "" : "s")"
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}

@MainActor
final class UnlockClient: ObservableObject {
    @Published var isBusy = false
    @Published var message: String = ""
    @Published var pairedMacs: [PairedMac] = []
    @Published var selectedPairedID: String? {
        didSet {
            if let selectedPairedID {
                UserDefaults.standard.set(selectedPairedID, forKey: TransportPreference.selectedPairedIDKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TransportPreference.selectedPairedIDKey)
            }
        }
    }
    /// Live lock state keyed by paired Mac id (from status polls).
    @Published var lockStatusByID: [String: MacLockState] = [:]

    var isPaired: Bool { !pairedMacs.isEmpty }

    private var connection: NWConnection?
    private var buffer = Data()
    private var pendingContinuation: CheckedContinuation<Envelope, Error>?
    private var acceptPredicate: ((Envelope) -> Bool)?
    private var session: SecureSession?
    private let ble: BLEUnlockCentral

    init(ble: BLEUnlockCentral) {
        self.ble = ble
        selectedPairedID = UserDefaults.standard.string(forKey: TransportPreference.selectedPairedIDKey)
        reloadPairing()
    }

    func reloadPairing() {
        pairedMacs = PairedMacStore.loadAll()
        if let selected = selectedPairedID, PairedMacStore.find(id: selected) != nil {
            return
        }
        selectedPairedID = pairedMacs.first?.id
    }

    func clearPairing() {
        PairedMacStore.removeAll()
        pairedMacs = []
        selectedPairedID = nil
        message = "All pairings removed."
    }

    func removePairing(id: String) {
        try? PairedMacStore.remove(id: id)
        reloadPairing()
        message = "Mac removed."
    }

    func secret(for discovered: DiscoveredMac) -> Data? {
        PairedMacStore.find(matching: discovered)?.secret
    }

    func pairedMac(for discovered: DiscoveredMac) -> PairedMac? {
        PairedMacStore.find(matching: discovered)
    }

    func unlock(mac: DiscoveredMac, method: String, bluetoothOnly: Bool) async throws {
        guard let paired = PairedMacStore.find(matching: mac) else {
            throw ClientError.notPaired
        }
        let secret = paired.secret
        isBusy = true
        defer { isBusy = false }
        message = "Unlocking \(paired.name)…"

        let device = UIDevice.current.name
        let payload = UnlockRequestPayload(deviceName: device, method: method)
        let payloadData = try ProtocolCodec.encode(payload)

        let envelope = try await exchange(
            mac: mac,
            bluetoothOnly: bluetoothOnly,
            mode: .unlock,
            salt: secret,
            build: {
                var env = Envelope(type: .unlockRequest, payload: payloadData)
                try AuthCrypto.sign(&env, secret: secret)
                return env
            },
            accept: { $0.type == .unlockOK || $0.type == .unlockFail }
        )

        if envelope.type == .unlockOK {
            message = "\(paired.name) unlocked"
            selectedPairedID = paired.id
            lockStatusByID[paired.id] = .unlocked
            return
        }
        throw ClientError.server(failReason(envelope) ?? "Unlock failed")
    }

    func lock(mac: DiscoveredMac, method: String, bluetoothOnly: Bool) async throws {
        guard let paired = PairedMacStore.find(matching: mac) else {
            throw ClientError.notPaired
        }
        let secret = paired.secret
        isBusy = true
        defer { isBusy = false }
        message = "Locking \(paired.name)…"

        let device = UIDevice.current.name
        let payload = LockRequestPayload(deviceName: device, method: method)
        let payloadData = try ProtocolCodec.encode(payload)

        let envelope = try await exchange(
            mac: mac,
            bluetoothOnly: bluetoothOnly,
            mode: .unlock,
            salt: secret,
            build: {
                var env = Envelope(type: .lockRequest, payload: payloadData)
                try AuthCrypto.sign(&env, secret: secret)
                return env
            },
            accept: { $0.type == .lockOK || $0.type == .unlockFail }
        )

        if envelope.type == .lockOK {
            message = "\(paired.name) locked"
            selectedPairedID = paired.id
            lockStatusByID[paired.id] = .locked
            return
        }
        throw ClientError.server(failReason(envelope) ?? "Lock failed")
    }

    /// Lightweight poll — does not toggle `isBusy` so the UI stays usable.
    func refreshLockStatus(mac: DiscoveredMac, bluetoothOnly: Bool) async {
        guard let paired = PairedMacStore.find(matching: mac) else { return }
        let secret = paired.secret
        do {
            let envelope = try await exchange(
                mac: mac,
                bluetoothOnly: bluetoothOnly,
                mode: .unlock,
                salt: secret,
                build: {
                    var env = Envelope(type: .statusRequest)
                    try AuthCrypto.sign(&env, secret: secret)
                    return env
                },
                accept: { $0.type == .statusOK || $0.type == .unlockFail }
            )
            guard envelope.type == .statusOK,
                  let data = envelope.payload,
                  let status = try? ProtocolCodec.decode(StatusPayload.self, from: data) else {
                return
            }
            lockStatusByID[paired.id] = status.locked ? .locked : .unlocked
        } catch {
            // Keep last known status on transient network errors.
        }
    }

    func pair(mac: DiscoveredMac, pin: String, bluetoothOnly: Bool) async throws {
        isBusy = true
        defer { isBusy = false }
        message = "Pairing (encrypted)…"
        let salt = Data(pin.utf8)
        let envelope = try await exchange(
            mac: mac,
            bluetoothOnly: bluetoothOnly,
            mode: .pair,
            salt: salt,
            build: { Envelope(type: .pairRequest, payload: Data(pin.utf8)) },
            accept: { $0.type == .pairAccept || $0.type == .unlockFail }
        )

        if envelope.type == .unlockFail {
            throw ClientError.server(failReason(envelope) ?? "Pairing failed")
        }

        guard let data = envelope.payload,
              let accept = try? ProtocolCodec.decode(PairAcceptPayload.self, from: data) else {
            throw ClientError.server("Invalid pairing response")
        }

        let id = accept.deviceID
            ?? mac.deviceIdentity
            ?? DeviceIdentity.shortID(from: nil, name: mac.name)
            ?? mac.id
        var remoteHost: String?
        var remotePort: UInt16?
        if mac.viaRemote, case let .hostPort(host, port) = mac.wifiEndpoint {
            remoteHost = "\(host)"
            remotePort = port.rawValue
        }
        let paired = try PairedMacStore.upsert(
            id: id,
            name: accept.deviceName,
            secret: accept.secret,
            remoteHost: remoteHost,
            remotePort: remotePort
        )
        reloadPairing()
        selectedPairedID = paired.id
        message = "Paired with \(accept.deviceName)"
    }

    func saveRemoteHost(_ host: String, port: UInt16 = UnlockService.tcpPort, forPairedID id: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try PairedMacStore.setRemote(id: id, host: nil, port: nil)
            reloadPairing()
            message = "Cleared VPN address"
            return
        }
        try PairedMacStore.setRemote(id: id, host: trimmed, port: port)
        reloadPairing()
        message = "Saved \(trimmed):\(port) for VPN / Tailscale"
    }

    /// Parses `host` or `host:port` (IPv4 / hostname). Returns nil if empty/invalid.
    static func parseHostPort(_ input: String, defaultPort: UInt16 = UnlockService.tcpPort) -> (host: String, port: UInt16)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let portText = String(trimmed[trimmed.index(after: colon)...])
            if let port = UInt16(portText), !host.isEmpty, !host.contains(":") {
                return (host, port)
            }
        }
        return (trimmed, defaultPort)
    }

    /// TCP + Latch status handshake. Only saves the address if this paired Mac answers.
    func testAndSaveRemoteHost(_ input: String, forPairedID id: String) async throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try saveRemoteHost("", forPairedID: id)
            return
        }
        guard let parsed = Self.parseHostPort(trimmed) else {
            throw ClientError.server("Enter a Tailscale IP or MagicDNS name.")
        }
        guard let paired = PairedMacStore.find(id: id) else {
            throw ClientError.notPaired
        }
        guard let mac = remoteDiscoveredMac(
            host: parsed.host,
            port: parsed.port,
            name: paired.name,
            deviceID: paired.id
        ) else {
            throw ClientError.server("Invalid address.")
        }

        isBusy = true
        defer { isBusy = false }
        message = "Testing \(parsed.host):\(parsed.port)…"

        let secret = paired.secret
        let envelope: Envelope
        do {
            envelope = try await exchange(
                mac: mac,
                bluetoothOnly: false,
                mode: .unlock,
                salt: secret,
                build: {
                    var env = Envelope(type: .statusRequest)
                    try AuthCrypto.sign(&env, secret: secret)
                    return env
                },
                accept: { $0.type == .statusOK || $0.type == .unlockFail }
            )
        } catch {
            throw ClientError.server(
                "Couldn’t reach Latch at \(parsed.host):\(parsed.port). Check Tailscale/VPN on both devices and that Latch is running."
            )
        }

        if envelope.type == .unlockFail {
            throw ClientError.server(failReason(envelope) ?? "Latch rejected the test (re-pair if needed).")
        }
        guard envelope.type == .statusOK,
              let data = envelope.payload,
              let status = try? ProtocolCodec.decode(StatusPayload.self, from: data) else {
            throw ClientError.server("Connected, but didn’t get a Latch status reply.")
        }

        lockStatusByID[paired.id] = status.locked ? .locked : .unlocked
        try PairedMacStore.setRemote(id: id, host: parsed.host, port: parsed.port)
        reloadPairing()
        selectedPairedID = paired.id
        let state = status.locked ? "locked" : "unlocked"
        message = "Reachable — \(parsed.host):\(parsed.port) (\(state))"
    }

    /// Build a discoverable Mac entry for a manual Tailscale / VPN host (pairing or unlock).
    func remoteDiscoveredMac(
        host: String,
        port: UInt16 = UnlockService.tcpPort,
        name: String? = nil,
        deviceID: String? = nil
    ) -> DiscoveredMac? {
        guard let endpoint = LatchNetwork.endpoint(host: host, port: port) else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoveredMac(
            id: "remote:" + trimmed.lowercased(),
            name: name ?? trimmed,
            wifiEndpoint: endpoint,
            bluetoothID: nil,
            deviceIdentity: deviceID,
            lockState: .unknown,
            viaRemote: true
        )
    }

    private func exchange(
        mac: DiscoveredMac,
        bluetoothOnly: Bool,
        mode: HandshakeMode,
        salt: Data,
        build: @escaping () throws -> Envelope,
        accept: @escaping (Envelope) -> Bool
    ) async throws -> Envelope {
        let transports = mac.preferredTransports(bluetoothOnly: bluetoothOnly)
        guard !transports.isEmpty else {
            throw ClientError.server("Mac has no available transport.")
        }

        var lastError: Error = ClientError.server("All transports failed.")
        for transport in transports {
            do {
                switch transport {
                case .wifi(let endpoint):
                    return try await sendExpecting(endpoint: endpoint, mode: mode, salt: salt, build: build, accept: accept)
                case .bluetooth(let id):
                    return try await ble.sendExpecting(peripheralID: id, mode: mode, salt: salt, build: build, accept: accept)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func failReason(_ envelope: Envelope) -> String? {
        guard let data = envelope.payload,
              let fail = try? ProtocolCodec.decode(UnlockFailPayload.self, from: data) else {
            return nil
        }
        return fail.reason
    }

    private func sendExpecting(
        endpoint: NWEndpoint,
        mode: HandshakeMode,
        salt: Data,
        build: @escaping () throws -> Envelope,
        accept: @escaping (Envelope) -> Bool
    ) async throws -> Envelope {
        cancelWiFi()
        buffer = Data()
        let session = SecureSession()
        self.session = session
        self.acceptPredicate = accept
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Envelope, Error>) in
            self.pendingContinuation = cont
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        do {
                            let hs = session.makeHandshakeInit(mode: mode)
                            self.writeWire(hs, on: connection)
                            self.receive(on: connection, mode: mode, salt: salt, build: build)
                        } catch {
                            self.finish(.failure(error))
                        }
                    case .failed(let error):
                        self.finish(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func writeWire(_ wire: WireMessage, on connection: NWConnection) {
        guard let data = try? ProtocolCodec.encodeWire(wire) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive(
        on connection: NWConnection,
        mode: HandshakeMode,
        salt: Data,
        build: @escaping () throws -> Envelope
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self, let session = self.session else { return }
                if let content {
                    self.buffer.append(content)
                    for line in LineFramer.split(buffer: &self.buffer) {
                        guard let wire = try? ProtocolCodec.decodeWire(from: line) else { continue }
                        switch wire.kind {
                        case .hsAccept:
                            do {
                                try session.finishHandshakeAsClient(accept: wire, salt: salt)
                                let envelope = try build()
                                let sealed = try session.seal(envelope)
                                self.writeWire(sealed, on: connection)
                            } catch {
                                self.finish(.failure(error))
                                connection.cancel()
                                return
                            }
                        case .sealed:
                            do {
                                let envelope = try session.open(wire)
                                if envelope.type == .hello || envelope.type == .pong { continue }
                                if let accept = self.acceptPredicate, accept(envelope) {
                                    // For unlock responses, `salt` is the pairing secret used to sign.
                                    if envelope.mac != nil && (envelope.type == .unlockOK || envelope.type == .lockOK || envelope.type == .statusOK) {
                                        let ok = AuthCrypto.verifyDetailed(envelope, secret: salt) == .ok
                                        if !ok {
                                            self.finish(.failure(ClientError.server("Invalid server signature")))
                                            connection.cancel()
                                            return
                                        }
                                    }
                                    self.finish(.success(envelope))
                                    connection.cancel()
                                    return
                                }
                            } catch {
                                self.finish(.failure(error))
                                connection.cancel()
                                return
                            }
                        default:
                            break
                        }
                    }
                }
                if let error {
                    self.finish(.failure(error))
                    connection.cancel()
                    return
                }
                if isComplete {
                    self.finish(.failure(ClientError.server("Connection closed")))
                    return
                }
                self.receive(on: connection, mode: mode, salt: salt, build: build)
            }
        }
    }

    private func finish(_ result: Result<Envelope, Error>) {
        guard let cont = pendingContinuation else { return }
        pendingContinuation = nil
        acceptPredicate = nil
        cont.resume(with: result)
    }

    private func cancelWiFi() {
        connection?.cancel()
        connection = nil
        session = nil
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(throwing: CancellationError())
        }
    }

    enum ClientError: LocalizedError {
        case notPaired
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: return "Pair with your Mac first."
            case .server(let message): return message
            }
        }
    }
}
