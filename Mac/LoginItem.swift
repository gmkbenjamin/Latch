import Foundation
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Latch starts when you log in."
        case .requiresApproval:
            return "Allowed in System Settings → General → Login Items."
        case .notFound:
            return "Install Latch to /Applications first, then enable this."
        case .notRegistered:
            return "Starts after you log in to this Mac user."
        @unknown default:
            return "Starts after you log in to this Mac user."
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
