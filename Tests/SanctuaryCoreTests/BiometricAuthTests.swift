// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import LocalAuthentication
import Testing
@testable import SanctuaryMenuBar

@Suite(.serialized)
struct BiometricAuthTests {
    @Test func biometricSuccessAuthorizesAction() async {
        let recorder = BiometricRecorder()
        await withMockAuth(
            context: MockBiometricContext(canBiometric: true, canOwner: true, success: true, recorder: recorder)
        ) {
            let confirmed = await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/.ssh")

            #expect(confirmed)
            #expect(recorder.evaluateCount == 1)
        }
    }

    @Test func biometricFailureDoesNotAuthorizeAction() async {
        await withMockAuth(
            context: MockBiometricContext(canBiometric: true, canOwner: true, success: false)
        ) {
            let confirmed = await BiometricAuth.confirm(reason: "Confirm to remove protection from MetaMask")

            #expect(!confirmed)
        }
    }

    @Test func ownerAuthenticationFallbackIsUsedWhenBiometricsUnavailable() async {
        let recorder = BiometricRecorder()
        await withMockAuth(
            context: MockBiometricContext(
                canBiometric: false,
                canOwner: true,
                success: true,
                recorder: recorder
            )
        ) {
            let confirmed = await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/Documents")

            #expect(confirmed)
            #expect(recorder.evaluatedPolicy == .deviceOwnerAuthentication)
        }
    }

    @Test func authorizationWindowAvoidsRepeatPrompt() async {
        let clock = TestClock(date: Date(timeIntervalSince1970: 100))
        let recorder = BiometricRecorder()
        await withMockAuth(
            context: MockBiometricContext(canBiometric: true, canOwner: true, success: true, recorder: recorder),
            now: { clock.date }
        ) {
            #expect(await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/.aws"))
            clock.date = Date(timeIntervalSince1970: 120)
            #expect(await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/.aws"))

            #expect(recorder.evaluateCount == 1)
        }
    }

    @Test func resetAuthorizationWindowForcesPromptAgain() async {
        let recorder = BiometricRecorder()
        await withMockAuth(
            context: MockBiometricContext(canBiometric: true, canOwner: true, success: true, recorder: recorder)
        ) {
            #expect(await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/.gnupg"))
            BiometricAuth.resetAuthorizationWindow()
            #expect(await BiometricAuth.confirm(reason: "Confirm to remove protection from ~/.gnupg"))

            #expect(recorder.evaluateCount == 2)
        }
    }

    private func withMockAuth(
        context: MockBiometricContext,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) },
        body: () async -> Void
    ) async {
        let oldFactory = BiometricAuth.contextFactory
        let oldNow = BiometricAuth.now
        BiometricAuth.contextFactory = { context }
        BiometricAuth.now = now
        BiometricAuth.resetAuthorizationWindow()
        defer {
            BiometricAuth.contextFactory = oldFactory
            BiometricAuth.now = oldNow
            BiometricAuth.resetAuthorizationWindow()
        }
        await body()
    }
}

private final class MockBiometricContext: BiometricAuthenticating, @unchecked Sendable {
    let canBiometric: Bool
    let canOwner: Bool
    let success: Bool
    let recorder: BiometricRecorder?

    init(
        canBiometric: Bool,
        canOwner: Bool,
        success: Bool,
        recorder: BiometricRecorder? = nil
    ) {
        self.canBiometric = canBiometric
        self.canOwner = canOwner
        self.success = success
        self.recorder = recorder
    }

    func canEvaluate(_ policy: LAPolicy) -> Bool {
        switch policy {
        case .deviceOwnerAuthenticationWithBiometrics:
            return canBiometric
        case .deviceOwnerAuthentication:
            return canOwner
        default:
            return false
        }
    }

    func evaluate(_ policy: LAPolicy, reason: String) async -> Bool {
        recorder?.record(policy: policy)
        return success
    }
}

private final class BiometricRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var policy: LAPolicy?

    var evaluateCount: Int {
        lock.withLock { count }
    }

    var evaluatedPolicy: LAPolicy? {
        lock.withLock { policy }
    }

    func record(policy: LAPolicy) {
        lock.withLock {
            count += 1
            self.policy = policy
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(date: Date) {
        self.storage = date
    }

    var date: Date {
        get {
            lock.withLock { storage }
        }
        set {
            lock.withLock {
                storage = newValue
            }
        }
    }
}
