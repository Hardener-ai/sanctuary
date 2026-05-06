// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryMenuBar

@Suite(.serialized)
struct DaemonInstallationTests {
    @Test func installCallsServiceRegister() async throws {
        let service = MockDaemonService(statusDescription: "notRegistered")
        try await withMockDaemonService(service) {
            try await DaemonInstallation.install()
        }

        #expect(service.registerCount == 1)
        #expect(service.unregisterCount == 0)
    }

    @Test func uninstallCallsServiceUnregister() async throws {
        let service = MockDaemonService(statusDescription: "enabled")
        try await withMockDaemonService(service) {
            try await DaemonInstallation.uninstall()
        }

        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 1)
    }

    @Test func statusDetectionCoversNotInstalled() {
        #expect(DaemonInstallation.status(for: "notRegistered", daemonRunning: false) == .notInstalled)
        #expect(DaemonInstallation.status(for: "notFound", daemonRunning: false) == .notInstalled)
    }

    @Test func statusDetectionCoversInstalledRunningAndStarting() {
        #expect(DaemonInstallation.status(for: "enabled", daemonRunning: true) == .installed(running: true))
        #expect(DaemonInstallation.status(for: "enabled", daemonRunning: false) == .installed(running: false))
    }

    @Test func statusDetectionSurfacesRequiresApproval() {
        #expect(DaemonInstallation.status(for: "requiresApproval", daemonRunning: false) == .requiresApproval)
        #expect(DaemonInstallation.status(for: "requires approval", daemonRunning: true) == .requiresApproval)
    }

    @Test func currentStatusUsesMockedServiceAndDaemonRunningCheck() {
        let service = MockDaemonService(statusDescription: "enabled")
        withMockDaemonServiceSync(service, daemonRunning: { false }) {
            #expect(DaemonInstallation.currentStatus() == .installed(running: false))
        }
    }
}

private final class MockDaemonService: DaemonServiceManaging, @unchecked Sendable {
    let statusDescription: String
    private let lock = NSLock()
    private var registers = 0
    private var unregisters = 0

    init(statusDescription: String) {
        self.statusDescription = statusDescription
    }

    var registerCount: Int {
        lock.withLock { registers }
    }

    var unregisterCount: Int {
        lock.withLock { unregisters }
    }

    func register() throws {
        lock.withLock {
            registers += 1
        }
    }

    func unregister() throws {
        lock.withLock {
            unregisters += 1
        }
    }
}

private func withMockDaemonService<T>(
    _ service: MockDaemonService,
    daemonRunning: @escaping @Sendable () -> Bool = { true },
    _ body: () async throws -> T
) async rethrows -> T {
    let oldFactory = DaemonInstallation.serviceFactory
    let oldRunning = DaemonInstallation.daemonRunning
    DaemonInstallation.serviceFactory = { service }
    DaemonInstallation.daemonRunning = daemonRunning
    defer {
        DaemonInstallation.serviceFactory = oldFactory
        DaemonInstallation.daemonRunning = oldRunning
    }
    return try await body()
}

private func withMockDaemonServiceSync<T>(
    _ service: MockDaemonService,
    daemonRunning: @escaping @Sendable () -> Bool = { true },
    _ body: () throws -> T
) rethrows -> T {
    let oldFactory = DaemonInstallation.serviceFactory
    let oldRunning = DaemonInstallation.daemonRunning
    DaemonInstallation.serviceFactory = { service }
    DaemonInstallation.daemonRunning = daemonRunning
    defer {
        DaemonInstallation.serviceFactory = oldFactory
        DaemonInstallation.daemonRunning = oldRunning
    }
    return try body()
}
