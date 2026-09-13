import Foundation
import LocalAuthentication

enum BiometricGate {
    enum AuthError: LocalizedError {
        case failed(String)
        case unavailable
        case biometricsUnavailable
        case cancelled

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            case .unavailable: return "Face ID / Touch ID / passcode is unavailable."
            case .biometricsUnavailable: return "Face ID or Touch ID is required to turn this off."
            case .cancelled: return nil
            }
        }
    }

    static func authenticate(reason: String, biometricsOnly: Bool = false) async throws -> String {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = biometricsOnly
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw biometricsOnly ? AuthError.biometricsUnavailable : AuthError.unavailable
        }

        if biometricsOnly {
            context.localizedFallbackTitle = ""
        }

        let method: String
        switch context.biometryType {
        case .faceID: method = "Face ID"
        case .touchID: method = "Touch ID"
        case .opticID: method = "Optic ID"
        default: method = "Passcode"
        }

        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            guard success else { throw AuthError.cancelled }
            return method
        } catch let auth as AuthError {
            throw auth
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback, .invalidContext, .notInteractive:
                throw AuthError.cancelled
            default:
                throw AuthError.failed(laError.localizedDescription)
            }
        } catch {
            throw AuthError.failed(error.localizedDescription)
        }
    }

    /// Nil means the user (or a newer prompt) dismissed Face ID — do not show an alert.
    static func userFacingMessage(from error: Error) -> String? {
        if let auth = error as? AuthError {
            switch auth {
            case .cancelled:
                return nil
            case .failed(let message):
                return message
            case .unavailable, .biometricsUnavailable:
                return auth.errorDescription
            }
        }
        if let laError = error as? LAError {
            switch laError.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback, .invalidContext, .notInteractive:
                return nil
            default:
                break
            }
        }
        return error.localizedDescription
    }
}
