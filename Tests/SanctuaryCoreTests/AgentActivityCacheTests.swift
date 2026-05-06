// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct AgentActivityCacheTests {
    @Test func cachedAgentSurvivesAfterProcessExitsWithinRetention() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 100))
        let proc = ActivityProc(pids: [42])
        let collector = ActivityCollector(identities: [
            42: ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
        ])
        let openFiles = ActivityOpenFiles(paths: [42: ["/tmp/secret.txt"]])
        let cache = AgentActivityCache(
            proc: proc,
            identityCollector: collector,
            openFileProvider: openFiles,
            clock: { clock.now },
            retention: 5
        )

        cache.refresh()
        proc.pids = []
        collector.identities = [:]
        openFiles.paths = [:]
        clock.now = Date(timeIntervalSince1970: 102)

        #expect(cache.runningAgents().map(\.pid) == [42])
        #expect(try cache.openFilePaths(pid: 42) == ["/tmp/secret.txt"])
    }

    @Test func cachedAgentExpiresAfterRetention() throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 100))
        let proc = ActivityProc(pids: [42])
        let collector = ActivityCollector(identities: [
            42: ProcessIdentity(pid: 42, executablePath: "/usr/local/bin/claude")
        ])
        let openFiles = ActivityOpenFiles(paths: [42: ["/tmp/secret.txt"]])
        let cache = AgentActivityCache(
            proc: proc,
            identityCollector: collector,
            openFileProvider: openFiles,
            clock: { clock.now },
            retention: 1
        )

        cache.refresh()
        proc.pids = []
        collector.identities = [:]
        openFiles.paths = [:]
        clock.now = Date(timeIntervalSince1970: 103)

        #expect(cache.runningAgents().isEmpty)
        #expect(throws: DarwinProcError.processUnavailable) {
            _ = try cache.openFilePaths(pid: 42)
        }
    }

    @Test func sanctuaryDaemonProcessIsNeverCachedAsAgent() {
        let cache = AgentActivityCache(
            proc: ActivityProc(pids: [42]),
            identityCollector: ActivityCollector(identities: [
                42: ProcessIdentity(
                    pid: 42,
                    executablePath: "/Users/tg/Projects/sanctuary/.build/release/sanctuaryd",
                    parentChain: [ProcessIdentity(pid: 1, executablePath: "/sbin/launchd")]
                )
            ]),
            openFileProvider: ActivityOpenFiles(paths: [42: ["/Users/tg/.ssh/.sanctuary-probe"]])
        )

        cache.refresh()

        #expect(cache.runningAgents().isEmpty)
    }
}

private final class MutableClock: @unchecked Sendable {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class ActivityProc: DarwinProcProviding, @unchecked Sendable {
    var pids: [pid_t]

    init(pids: [pid_t]) {
        self.pids = pids
    }

    func listPIDs() throws -> [pid_t] {
        pids
    }

    func listFileDescriptors(pid: pid_t) throws -> [ProcessFileDescriptor] {
        []
    }

    func socketInfo(pid: pid_t, fd: Int32) throws -> ProcessSocketInfo? {
        nil
    }
}

private final class ActivityCollector: ProcessIdentityCollecting, @unchecked Sendable {
    var identities: [pid_t: ProcessIdentity]

    init(identities: [pid_t: ProcessIdentity]) {
        self.identities = identities
    }

    func collect(pid: pid_t) -> ProcessIdentity? {
        identities[pid]
    }
}

private final class ActivityOpenFiles: ProcessOpenFileProviding, @unchecked Sendable {
    var paths: [pid_t: [String]]

    init(paths: [pid_t: [String]]) {
        self.paths = paths
    }

    func openFilePaths(pid: pid_t) throws -> [String] {
        guard let value = paths[pid] else {
            throw DarwinProcError.processUnavailable
        }
        return value
    }
}
