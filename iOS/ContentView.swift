import SwiftUI
import AVFoundation
import Network

@main
struct LatchiOSApp: App {
    @StateObject private var discovery: MacDiscovery
    @StateObject private var client: UnlockClient

    init() {
        let discovery = MacDiscovery()
        _discovery = StateObject(wrappedValue: discovery)
        _client = StateObject(wrappedValue: UnlockClient(ble: discovery.ble))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(discovery)
                .environmentObject(client)
                .onAppear {
                    client.reloadPairing()
                    discovery.start()
                }
                .onReceive(discovery.wifi.$peers) { _ in discovery.refresh() }
                .onReceive(discovery.ble.$peers) { _ in discovery.refresh() }
                .onReceive(discovery.ble.$status) { _ in discovery.refresh() }
                .onReceive(discovery.wifi.$status) { _ in discovery.refresh() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var discovery: MacDiscovery
    @EnvironmentObject private var client: UnlockClient
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TransportPreference.unlockOnLaunchKey) private var unlockOnLaunch = false
    @AppStorage(TransportPreference.requireBiometricKey) private var requireBiometric = true
    @State private var showScanner = false
    @State private var showAddMac = false
    @State private var manualPIN = ""
    @State private var selectedMac: DiscoveredMac?
    @State private var alertMessage: String?
    @State private var remoteHostDraft = ""
    @State private var autoUnlockGeneration = 0
    /// Set after the first auto-unlock attempt in this process; never reset while alive.
    @State private var didAutoUnlockThisProcess = false
    /// Once true, further foregroundings are app switches, not launches.
    @State private var hasBeenBackgrounded = false
    @State private var isConfirmingBiometricChange = false
    @State private var actionInFlight = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    optionsSection

                    if client.isPaired {
                        pairedSection
                        remoteSection
                    }

                    nearbySection

                    if showAddMac || !client.isPaired {
                        pairingControls
                    } else {
                        Button {
                            showAddMac = true
                        } label: {
                            Label("Add another Mac", systemImage: "plus.circle")
                                .font(.custom("AvenirNext-Medium", size: 15))
                                .foregroundStyle(Color(red: 0.85, green: 0.92, blue: 0.55))
                        }
                    }

                    footerStatus
                }
                .padding(24)
            }
            .background(background)
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showScanner) {
                QRScannerView { code in
                    showScanner = false
                    handleScanned(code)
                }
            }
            .alert("Latch", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhase(phase)
            }
            .onAppear {
                // Cold start: scene may already be .active without an onChange.
                handleScenePhase(scenePhase)
            }
            .onReceive(Timer.publish(every: 3.0, on: .main, in: .common).autoconnect()) { _ in
                guard scenePhase == .active, !client.isBusy else { return }
                Task { await pollLockStatus() }
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            hasBeenBackgrounded = true
            // Cancel any in-flight "looking for Mac" wait from the launch attempt.
            autoUnlockGeneration += 1
        case .active:
            // Only on cold launch — not when switching back from the app switcher.
            guard unlockOnLaunch, client.isPaired else {
                Task { await pollLockStatus() }
                return
            }
            guard !hasBeenBackgrounded, !didAutoUnlockThisProcess else {
                Task { await pollLockStatus() }
                return
            }
            didAutoUnlockThisProcess = true
            autoUnlockGeneration += 1
            let generation = autoUnlockGeneration
            Task { await maybeUnlockOnLaunch(generation: generation) }
        default:
            break
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(red: 0.07, green: 0.10, blue: 0.14),
                Color(red: 0.12, green: 0.18, blue: 0.22),
                Color(red: 0.05, green: 0.08, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Latch")
                .font(.custom("AvenirNext-Heavy", size: 40))
                .foregroundStyle(.white)
            Text(requireBiometric
                 ? "Unlock any paired Mac with Face ID, Touch ID, or passcode."
                 : "Unlock any paired Mac. Biometrics are off.")
                .font(.custom("AvenirNext-Regular", size: 16))
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $discovery.bluetoothOnly) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bluetooth only")
                        .font(.custom("AvenirNext-DemiBold", size: 15))
                        .foregroundStyle(.white)
                    Text("Ignore Wi‑Fi and unlock only nearby over Bluetooth")
                        .font(.custom("AvenirNext-Regular", size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(Color(red: 0.85, green: 0.92, blue: 0.55))

            Toggle(isOn: $unlockOnLaunch) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock on launch")
                        .font(.custom("AvenirNext-DemiBold", size: 15))
                        .foregroundStyle(.white)
                    Text(unlockOnLaunch
                         ? "Unlock once when you open the app (not when switching back)"
                         : "Only unlock when you tap the button")
                        .font(.custom("AvenirNext-Regular", size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(Color(red: 0.85, green: 0.92, blue: 0.55))
            .disabled(!client.isPaired)

            Toggle(isOn: biometricRequirementBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require Face ID / Touch ID")
                        .font(.custom("AvenirNext-DemiBold", size: 15))
                        .foregroundStyle(.white)
                    Text(requireBiometric
                         ? "Ask for biometrics or passcode before unlocking"
                         : "Unlock immediately without biometrics")
                        .font(.custom("AvenirNext-Regular", size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .tint(Color(red: 0.85, green: 0.92, blue: 0.55))
            .disabled(isConfirmingBiometricChange)
        }
    }

    private var biometricRequirementBinding: Binding<Bool> {
        Binding(
            get: { requireBiometric },
            set: { newValue in
                if requireBiometric, !newValue {
                    Task { await confirmDisableBiometrics() }
                } else {
                    requireBiometric = newValue
                }
            }
        )
    }

    private func confirmDisableBiometrics() async {
        guard !isConfirmingBiometricChange else { return }
        isConfirmingBiometricChange = true
        defer { isConfirmingBiometricChange = false }
        do {
            _ = try await BiometricGate.authenticate(
                reason: "Turn off Face ID for Latch",
                biometricsOnly: true
            )
            requireBiometric = false
        } catch let error as BiometricGate.AuthError {
            requireBiometric = true
            if let message = BiometricGate.userFacingMessage(from: error) {
                alertMessage = message
            }
        } catch {
            requireBiometric = true
            if let message = BiometricGate.userFacingMessage(from: error) {
                alertMessage = message
            }
        }
    }

    private var pairedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paired Macs")
                .font(.custom("AvenirNext-DemiBold", size: 14))
                .foregroundStyle(.white.opacity(0.55))

            ForEach(client.pairedMacs) { mac in
                let online = discovery.peers.first(where: { client.pairedMac(for: $0)?.id == mac.id })
                let lockState = displayedLockState(for: mac.id, online: online)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(mac.name)
                            .font(.custom("AvenirNext-Medium", size: 16))
                            .foregroundStyle(.white)
                        Text(statusLine(lockState: lockState, online: online))
                            .font(.custom("AvenirNext-Regular", size: 12))
                            .foregroundStyle(lockColor(lockState))
                    }
                    Spacer()
                    Image(systemName: lockState == .locked ? "lock.fill" : lockState == .unlocked ? "lock.open" : "questionmark.circle")
                        .foregroundStyle(lockColor(lockState))
                    if client.selectedPairedID == mac.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color(red: 0.85, green: 0.92, blue: 0.55))
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(client.selectedPairedID == mac.id ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    client.selectedPairedID = mac.id
                    if let online { selectedMac = online }
                    Task { await pollLockStatus() }
                }
                .contextMenu {
                    Button("Remove pairing", role: .destructive) {
                        client.removePairing(id: mac.id)
                    }
                }
            }

            Button {
                Task { await unlockSelected() }
            } label: {
                Text((client.isBusy || actionInFlight) ? "Working…" : "Unlock selected Mac")
                    .font(.custom("AvenirNext-Bold", size: 18))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color(red: 0.85, green: 0.92, blue: 0.55))
                    .foregroundStyle(Color(red: 0.08, green: 0.12, blue: 0.10))
            }
            .disabled(client.isBusy || actionInFlight || selectedOnlineMac() == nil)

            Button {
                Task { await lockSelected() }
            } label: {
                Text((client.isBusy || actionInFlight) ? "Working…" : "Lock selected Mac")
                    .font(.custom("AvenirNext-Bold", size: 18))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
            }
            .disabled(client.isBusy || actionInFlight || selectedOnlineMac() == nil)

            if client.pairedMacs.count > 1 {
                Button("Remove all pairings") {
                    client.clearPairing()
                    showAddMac = true
                }
                .font(.custom("AvenirNext-Medium", size: 13))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
    }

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("VPN / Tailscale")
                .font(.custom("AvenirNext-DemiBold", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Text("When you’re not on the same Wi‑Fi, enter this Mac’s Tailscale IP or MagicDNS name. Save tests the connection first. Port \(UnlockService.tcpPort).")
                .font(.custom("AvenirNext-Regular", size: 12))
                .foregroundStyle(.white.opacity(0.45))

            if let selected = client.selectedPairedID,
               let paired = PairedMacStore.find(id: selected),
               let host = paired.remoteHost {
                Text("Saved: \(host):\(paired.resolvedRemotePort)")
                    .font(.custom("AvenirNext-Medium", size: 13))
                    .foregroundStyle(Color(red: 0.85, green: 0.92, blue: 0.55))
            }

            HStack {
                TextField("100.x.x.x or name.ts.net", text: $remoteHostDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                Button(client.isBusy ? "…" : "Save") {
                    Task { await saveRemoteHost() }
                }
                .disabled(client.selectedPairedID == nil || client.isBusy)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(red: 0.85, green: 0.92, blue: 0.55))
                .foregroundStyle(.black)
            }

            if client.selectedPairedID != nil {
                Button("Clear saved address") {
                    guard let id = client.selectedPairedID else { return }
                    try? client.saveRemoteHost("", forPairedID: id)
                    remoteHostDraft = ""
                    discovery.refresh()
                }
                .font(.custom("AvenirNext-Medium", size: 13))
                .foregroundStyle(.white.opacity(0.45))
            }
        }
        .onAppear {
            if let id = client.selectedPairedID,
               let host = PairedMacStore.find(id: id)?.remoteHost {
                remoteHostDraft = host
            }
        }
        .onChange(of: client.selectedPairedID) { _, id in
            remoteHostDraft = id.flatMap { PairedMacStore.find(id: $0)?.remoteHost } ?? ""
        }
    }

    private func saveRemoteHost() async {
        guard let id = client.selectedPairedID else {
            alertMessage = "Select a paired Mac first."
            return
        }
        do {
            try await client.testAndSaveRemoteHost(remoteHostDraft, forPairedID: id)
            discovery.refresh()
            if let host = PairedMacStore.find(id: id)?.remoteHost,
               let mac = client.remoteDiscoveredMac(
                host: host,
                port: PairedMacStore.find(id: id)?.resolvedRemotePort ?? UnlockService.tcpPort,
                name: PairedMacStore.find(id: id)?.name,
                deviceID: id
               ) {
                selectedMac = mac
            }
            if let parsed = UnlockClient.parseHostPort(remoteHostDraft) {
                remoteHostDraft = parsed.host
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private var nearbySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby")
                .font(.custom("AvenirNext-DemiBold", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            Text(discovery.status)
                .font(.custom("AvenirNext-Regular", size: 13))
                .foregroundStyle(.white.opacity(0.45))

            if discovery.peers.isEmpty {
                Text("Waiting for Mac…")
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ForEach(discovery.peers) { peer in
                    let paired = client.pairedMac(for: peer)
                    Button {
                        selectedMac = peer
                        if let paired { client.selectedPairedID = paired.id }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.name)
                                    .font(.custom("AvenirNext-Medium", size: 16))
                                Text(pairedSubtitle(for: peer, paired: paired != nil))
                                    .font(.custom("AvenirNext-Regular", size: 12))
                                    .foregroundStyle(peer.lockState == .locked
                                                     ? Color.orange.opacity(0.9)
                                                     : .white.opacity(0.45))
                            }
                            Spacer()
                            if selectedMac?.id == peer.id {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(selectedMac?.id == peer.id ? Color.white.opacity(0.16) : Color.white.opacity(0.06))
                        )
                    }
                }
            }
        }
        .onChange(of: discovery.peers) { _, peers in
            if selectedMac == nil {
                selectedMac = preferredPeer(from: peers)
            } else if let selected = selectedMac, !peers.contains(where: { $0.id == selected.id }) {
                selectedMac = preferredPeer(from: peers)
            }
            if let selected = selectedMac, let paired = client.pairedMac(for: selected) {
                client.selectedPairedID = paired.id
            }
        }
    }

    private var pairingControls: some View {
        VStack(spacing: 14) {
            Text(discovery.bluetoothOnly
                 ? "Pair over Bluetooth. Keep your phone near the Mac."
                 : "Select a nearby Mac, then scan the QR code or enter the PIN.")
                .font(.custom("AvenirNext-Regular", size: 15))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            Button {
                showScanner = true
            } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    .font(.custom("AvenirNext-Bold", size: 17))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
            }

            HStack {
                TextField("Or enter PIN", text: $manualPIN)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                Button("Pair") {
                    Task { await pairWithPIN(manualPIN) }
                }
                .disabled(manualPIN.count < 4 || selectedMac == nil || client.isBusy)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(red: 0.85, green: 0.92, blue: 0.55))
                .foregroundStyle(.black)
            }

            if client.isPaired {
                Button("Cancel") {
                    showAddMac = false
                    manualPIN = ""
                }
                .font(.custom("AvenirNext-Medium", size: 14))
                .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var footerStatus: some View {
        Text(client.message)
            .font(.custom("AvenirNext-Regular", size: 13))
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }

    private func pairedSubtitle(for peer: DiscoveredMac, paired: Bool) -> String {
        let prefix = paired ? "Paired" : "Not paired"
        switch peer.lockState {
        case .locked:
            return "\(prefix) · Locked · \(peer.transportLabel)"
        case .unlocked:
            return "\(prefix) · Unlocked · \(peer.transportLabel)"
        case .unknown:
            return "\(prefix) · \(peer.transportLabel)"
        }
    }

    private func displayedLockState(for pairedID: String, online: DiscoveredMac?) -> MacLockState {
        if let polled = client.lockStatusByID[pairedID] {
            return polled
        }
        return online?.lockState ?? .unknown
    }

    private func statusLine(lockState: MacLockState, online: DiscoveredMac?) -> String {
        guard online != nil || lockState != .unknown else { return "Not nearby" }
        let lock = lockState.label
        if let online {
            return "\(lock) · \(online.transportLabel)"
        }
        return lock
    }

    private func lockColor(_ state: MacLockState) -> Color {
        switch state {
        case .locked: return Color.orange.opacity(0.95)
        case .unlocked: return Color(red: 0.85, green: 0.92, blue: 0.55).opacity(0.9)
        case .unknown: return Color.white.opacity(0.45)
        }
    }

    private func pollLockStatus() async {
        guard let mac = selectedOnlineMac() else { return }
        await client.refreshLockStatus(mac: mac, bluetoothOnly: discovery.bluetoothOnly)
    }

    private func preferredPeer(from peers: [DiscoveredMac]) -> DiscoveredMac? {
        if let selected = client.selectedPairedID,
           let match = peers.first(where: { client.pairedMac(for: $0)?.id == selected }) {
            return match
        }
        if let pairedOnline = peers.first(where: { client.pairedMac(for: $0) != nil }) {
            return pairedOnline
        }
        if discovery.bluetoothOnly {
            return peers.first(where: { $0.bluetoothID != nil }) ?? peers.first
        }
        return peers.first
    }

    private func selectedOnlineMac() -> DiscoveredMac? {
        if let selected = selectedMac, client.pairedMac(for: selected) != nil {
            return selected
        }
        if let id = client.selectedPairedID {
            return discovery.peers.first(where: { client.pairedMac(for: $0)?.id == id })
        }
        return discovery.peers.first(where: { client.pairedMac(for: $0) != nil })
    }

    private func handleScanned(_ code: String) {
        guard let data = code.data(using: .utf8),
              let payload = try? ProtocolCodec.decode(PairingQRPayload.self, from: data) else {
            alertMessage = "That QR code isn’t a Latch pairing code."
            return
        }
        manualPIN = payload.pin
        showAddMac = true
        if let id = payload.id?.lowercased(),
           let match = discovery.peers.first(where: {
               $0.deviceIdentity?.lowercased() == id
               || DeviceIdentity.shortID(from: $0.deviceIdentity, name: $0.name)?.lowercased()
                   == DeviceIdentity.shortID(from: id, name: nil)?.lowercased()
           }) {
            selectedMac = match
        } else if let match = discovery.peers.first(where: { $0.name == payload.name }) {
            selectedMac = match
        } else if let host = payload.host,
                  let remote = client.remoteDiscoveredMac(
                    host: host,
                    port: payload.port ?? UnlockService.tcpPort,
                    name: payload.name,
                    deviceID: payload.id
                  ) {
            selectedMac = remote
            remoteHostDraft = host
        }
        Task { await pairWithPIN(payload.pin, qrHost: payload.host, qrPort: payload.port) }
    }

    private func pairWithPIN(_ pin: String, qrHost: String? = nil, qrPort: UInt16? = nil) async {
        guard let mac = selectedMac
                ?? preferredPeer(from: discovery.peers)
                ?? qrHost.flatMap({
                    client.remoteDiscoveredMac(
                        host: $0,
                        port: qrPort ?? UnlockService.tcpPort,
                        deviceID: nil
                    )
                }) else {
            alertMessage = discovery.bluetoothOnly
                ? "Select your Mac over Bluetooth, or turn off Bluetooth only to use Tailscale / VPN."
                : "Select your Mac, or scan a QR that includes a Tailscale / VPN address."
            return
        }
        do {
            try await client.pair(mac: mac, pin: pin, bluetoothOnly: discovery.bluetoothOnly)
            if let host = qrHost ?? (mac.viaRemote ? remoteHostDraft : nil),
               let id = client.selectedPairedID {
                try? client.saveRemoteHost(host, port: qrPort ?? UnlockService.tcpPort, forPairedID: id)
                remoteHostDraft = host
            }
            discovery.refresh()
            showAddMac = false
            manualPIN = ""
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func unlockSelected() async {
        guard !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        guard let mac = selectedOnlineMac() else {
            alertMessage = discovery.bluetoothOnly
                ? "Paired Mac not found over Bluetooth."
                : "Paired Mac not found nearby."
            return
        }
        do {
            let method: String
            if requireBiometric {
                method = try await BiometricGate.authenticate(reason: "Authenticate to unlock \(mac.name)")
            } else {
                method = "None"
            }
            try await client.unlock(mac: mac, method: method, bluetoothOnly: discovery.bluetoothOnly)
        } catch {
            if let message = BiometricGate.userFacingMessage(from: error) {
                alertMessage = message
            }
        }
    }

    private func lockSelected() async {
        guard !actionInFlight else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        guard let mac = selectedOnlineMac() else {
            alertMessage = discovery.bluetoothOnly
                ? "Paired Mac not found over Bluetooth."
                : "Paired Mac not found nearby."
            return
        }
        do {
            let method: String
            if requireBiometric {
                method = try await BiometricGate.authenticate(reason: "Authenticate to lock \(mac.name)")
            } else {
                method = "None"
            }
            try await client.lock(mac: mac, method: method, bluetoothOnly: discovery.bluetoothOnly)
        } catch {
            if let message = BiometricGate.userFacingMessage(from: error) {
                alertMessage = message
            }
        }
    }

    private func maybeUnlockOnLaunch(generation: Int) async {
        guard unlockOnLaunch, client.isPaired, !client.isBusy else { return }

        client.message = "Looking for selected Mac…"
        let deadline = Date().addingTimeInterval(8)
        while selectedOnlineMac() == nil, Date() < deadline {
            if generation != autoUnlockGeneration { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard generation == autoUnlockGeneration else { return }
        guard selectedOnlineMac() != nil else {
            client.message = "Selected Mac not nearby."
            return
        }
        await unlockSelected()
    }
}

// MARK: - QR Scanner

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var handled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handled,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        handled = true
        session.stopRunning()
        onCode?(value)
    }
}
