// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ProtectedFolderWatcherTests {
    @Test func definiteAttributionWhenAgentHasPathOpen() {
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let watcher = makeWatcher(agents: [agent], openFiles: [321: ["/tmp/protected/secret.txt"]])

        let attribution = watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 1))

        #expect(attribution == .definite(agent))
    }

    @Test func probableAttributionUsesRecentFdHistory() {
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let now = FSLockedBox(Date(timeIntervalSince1970: 10))
        let openFiles = FSOpenFileProvider(openFiles: [321: ["/tmp/protected/secret.txt"]])
        let watcher = makeWatcher(agents: [agent], openFileProvider: openFiles, clock: { now.get() })

        _ = watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 1))
        openFiles.set([:])
        now.set(Date(timeIntervalSince1970: 12))

        if case let .probable(identity, age) = watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 2)) {
            #expect(identity == agent)
            #expect(age == 2)
        } else {
            Issue.record("expected probable attribution")
        }
    }

    @Test func staleHistoryFallsBackToCorrelated() {
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let now = FSLockedBox(Date(timeIntervalSince1970: 10))
        let openFiles = FSOpenFileProvider(openFiles: [321: ["/tmp/protected/secret.txt"]])
        let watcher = makeWatcher(agents: [agent], openFileProvider: openFiles, clock: { now.get() })

        _ = watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 1))
        openFiles.set([:])
        now.set(Date(timeIntervalSince1970: 20))

        #expect(watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 2)) == .correlated([agent]))
    }

    @Test func correlatedWhenAgentsRunWithoutFdEvidence() {
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let watcher = makeWatcher(agents: [agent], openFiles: [:])

        #expect(watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 1)) == .correlated([agent]))
    }

    @Test func unattributedWhenNoAgentsRun() {
        let watcher = makeWatcher(agents: [], openFiles: [:])

        #expect(watcher.attribute(.init(path: "/tmp/protected/secret.txt", flags: 1)) == .unattributed)
    }

    @Test func auditEntryWrittenForProtectedFolderEvent() throws {
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(agents: [agent], openFiles: [321: ["/tmp/protected/secret.txt"]], logger: logger)

        watcher.handle(.init(path: "/tmp/protected/secret.txt", flags: 42, timestamp: Date(timeIntervalSince1970: 0)))

        let entry = try #require(logger.entries.first)
        #expect(entry.kind == "fs_access")
        #expect(entry.action == "DETECT_ALERT")
        #expect(entry.policy == "protected_folder")
        #expect(entry.path == "/tmp/protected/secret.txt")
        #expect(entry.flags == 42)
        #expect(entry.attribution?.level == "definite")
        #expect(entry.process?.pid == 321)
    }

    @Test func auditNotWrittenForUnattributedEvent() {
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(agents: [], openFiles: [:], logger: logger)

        watcher.handle(.init(path: "/tmp/protected/secret.txt", flags: 1))

        #expect(logger.entries.isEmpty)
    }

    @Test func backendEventInsideProtectedPathRoutesToAudit() throws {
        let backend = FSMockFSEventsBackend()
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(
            paths: ["/tmp/protected"],
            backend: backend,
            agents: [agent],
            openFiles: [321: ["/tmp/protected/secret.txt"]],
            logger: logger
        )
        try watcher.start()

        backend.emit(.init(path: "/tmp/protected/secret.txt", flags: 1))

        #expect(logger.entries.count == 1)
    }

    @Test func backendEventOutsideProtectedPathIsIgnored() throws {
        let backend = FSMockFSEventsBackend()
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(
            paths: ["/tmp/protected"],
            backend: backend,
            agents: [agent],
            openFiles: [321: ["/tmp/other/secret.txt"]],
            logger: logger
        )
        try watcher.start()

        backend.emit(.init(path: "/tmp/other/secret.txt", flags: 1))

        #expect(logger.entries.isEmpty)
    }

    @Test func stopUnsubscribesBackend() throws {
        let backend = FSMockFSEventsBackend()
        let watcher = makeWatcher(paths: ["/tmp/protected"], backend: backend, agents: [], openFiles: [:])
        try watcher.start()

        watcher.stop()

        #expect(backend.handle?.isStopped == true)
        #expect(!watcher.isRunning)
    }

    @Test func updateProtectedPathsRestartsWatcher() throws {
        let backend = FSMockFSEventsBackend()
        let agent = ProcessIdentity(pid: 321, executablePath: "/usr/local/bin/claude")
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(
            paths: ["/tmp/old"],
            backend: backend,
            agents: [agent],
            openFiles: [321: ["/tmp/new/secret.txt"]],
            logger: logger
        )
        try watcher.start()

        try watcher.updateProtectedPaths(["/tmp/new"])
        backend.emit(.init(path: "/tmp/old/secret.txt", flags: 1))
        backend.emit(.init(path: "/tmp/new/secret.txt", flags: 1))

        #expect(logger.entries.count == 1)
    }

    @Test func auditEntryDoesNotIncludeEnvironmentVars() throws {
        let agent = ProcessIdentity(
            pid: 321,
            executablePath: "/usr/local/bin/claude",
            environmentVars: ["OPENAI_API_KEY", "PATH"]
        )
        let logger = FSCapturingAuditLogger()
        let watcher = makeWatcher(agents: [agent], openFiles: [321: ["/tmp/protected/secret.txt"]], logger: logger)

        watcher.handle(.init(path: "/tmp/protected/secret.txt", flags: 1))

        let data = try JSONEncoder().encode(try #require(logger.entries.first))
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("OPENAI_API_KEY"))
        #expect(!json.contains("PATH"))
    }

    @Test func liveSnapshotProviderSkipsCurrentProcess() {
        let provider = DarwinAgentProcessSnapshotProvider(
            proc: FSDarwinProc(pids: [111, 222]),
            identityCollector: FSIdentityCollector(identities: [
                111: ProcessIdentity(pid: 111, executablePath: "/usr/local/bin/claude"),
                222: ProcessIdentity(pid: 222, executablePath: "/usr/local/bin/claude"),
            ]),
            currentPID: { 111 }
        )

        #expect(provider.runningAgents().map(\.pid) == [222])
    }

    private func makeWatcher(
        paths: [String] = ["/tmp/protected"],
        backend: any FSEventsBackend = FSMockFSEventsBackend(),
        agents: [ProcessIdentity],
        openFiles: [pid_t: [String]],
        logger: FSCapturingAuditLogger = FSCapturingAuditLogger(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> ProtectedFolderWatcher {
        makeWatcher(
            paths: paths,
            backend: backend,
            agents: agents,
            openFileProvider: FSOpenFileProvider(openFiles: openFiles),
            logger: logger,
            clock: clock
        )
    }

    private func makeWatcher(
        paths: [String] = ["/tmp/protected"],
        backend: any FSEventsBackend = FSMockFSEventsBackend(),
        agents: [ProcessIdentity],
        openFileProvider: FSOpenFileProvider,
        logger: FSCapturingAuditLogger = FSCapturingAuditLogger(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) }
    ) -> ProtectedFolderWatcher {
        ProtectedFolderWatcher(
            protectedPaths: paths,
            backend: backend,
            agentSnapshotProvider: FSAgentSnapshotProvider(agents: agents),
            openFileProvider: openFileProvider,
            auditLogger: logger,
            clock: clock
        )
    }
}

