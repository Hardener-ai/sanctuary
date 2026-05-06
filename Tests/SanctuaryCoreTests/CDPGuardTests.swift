// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Testing
@testable import SanctuaryCore

struct CDPGuardTests {
    @Test func startSetsIsRunning() throws {
        let guardInstance = CDPGuard(
            classifier: AgentClassifier(),
            attributor: PeerProcessAttributor(proc: EmptyDarwinProc()),
            pfAnchorManager: NoopPFAnchorManager(),
            proxyPort: 0
        )

        try guardInstance.start()

        #expect(guardInstance.isRunning)
    }

    @Test func stopClearsIsRunning() throws {
        let guardInstance = CDPGuard(
            classifier: AgentClassifier(),
            attributor: PeerProcessAttributor(proc: EmptyDarwinProc()),
            pfAnchorManager: NoopPFAnchorManager(),
            proxyPort: 0
        )

        try guardInstance.start()
        guardInstance.stop()

        #expect(!guardInstance.isRunning)
    }

    @Test func doubleStartThrows() throws {
        let guardInstance = CDPGuard(
            classifier: AgentClassifier(),
            attributor: PeerProcessAttributor(proc: EmptyDarwinProc()),
            pfAnchorManager: NoopPFAnchorManager(),
            proxyPort: 0
        )

        try guardInstance.start()

        #expect(throws: CDPGuardError.alreadyRunning) {
            try guardInstance.start()
        }
    }
}

private struct EmptyDarwinProc: DarwinProcProviding {
    func listPIDs() throws -> [pid_t] {
        []
    }

    func listFileDescriptors(pid: pid_t) throws -> [ProcessFileDescriptor] {
        []
    }

    func socketInfo(pid: pid_t, fd: Int32) throws -> ProcessSocketInfo? {
        nil
    }
}

private final class NoopPFAnchorManager: PFAnchorManaging, @unchecked Sendable {
    private(set) var isInstalled = false

    func ensurePFEnabled() throws {}

    func install(redirects: [PFAnchorManager.Redirect]) throws {
        isInstalled = true
    }

    func uninstall() throws {
        isInstalled = false
    }
}
