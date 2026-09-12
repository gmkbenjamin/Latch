import Foundation
import LocalAuthentication

enum BiometricGate {
    enum AuthError: LocalizedError {
        case failed(String)
        case unavailable

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            case .unavailable: return "Face ID / Touch ID / passcode is unavailable."
            }
        }
    }

    static func authenticate(reason: String) async throws -> String {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw AuthError.unavailable
        }

        let method: String
        switch context.biometryType {
        case .faceID: method = "Face ID"
        case .touchID: method = "Touch ID"
        case .opticID: method = "Optic ID"
        default: method = "Passcode"
        }

        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard success else { throw AuthError.failed("Authentication was cancelled.") }
            return method
        } catch {
            throw AuthError.failed(error.localizedDescription)
        }
    }
}
