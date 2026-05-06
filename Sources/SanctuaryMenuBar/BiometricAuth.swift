// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import Foundation
import LocalAuthentication

protocol BiometricAuthenticating: Sendable {
    func canEvaluate(_ policy: LAPolicy) -> Bool
    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool
}

enum BiometricAuth {
    static var contextFactory: @Sendable () -> any BiometricAuthenticating = {
        SystemBiometricContext()
    }
    static var now: @Sendable () -> Date = { Date() }

    private static let lock = NSLock()
    private static var authorizedUntil: Date?

    static func confirm(reason: String) async -> Bool {
        if isWithinAuthorizationWindow() {
            return true
        }

        let context = contextFactory()
        let policy: LAPolicy
        if context.canEvaluate(.deviceOwnerAuthenticationWithBiometrics) {
            policy = .deviceOwnerAuthenticationWithBiometrics
        } else if context.canEvaluate(.deviceOwnerAuthentication) {
            policy = .deviceOwnerAuthentication
        } else {
            await showUnavailableAlert()
            return false
        }

        let success = await context.evaluate(policy, reason: reason)
        if success {
            rememberAuthorizationWindow()
        }
        return success
    }

    static func resetAuthorizationWindow() {
        lock.withLock {
            authorizedUntil = nil
        }
    }

    private static func isWithinAuthorizationWindow() -> Bool {
        lock.withLock {
            guard let authorizedUntil else {
                return false
            }
            return authorizedUntil > now()
        }
    }

    private static func rememberAuthorizationWindow() {
        lock.withLock {
            authorizedUntil = now().addingTimeInterval(30)
        }
    }

    @MainActor
    private static func showUnavailableAlert() {
        let alert = NSAlert()
        alert.messageText = "Touch ID is unavailable"
        alert.informativeText = "Sanctuary did not change this protection."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct SystemBiometricContext: BiometricAuthenticating {
    func canEvaluate(_ policy: LAPolicy) -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(policy, error: &error)
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool {
        let context = LAContext()
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