private struct FSAgentSnapshotProvider: AgentProcessSnapshotProviding {
    let agents: [ProcessIdentity]

    func runningAgents() -> [ProcessIdentity] {
        agents
    }
}

private final class FSOpenFileProvider: ProcessOpenFileProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [pid_t: [String]]

    init(openFiles: [pid_t: [String]]) {
        self.stored = openFiles
    }

    func set(_ openFiles: [pid_t: [String]]) {
        lock.withLock {
            stored = openFiles
        }
    }

    func openFilePaths(pid: pid_t) throws -> [String] {
        lock.withLock { stored[pid] ?? [] }
    }
}

private final class FSCapturingAuditLogger: ExtensionAuditLogging, @unchecked Sendable {
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

private final class FSMockFSEventsBackend: FSEventsBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (ExtensionStorageEvent) -> Void)?
    private(set) var handle: FSMockFSEventsHandle?

    func start(
        paths: [String],
        latency: TimeInterval,
        callback: @escaping @Sendable (ExtensionStorageEvent) -> Void
    ) throws -> any FSEventsStreamHandle {
        let handle = FSMockFSEventsHandle()
        lock.withLock {
            self.callback = callback
            self.handle = handle
        }
        return handle
    }

    func emit(_ event: ExtensionStorageEvent) {
        lock.withLock { callback }?(event)
    }
}

private final class FSMockFSEventsHandle: FSEventsStreamHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        lock.withLock {
            stopped = true
        }
    }
}

private final class FSLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ value: Value) {
        lock.withLock {
            self.value = value
        }
    }
}

private struct FSDarwinProc: DarwinProcProviding {
    let pids: [pid_t]

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

private struct FSIdentityCollector: ProcessIdentityCollecting {
    let identities: [pid_t: ProcessIdentity]

    func collect(pid: pid_t) -> ProcessIdentity? {
        identities[pid]
    }
}
