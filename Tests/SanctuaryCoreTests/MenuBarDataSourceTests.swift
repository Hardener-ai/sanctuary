// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Testing
import SanctuaryCore
@testable import SanctuaryMenuBar

@Suite(.serialized)
struct MenuBarDataSourceTests {
    @Test func emptyRegistriesReturnEmptyArrays() {
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            installationStatusLoader: { .notInstalled }
        )

        source.refresh()

        #expect(source.folders.isEmpty)
        #expect(source.extensions.isEmpty)
        #expect(source.agents.isEmpty)
        #expect(source.status == .inactive)
    }

    @Test func populatedRegistriesReturnDisplayEntries() {
        let source = MenuBarDataSource(
            folderLoader: {
                [
                    ProtectedFolder(path: "\(NSHomeDirectory())/.ssh", addedAt: 0, source: "default")
                ]
            },
            extensionLoader: {
                [
                    ProtectedExtension(
                        profilePath: "\(NSHomeDirectory())/Library/Application Support/BraveSoftware/Brave-Browser/Default",
                        extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                        friendlyName: "MetaMask",
                        addedAt: 0
                    )
                ]
            },
            inventoryLoader: { [Self.inventoryEntry()] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" }
        )

        source.refresh()

        #expect(source.folders == [.init(path: "\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh", source: "default")])
        #expect(source.extensions == [
            .init(
                profilePath: "\(NSHomeDirectory())/Library/Application Support/BraveSoftware/Brave-Browser/Default",
                extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                friendlyName: "MetaMask",
                profile: "Brave Default"
            )
        ])
        #expect(source.agents.map(\.displayName) == ["Codex CLI"])
        #expect(source.status == .active)
    }

    @Test func statusComputationCoversActiveInactiveAndNoDaemon() {
        #expect(MenuBarDataSource.computeStatus(protectedCount: 0, daemonRunning: false) == .inactive)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 2, daemonRunning: true) == .active)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 1, daemonRunning: false) == .noDaemon)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 1, daemonRunning: false, installationStatus: .installed(running: false)) == .starting)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 1, daemonRunning: true, installationStatus: .requiresApproval) == .requiresApproval)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 1, daemonRunning: true, installationStatus: .notInstalled) == .inactive)
        #expect(MenuBarDataSource.computeStatus(protectedCount: 0, daemonRunning: true, installationStatus: .installed(running: true)) == .active)
    }

    @Test func lastDenialAtReadsNewestDetectAlertFromAuditLog() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audit = root.appendingPathComponent("audit.log")
        try """
        {"action":"DETECT_ALERT","ts":"2026-05-05T08:01:00.000Z"},"sig":"old"
        {"action":"ALLOW","ts":"2026-05-05T08:02:00.000Z"},"sig":"ignore"
        {"action":"DETECT_ALERT","ts":"2026-05-05T08:03:00.000Z"},"sig":"new"
        """.write(to: audit, atomically: true, encoding: .utf8)

        let date = try #require(MenuBarDataSource.mostRecentDetectAlert(in: audit.path))
        #expect(Int(date.timeIntervalSince1970) == 1_777_968_180)
    }

    @Test func refreshLoadsCachedActivitiesAndRecentDenial() {
        let denied = ActivityEntry(
            timestamp: Date(timeIntervalSince1970: 20),
            relativeTimeText: "just now",
            summaryText: "Codex CLI tried to attach to Brave",
            attributionText: "Blocked",
            isDenial: true
        )
        let detected = ActivityEntry(
            timestamp: Date(timeIntervalSince1970: 10),
            relativeTimeText: "1 minute ago",
            summaryText: "Codex CLI accessed ~/.ssh",
            attributionText: "Detected · definite",
            isDenial: false
        )
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            activityLoader: { [detected, denied] }
        )

        source.refresh()

        #expect(source.activities == [detected, denied])
        #expect(source.lastDenialAt == denied.timestamp)
    }

    @Test func inventorySnapshotLoadsFromJSONWithoutLiveRefresh() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("inventory.json")
        let data = try JSONEncoder.iso8601.encode([Self.inventoryEntry(pid: 101, displayName: "Hermes Agent (Nous Research)")])
        try data.write(to: snapshot)

        let entries = MenuBarDataSource.loadInventorySnapshot(path: snapshot.path)

        #expect(entries.map(\.pid) == [101])
        #expect(entries.map(\.displayName) == ["Hermes Agent (Nous Research)"])
    }

    @Test func profileDisplayNameCoversAdditionalChromiumBrowsers() {
        #expect(MenuBarDataSource.profileDisplayName(for: "/Users/tg/Library/Application Support/Microsoft Edge/Default") == "Edge Default")
        #expect(MenuBarDataSource.profileDisplayName(for: "/Users/tg/Library/Application Support/Vivaldi/Profile 1") == "Vivaldi Profile 1")
        #expect(MenuBarDataSource.profileDisplayName(for: "/Users/tg/Library/Application Support/com.operasoftware.Opera") == "Opera Default")
    }

    @Test func honorsDatabasePathEnvironmentOverride() throws {
        try Self.withTemporaryEnvironment { root in
            let db = root.appendingPathComponent("policy.sqlite").path
            setenv("SANCTUARY_DB_PATH", db, 1)
            try ProtectedFolderRegistry().protect(path: "/tmp/sanctuary-menu-folder", source: "user")
            try ProtectedExtensionRegistry().protect(
                profilePath: "\(root.path)/Library/Application Support/Google/Chrome/Profile 1",
                extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                friendlyName: "MetaMask"
            )

            let source = MenuBarDataSource()
            source.refresh()

            #expect(source.folders.map(\.displayPath) == ["/tmp/sanctuary-menu-folder"])
            #expect(source.extensions.map(\.profile) == ["Chrome Profile 1"])
        }
    }

    @Test func autoRefreshFiresOnSchedule() {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var refreshCount = 0
        let source = MenuBarDataSource(
            folderLoader: {
                lock.lock()
                refreshCount += 1
                lock.unlock()
                semaphore.signal()
                return []
            },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" }
        )

        source.startAutoRefresh(interval: 0.02)
        defer { source.stop() }

        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        #expect(semaphore.wait(timeout: .now() + 1) == .success)
        lock.lock()
        let count = refreshCount
        lock.unlock()
        #expect(count >= 2)
    }

    @Test func protectFolderMutationAddsRegistryRowAndRefreshes() async throws {
        try await Self.withTemporaryEnvironment { root in
            let db = root.appendingPathComponent("policy.sqlite").path
            setenv("SANCTUARY_DB_PATH", db, 1)
            let source = MenuBarDataSource()

            try await source.protectFolder("/tmp/sanctuary-menu-added-folder")

            #expect(source.folders.map(\.path) == ["/tmp/sanctuary-menu-added-folder"])
            #expect(try ProtectedFolderRegistry().list().map(\.path) == ["/tmp/sanctuary-menu-added-folder"])
        }
    }

    @Test func unprotectFolderMutationRemovesRegistryRowAndRefreshes() async throws {
        try await Self.withTemporaryEnvironment { root in
            let db = root.appendingPathComponent("policy.sqlite").path
            setenv("SANCTUARY_DB_PATH", db, 1)
            try ProtectedFolderRegistry().protect(path: "/tmp/sanctuary-menu-remove-folder", source: "user")
            let source = MenuBarDataSource()
            source.refresh()

            try await source.unprotectFolder("/tmp/sanctuary-menu-remove-folder")

            #expect(source.folders.isEmpty)
            #expect(try ProtectedFolderRegistry().list().isEmpty)
        }
    }

    @Test func protectExtensionMutationAddsRegistryRowAndRefreshes() async throws {
        try await Self.withTemporaryEnvironment { root in
            let db = root.appendingPathComponent("policy.sqlite").path
            setenv("SANCTUARY_DB_PATH", db, 1)
            let profile = root.appendingPathComponent("Chrome/Default").path
            let source = MenuBarDataSource()

            try await source.protectExtension(
                InstalledBrowserExtension(
                    profilePath: profile,
                    extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                    friendlyName: "MetaMask"
                )
            )

            #expect(source.extensions.map(\.friendlyName) == ["MetaMask"])
            #expect(try ProtectedExtensionRegistry().list().map(\.extensionID) == ["nkbihfbeogaeaoehlefnkodbefgpgknn"])
        }
    }

    @Test func unprotectExtensionMutationRemovesRegistryRowAndRefreshes() async throws {
        try await Self.withTemporaryEnvironment { root in
            let db = root.appendingPathComponent("policy.sqlite").path
            setenv("SANCTUARY_DB_PATH", db, 1)
            let profile = root.appendingPathComponent("Chrome/Default").path
            try ProtectedExtensionRegistry().protect(
                profilePath: profile,
                extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                friendlyName: "MetaMask"
            )
            let source = MenuBarDataSource()
            source.refresh()

            try await source.unprotectExtension(
                .init(
                    profilePath: profile,
                    extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
                    friendlyName: "MetaMask",
                    profile: "Chrome Default"
                )
            )

            #expect(source.extensions.isEmpty)
            #expect(try ProtectedExtensionRegistry().list().isEmpty)
        }
    }

    @Test func enableProtectionInstallsDaemonAndRefreshesStatus() async throws {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var installed = false
        }
        let state = State()
        let source = MenuBarDataSource(
            folderLoader: {
                [ProtectedFolder(path: "/tmp/sanctuary-protected", addedAt: 0, source: "user")]
            },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            installationStatusLoader: {
                state.lock.withLock {
                    state.installed ? .installed(running: true) : .notInstalled
                }
            },
            installProtection: {
                state.lock.withLock {
                    state.installed = true
                }
            }
        )

        try await source.enableProtection()

        #expect(source.protectionEnabled)
        #expect(source.installationStatus == .installed(running: true))
        #expect(source.status == .active)
    }

    @Test func disableProtectionUnregistersDaemonAndRefreshesStatus() async throws {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var installed = true
        }
        let state = State()
        let source = MenuBarDataSource(
            folderLoader: {
                [ProtectedFolder(path: "/tmp/sanctuary-protected", addedAt: 0, source: "user")]
            },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            installationStatusLoader: {
                state.lock.withLock {
                    state.installed ? .installed(running: true) : .notInstalled
                }
            },
            uninstallProtection: {
                state.lock.withLock {
                    state.installed = false
                }
            }
        )

        source.refresh()
        try await source.disableProtection()

        #expect(!source.protectionEnabled)
        #expect(source.installationStatus == .notInstalled)
        #expect(source.status == .inactive)
    }

    @Test func requiresApprovalStatusKeepsProtectionToggleOn() {
        #expect(MenuBarDataSource.protectionEnabled(for: .requiresApproval))
        #expect(MenuBarDataSource.protectionEnabled(for: .installed(running: false)))
        #expect(!MenuBarDataSource.protectionEnabled(for: .notInstalled))
    }

    @Test func emptyInventoryProducesNoAgentGroups() {
        #expect(MenuBarDataSource.groupAgents([]).isEmpty)
    }

    @Test func singleRootAgentProducesOneGroup() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 10, displayName: "Codex CLI", category: .foregroundCoding, verdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium))
        ])

        #expect(groups == [
            AgentGroup(
                rootIdentity: "Codex CLI",
                category: .foregroundCoding,
                processCount: 1,
                representativePid: 10,
                representativeVerdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium)
            )
        ])
    }

    @Test func rootWithTwoParentChainChildrenProducesOneGroup() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 10, displayName: "Codex CLI", category: .foregroundCoding, verdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium)),
            Self.inventoryEntry(pid: 11, displayName: "bash", category: .foregroundCoding, verdict: .agent(reason: .parentChain("Codex CLI"), confidence: .medium), parentPid: 10, parentDisplayName: "Codex CLI"),
            Self.inventoryEntry(pid: 12, displayName: "python3.11", category: .foregroundCoding, verdict: .agent(reason: .parentChain("Codex CLI"), confidence: .medium), parentPid: 11, parentDisplayName: "bash")
        ])

        #expect(groups.count == 1)
        #expect(groups.first?.rootIdentity == "Codex CLI")
        #expect(groups.first?.processCount == 3)
    }

    @Test func twoRootAgentsWithChildrenProduceTwoGroups() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 10, displayName: "Codex CLI", category: .foregroundCoding, verdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium)),
            Self.inventoryEntry(pid: 11, displayName: "bash", category: .foregroundCoding, verdict: .agent(reason: .parentChain("Codex CLI"), confidence: .medium), parentPid: 10, parentDisplayName: "Codex CLI"),
            Self.inventoryEntry(pid: 20, displayName: "Hermes Agent (Nous Research)", category: .backgroundService, verdict: .agent(reason: .serviceLaunch, confidence: .high)),
            Self.inventoryEntry(pid: 21, displayName: "python3.11", category: .backgroundService, verdict: .agent(reason: .parentChain("python3.11"), confidence: .high), parentPid: 20, parentDisplayName: "Hermes Agent (Nous Research)")
        ])

        #expect(groups.map(\.rootIdentity).sorted() == ["Codex CLI", "Hermes Agent (Nous Research)"])
        #expect(groups.map(\.processCount).sorted() == [2, 2])
    }

    @Test func hermesStyleFixtureGroupsPythonChildUnderRoot() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 58639, displayName: "Hermes Agent (Nous Research)", category: .backgroundService, verdict: .agent(reason: .serviceLaunch, confidence: .high)),
            Self.inventoryEntry(pid: 75940, displayName: "python3.11", category: .backgroundService, verdict: .agent(reason: .parentChain("python3.11"), confidence: .high), parentPid: 58639, parentDisplayName: "Hermes Agent (Nous Research)")
        ])

        #expect(groups.count == 1)
        #expect(groups.first?.rootIdentity == "Hermes Agent (Nous Research)")
        #expect(groups.first?.processCount == 2)
    }

    @Test func openClawStyleFixtureKeepsSeparateRootsAndGroupsChildren() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 69601, displayName: "OpenClaw", category: .backgroundService, verdict: .agent(reason: .serviceLaunch, confidence: .high)),
            Self.inventoryEntry(pid: 69602, displayName: "bash", category: .backgroundService, verdict: .agent(reason: .parentChain("bash"), confidence: .high), parentPid: 69601, parentDisplayName: "OpenClaw"),
            Self.inventoryEntry(pid: 73573, displayName: "OpenClaw", category: .backgroundService, verdict: .agent(reason: .serviceLaunch, confidence: .high)),
            Self.inventoryEntry(pid: 73574, displayName: "bash", category: .backgroundService, verdict: .agent(reason: .parentChain("bash"), confidence: .high), parentPid: 73573, parentDisplayName: "OpenClaw")
        ])

        #expect(groups.count == 2)
        #expect(groups.map(\.rootIdentity) == ["OpenClaw", "OpenClaw"])
        #expect(groups.map(\.processCount) == [2, 2])
        #expect(groups.map(\.representativePid) == [69601, 73573])
    }

    @Test func distinctKnownAgentSpawnedByAgentGetsOwnGroup() {
        let groups = MenuBarDataSource.groupAgents([
            Self.inventoryEntry(pid: 10, displayName: "Codex CLI", category: .foregroundCoding, verdict: .agent(reason: .knownList("Codex CLI"), confidence: .medium)),
            Self.inventoryEntry(pid: 20, displayName: "OpenClaw", category: .backgroundService, verdict: .agent(reason: .knownList("OpenClaw"), confidence: .high), parentPid: 10, parentDisplayName: "Codex CLI")
        ])

        #expect(groups.map(\.rootIdentity).sorted() == ["Codex CLI", "OpenClaw"])
    }

    private static func inventoryEntry(
        pid: pid_t = 42,
        displayName: String = "Codex CLI",
        category: InventoryCategory = .foregroundCoding,
        verdict: AgentVerdict = .agent(reason: .knownList("Codex CLI"), confidence: .medium),
        parentPid: pid_t? = nil,
        parentDisplayName: String? = nil
    ) -> InventoryEntry {
        InventoryEntry(
            pid: pid,
            executablePath: "/tmp/\(displayName.replacingOccurrences(of: " ", with: "-").lowercased())",
            displayName: displayName,
            category: category,
            verdict: verdict,
            parentPid: parentPid,
            parentDisplayName: parentDisplayName,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastClassified: Date(timeIntervalSince1970: 0),
            mcpTransport: nil
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-menubar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func withTemporaryEnvironment(_ body: (URL) throws -> Void) throws {
        environmentLock.lock()
        defer { environmentLock.unlock() }
        let oldDB = getenv("SANCTUARY_DB_PATH").map { String(cString: $0) }
        let oldAudit = getenv("SANCTUARY_AUDIT_PATH").map { String(cString: $0) }
        defer {
            restore("SANCTUARY_DB_PATH", oldDB)
            restore("SANCTUARY_AUDIT_PATH", oldAudit)
        }

        unsetenv("SANCTUARY_DB_PATH")
        unsetenv("SANCTUARY_AUDIT_PATH")
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private static func withTemporaryEnvironment(_ body: (URL) async throws -> Void) async throws {
        let oldDB = getenv("SANCTUARY_DB_PATH").map { String(cString: $0) }
        let oldAudit = getenv("SANCTUARY_AUDIT_PATH").map { String(cString: $0) }
        defer {
            restore("SANCTUARY_DB_PATH", oldDB)
            restore("SANCTUARY_AUDIT_PATH", oldAudit)
        }

        unsetenv("SANCTUARY_DB_PATH")
        unsetenv("SANCTUARY_AUDIT_PATH")
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private static func restore(_ name: String, _ value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }
}

private let environmentLock = NSLock()

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
