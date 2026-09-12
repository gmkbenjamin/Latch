import AppKit
import ApplicationServices

enum ScreenUnlocker {
    enum UnlockError: LocalizedError {
        case missingPassword
        case accessibilityDenied
        case injectionFailed
        case lockFailed

        var errorDescription: String? {
            switch self {
            case .missingPassword:
                return "Save your Mac login password in Latch first."
            case .accessibilityDenied:
                return "Enable Accessibility for Latch in System Settings → Privacy & Security → Accessibility."
            case .injectionFailed:
                return "Could not type the password into the lock screen."
            case .lockFailed:
                return "Could not lock the Mac screen."
            }
        }
    }

    enum UnlockOutcome: Sendable {
        case unlocked
        case alreadyUnlocked
    }

    enum LockOutcome: Sendable {
        case locked
        case alreadyLocked
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// True when the session lock screen is showing (not merely display sleep).
    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as NSDictionary? else {
            return false
        }
        if let locked = dict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        if let number = dict["CGSSessionScreenIsLocked"] as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Opens Privacy → Accessibility. Prefer letting the system prompt do this; use as a fallback.
    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.extension.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    static var runningAppURL: URL {
        Bundle.main.bundleURL
    }

    /// Copies this build to /Applications/Latch.app and relaunches from there (stable TCC path).
    @discardableResult
    static func installToApplicationsAndRelaunch() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/Latch.app")
        if source.standardizedFileURL == destination.standardizedFileURL {
            return destination
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
        NSWorkspace.shared.open(destination)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.terminate(nil)
        }
        return destination
    }

    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @discardableResult
    static func unlock() throws -> UnlockOutcome {
        guard isScreenLocked else {
            return .alreadyUnlocked
        }

        guard var password = try KeychainStore.string(account: KeychainStore.Key.loginPassword), !password.isEmpty else {
            throw UnlockError.missingPassword
        }
        // Strip accidental whitespace/newlines from SecureField / file reads.
        password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else {
            throw UnlockError.missingPassword
        }
        guard isAccessibilityTrusted else {
            requestAccessibilityPrompt()
            throw UnlockError.accessibilityDenied
        }

        // Wake display without holding modifiers (Shift was corrupting typed characters).
        wakeDisplay()
        Thread.sleep(forTimeInterval: 0.55)

        guard isScreenLocked else {
            return .alreadyUnlocked
        }

        // Clear any leftover characters from a failed attempt, then type the password fresh.
        clearPasswordField()
        Thread.sleep(forTimeInterval: 0.12)

        guard typeText(password) else { throw UnlockError.injectionFailed }
        Thread.sleep(forTimeInterval: 0.12)
        guard pressReturn() else { throw UnlockError.injectionFailed }
        return .unlocked
    }

    /// Locks the session via Control–Command–Q (same shortcut as Lock Screen).
    @discardableResult
    static func lock() throws -> LockOutcome {
        guard !isScreenLocked else {
            return .alreadyLocked
        }
        guard isAccessibilityTrusted else {
            requestAccessibilityPrompt()
            throw UnlockError.accessibilityDenied
        }
        guard pressLockShortcut() else {
            throw UnlockError.lockFailed
        }
        Thread.sleep(forTimeInterval: 0.4)
        return .locked
    }

    private static func wakeDisplay() {
        let src = CGEventSource(stateID: .hidSystemState)
        // Mouse nudge only — do not tap Shift/Option; sticky modifiers break password typing.
        let points = [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 40), CGPoint(x: 20, y: 20)]
        for point in points {
            let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
            move?.flags = []
            move?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.02)
        }
        // Click once so the lock-screen password field takes focus.
        if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 500, y: 500), mouseButton: .left),
           let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: 500, y: 500), mouseButton: .left) {
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private static func clearPasswordField() {
        // Cmd+A then Delete — avoids appending onto a half-typed wrong attempt.
        postKey(virtualKey: 0x00, flags: .maskCommand) // A
        Thread.sleep(forTimeInterval: 0.04)
        postKey(virtualKey: 0x33, flags: []) // Delete
    }

    private static func typeText(_ text: String) -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        // Prefer whole-string unicode injection; per-scalar + virtualKey 0 is flaky on the lock screen.
        var utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return true }
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func pressReturn() -> Bool {
        postKey(virtualKey: 36, flags: [])
        return true
    }

    private static func pressLockShortcut() -> Bool {
        postKey(virtualKey: 0x0C, flags: [.maskControl, .maskCommand]) // Q
        return true
    }

    private static func postKey(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
