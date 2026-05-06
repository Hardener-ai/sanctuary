// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
@testable import SanctuaryCore

struct ExtensionStorageProtectionServiceTests {
    @Test func definiteAttributionWhenAgentHasPathOpen() {
        let agent = ProcessIdentity(pid: 123, executablePath: "/usr/local/bin/claude")
        let service = makeService(
            agents: [agent],
            openFiles: [123: ["/tmp/profile/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn/000003.log"]]
        )

        let attribution = service.attribute(.init(path: "/tmp/profile/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn/000003.log", flags: 1))

        #expect(attribution == .definite(agent))
    }

    @Test func correlatedAttributionWhenAgentRunsWithoutOpenFD() {
        let agent = ProcessIdentity(pid: 123, executablePath: "/usr/local/bin/claude")
        let service = makeService(agents: [agent], openFiles: [:])

        let attribution = service.attribute(.init(path: "/tmp/profile/Local Extension Settings/id/file", flags: 1))

        #expect(attribution == .correlated([agent]))
    }

    @Test func unattributedWhenNoAgentsRun() {
        let service = makeService(agents: [], openFiles: [:])

        let attribution = service.attribute(.init(path: "/tmp/profile/file", flags: 1))

        #expect(attribution == .unattributed)
    }

    @Test func auditLogWrittenForDefiniteAgentEvent() throws {
        let agent = ProcessIdentity(pid: 123, executablePath: "/usr/local/bin/claude")
        let logger = CapturingAuditLogger()
        let service = makeService(
            agents: [agent],
            openFiles: [123: ["/tmp/profile/file"]],
            logger: logger
        )

        service.handle(.init(path: "/tmp/profile/file", flags: 99, timestamp: Date(timeIntervalSince1970: 0)))

        let entry = try #require(logger.entries.first)
        let attribution = try #require(entry.attribution)
        #expect(entry.action == "DETECT_ALERT")
        #expect(entry.policy == "protected_extension_storage")
        #expect(attribution.level == "definite")
        #expect(attribution.pid == 123)
    }

    @Test func auditLogNotWrittenForUnattributedEvent() {
        let logger = CapturingAuditLogger()
        let service = makeService(agents: [], openFiles: [:], logger: logger)

        service.handle(.init(path: "/tmp/profile/file", flags: 1))

        #expect(logger.entries.isEmpty)
    }

    @Test func jsonlAuditLoggerWritesSchemaLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-audit-\(UUID().uuidString).log")
        let logger = AuditLog(path: url.path, signingKeyProvider: FixedAuditSigningKeyProvider())

        try logger.append(
            AuditEntry(
                ts: "2026-05-05T00:00:00.000Z",
                kind: "fs_access",
                action: "DETECT_ALERT",
                attribution: .init(level: "definite", pid: 123, processPath: "/usr/local/bin/claude", agentPids: [123]),
                policy: "protected_extension_storage",
                path: "/tmp/profile/file",
                flags: 1
            )
        )

        let line = try String(contentsOf: url, encoding: .utf8)
        #expect(line.contains(#""action":"DETECT_ALERT""#))
        #expect(line.contains(#""kind":"fs_access""#))
    }

    private func makeService(
        agents: [ProcessIdentity],
        openFiles: [pid_t: [String]],
        logger: CapturingAuditLogger = CapturingAuditLogger()
    ) -> ExtensionStorageProtectionService {
        ExtensionStorageProtectionService(
            watcher: ExtensionStorageWatcher(protectedPaths: [], backend: MockFSEventsBackend()),
            agentSnapshotProvider: FixedAgentSnapshotProvider(agents: agents),
            openFileProvider: FixedOpenFileProvider(openFiles: openFiles),
            auditLogger: logger,
            clock: { Date(timeIntervalSince1970: 0) }
        )
    }
}

private struct FixedAgentSnapshotProvider: AgentProcessSnapshotProviding {
    let agents: [ProcessIdentity]

    func runningAgents() -> [ProcessIdentity] {
        agents
    }
}

private struct FixedOpenFileProvider: ProcessOpenFileProviding {
    let openFiles: [pid_t: [String]]

    func openFilePaths(pid: pid_t) throws -> [String] {
        openFiles[pid] ?? []
    }
}

private final class CapturingAuditLogger: ExtensionAuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [AuditEntry] = []

    var entries: [AuditEntry] {
        lock.withLock { storedEntries }
    }

    func append(_ entry: AuditEntry) throws {
        lock.withLock {
            storedEntries.append(entry)
        }
    }
}

private struct FixedAuditSigningKeyProvider: AuditSigningKeyProviding {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))

    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func publicKeyData(keychainAccount: String) throws -> Data {
        key.publicKey.rawRepresentation
    }
}
