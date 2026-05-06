// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ProtectedPathAccessPollerTests {
    @Test func scanAuditsAgentOpenFileUnderProtectedPath() throws {
        let audit = PollerAudit()
        let poller = ProtectedPathAccessPoller(
            protectedPaths: ["/tmp/profile/Local Extension Settings/nkb"],
            policy: "protected_extension_storage",
            agentSnapshotProvider: PollerAgents(agents: [
                ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
            ]),
            openFileProvider: PollerOpenFiles(paths: [
                42: ["/tmp/profile/Local Extension Settings/nkb/000003.log"]
            ]),
            auditLogger: audit
        )

        poller.scanOnce()

        #expect(audit.entries.count == 1)
        #expect(audit.entries.first?.policy == "protected_extension_storage")
        #expect(audit.entries.first?.attribution?.level == "definite")
        #expect(audit.entries.first?.process?.pid == 42)
    }

    @Test func scanIgnoresOpenFilesOutsideProtectedPaths() {
        let audit = PollerAudit()
        let poller = ProtectedPathAccessPoller(
            protectedPaths: ["/tmp/profile/Local Extension Settings/nkb"],
            policy: "protected_extension_storage",
            agentSnapshotProvider: PollerAgents(agents: [
                ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
            ]),
            openFileProvider: PollerOpenFiles(paths: [42: ["/tmp/elsewhere/file"]]),
            auditLogger: audit
        )

        poller.scanOnce()

        #expect(audit.entries.isEmpty)
    }

    @Test func scanDeduplicatesSamePidPathPolicy() {
        let audit = PollerAudit()
        let poller = ProtectedPathAccessPoller(
            protectedPaths: ["/tmp/profile/Local Extension Settings/nkb"],
            policy: "protected_extension_storage",
            agentSnapshotProvider: PollerAgents(agents: [
                ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
            ]),
            openFileProvider: PollerOpenFiles(paths: [
                42: ["/tmp/profile/Local Extension Settings/nkb/000003.log"]
            ]),
            auditLogger: audit
        )

        poller.scanOnce()
        poller.scanOnce()

        #expect(audit.entries.count == 1)
    }
}

private final class PollerAudit: ExtensionAuditLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [AuditEntry] = []

    func append(_ entry: AuditEntry) throws {
        lock.withLock {
            entries.append(entry)
        }
    }
}

private struct PollerAgents: AgentProcessSnapshotProviding {
    let agents: [ProcessIdentity]

    func runningAgents() -> [ProcessIdentity] {
        agents
    }
}

private struct PollerOpenFiles: ProcessOpenFileProviding {
    let paths: [pid_t: [String]]

    func openFilePaths(pid: pid_t) throws -> [String] {
        paths[pid] ?? []
    }
}
