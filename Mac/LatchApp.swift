import SwiftUI
import CoreImage.CIFilterBuiltins
import ServiceManagement
import AppKit

@main
struct LatchApp: App {
    @StateObject private var server = UnlockServer()
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text("Latch")
                    .font(.headline)
                Label(
                    server.isScreenLocked ? "Mac is locked" : "Mac is unlocked",
                    systemImage: server.isScreenLocked ? "lock.fill" : "lock.open"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(server.isScreenLocked ? .orange : .green)
                Text(server.lastEvent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !server.bleStatus.isEmpty {
                    Text(server.bleStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !server.bluetoothOnly, !server.reachabilityLines.isEmpty {
                    Text("Reachable at")
                        .font(.caption.weight(.semibold))
                        .padding(.top, 2)
                    ForEach(server.reachabilityLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("Use a Tailscale IP / MagicDNS name on iPhone when not on the same Wi‑Fi.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                if server.pairedDeviceName == nil {
                    Text("Pairing PIN")
                        .font(.caption.weight(.semibold))
                    Text(server.pairingPIN)
                        .font(.system(.title, design: .monospaced).weight(.bold))
                    QRCodeView(string: server.pairingQRJSON)
                        .frame(width: 160, height: 160)
                        .padding(.vertical, 4)
                    Text("Scan with the Latch app on iPhone/iPad.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Paired and ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Button("Reset Pairing") {
                        server.resetPairing()
                    }
                }

                Divider()

                SecureField("Mac login password", text: $appModel.passwordDraft)
                    .textFieldStyle(.roundedBorder)
                Button(appModel.passwordSaved ? "Update Password" : "Save Password") {
                    appModel.savePassword()
                }
                .disabled(appModel.passwordDraft.isEmpty)
                if !appModel.passwordSaved {
                    Text("Re-save your Mac password once after this update.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if appModel.accessibilityTrusted {
                    Label("Accessibility enabled", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("Request Accessibility Access…") {
                            // Only the system prompt — opening Settings at the same time
                            // races TCC and often leaves Latch missing from the list.
                            ScreenUnlocker.requestAccessibilityPrompt()
                        }
                        Button("Open Accessibility Settings") {
                            ScreenUnlocker.openAccessibilitySettings()
                        }
                        Button("Show Latch in Finder") {
                            ScreenUnlocker.revealAppInFinder()
                        }
                        if !ScreenUnlocker.isInstalledInApplications {
                            Button("Install to Applications & Relaunch") {
                                do {
                                    _ = try ScreenUnlocker.installToApplicationsAndRelaunch()
                                } catch {
                                    appModel.accessibilityHint = "Could not install: \(error.localizedDescription)"
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Text(appModel.accessibilityHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider()

                Toggle("Bluetooth only", isOn: $server.bluetoothOnly)
                Text(server.bluetoothOnly
                     ? "Wi‑Fi unlock is disabled. Phone must be nearby."
                     : "Accepts unlock over Wi‑Fi and Bluetooth.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Open at login", isOn: Binding(
                    get: { appModel.openAtLogin },
                    set: { appModel.setOpenAtLogin($0) }
                ))
                Text(appModel.openAtLoginDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Listen for unlock requests", isOn: Binding(
                    get: { server.isRunning },
                    set: { on in
                        if on { server.start() } else { server.stop() }
                    }
                ))

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(14)
            .frame(width: 300)
            .onAppear {
                appModel.reload()
                if !server.isRunning {
                    server.start()
                }
                server.refreshLockState()
            }
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                server.refreshBLEStatus()
                server.refreshLockState()
                server.refreshReachability()
                appModel.refreshAccessibility()
                appModel.refreshOpenAtLogin()
            }
        } label: {
            Image(systemName: server.isScreenLocked ? "lock.fill" : "lock.open")
                .symbolRenderingMode(.hierarchical)
                .accessibilityLabel(server.isScreenLocked ? "Latch — Mac locked" : "Latch — Mac unlocked")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var passwordDraft = ""
    @Published var passwordSaved = false
    @Published var accessibilityTrusted = ScreenUnlocker.isAccessibilityTrusted
    @Published var openAtLogin = LoginItem.isEnabled
    @Published var openAtLoginDetail = LoginItem.statusDescription
    @Published var accessibilityHint = """
        Click Request Accessibility Access, then Open System Settings from that dialog. \
        If Latch still isn’t listed, use Install to Applications & Relaunch, then in Accessibility click + and choose /Applications/Latch.app.
        """

    func reload() {
        passwordSaved = (try? KeychainStore.string(account: KeychainStore.Key.loginPassword))?.isEmpty == false
        refreshAccessibility()
        refreshOpenAtLogin()
    }

    func refreshAccessibility() {
        let trusted = ScreenUnlocker.isAccessibilityTrusted
        if trusted != accessibilityTrusted {
            accessibilityTrusted = trusted
        }
    }

    func refreshOpenAtLogin() {
        let enabled = LoginItem.isEnabled
        if enabled != openAtLogin {
            openAtLogin = enabled
        }
        let detail = LoginItem.statusDescription
        if detail != openAtLoginDetail {
            openAtLoginDetail = detail
        }
    }

    func setOpenAtLogin(_ enabled: Bool) {
        if enabled, !ScreenUnlocker.isInstalledInApplications {
            openAtLoginDetail = "Install Latch to /Applications first (button above), then enable Open at login."
            openAtLogin = false
            return
        }
        if let error = LoginItem.setEnabled(enabled) {
            openAtLoginDetail = error
            openAtLogin = LoginItem.isEnabled
            return
        }
        openAtLogin = LoginItem.isEnabled
        openAtLoginDetail = LoginItem.statusDescription
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            openAtLoginDetail = "Turn on Latch under System Settings → General → Login Items."
        }
    }

    func savePassword() {
        let trimmed = passwordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? KeychainStore.setString(trimmed, account: KeychainStore.Key.loginPassword)
        passwordDraft = ""
        passwordSaved = true
    }
}

struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.makeQR(from: string) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    private static func makeQR(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
