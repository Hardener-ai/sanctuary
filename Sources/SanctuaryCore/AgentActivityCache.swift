// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public final class AgentActivityCache: AgentProcessSnapshotProviding, ProcessOpenFileProviding, @unchecked Sendable {
    private struct CachedAgent {
        var identity: ProcessIdentity
        var openFilePaths: [String]
        var lastSeen: Date
    }

    private let classifier: AgentClassifier
    private let proc: any DarwinProcProviding
    private let identityCollector: any ProcessIdentityCollecting
    private let openFileProvider: any ProcessOpenFileProviding
    private let clock: @Sendable () -> Date
    private let retention: TimeInterval
    private let lock = NSLock()
    private var cache: [pid_t: CachedAgent] = [:]
    private var refreshTimer: DispatchSourceTimer?

    public init(
        classifier: AgentClassifier = AgentClassifier(),
        proc: any DarwinProcProviding = DarwinProc(),
        identityCollector: any ProcessIdentityCollecting = ProcessIdentityCollector(),
        openFileProvider: any ProcessOpenFileProviding = DarwinOpenFileProvider(),
        clock: @escaping @Sendable () -> Date = { Date() },
        retention: TimeInterval = 5
    ) {
        self.classifier = classifier
        self.proc = proc
        self.identityCollector = identityCollector
        self.openFileProvider = openFileProvider
        self.clock = clock
        self.retention = retention
    }

    public func startContinuousRefresh(interval: TimeInterval = 0.25) {
        stop()
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.agent-activity-cache"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        lock.withLock {
            refreshTimer = timer
        }
        timer.resume()
    }

    public func stop() {
        let timer = lock.withLock { () -> DispatchSourceTimer? in
            let old = refreshTimer
            refreshTimer = nil
            return old
        }
        timer?.cancel()
    }

    public func refresh() {
        let now = clock()
        guard let pids = try? proc.listPIDs() else {
            prune(now: now)
            return
        }

        let excluded = Set(CurrentProcessExclusion.processGroup(containing: getpid(), listPIDs: { pids }))
        for pid in CurrentProcessExclusion.filterPids(pids, excluding: excluded) {
            guard let identity = identityCollector.collect(pid: pid) else {
                continue
            }
            guard !CurrentProcessExclusion.isSanctuaryExecutablePath(identity.executablePath) else {
                continue
            }
            guard case .agent = classifier.classify(identity) else {
                continue
            }
            let paths = (try? openFileProvider.openFilePaths(pid: pid)) ?? []
            lock.withLock {
                cache[pid] = CachedAgent(
                    identity: identity,
                    openFilePaths: paths.map(ExtensionPathMaterializer.normalize),
                    lastSeen: now
                )
            }
        }

        prune(now: now)
    }

    public func runningAgents() -> [ProcessIdentity] {
        refresh()
        let now = clock()
        return lock.withLock {
            cache.values
                .filter { now.timeIntervalSince($0.lastSeen) <= retention }
                .map(\.identity)
                .sorted { $0.pid < $1.pid }
        }
    }

    public func openFilePaths(pid: pid_t) throws -> [String] {
        if let live = try? openFileProvider.openFilePaths(pid: pid) {
            let normalized = live.map(ExtensionPathMaterializer.normalize)
            lock.withLock {
                if var existing = cache[pid] {
                    existing.openFilePaths = normalized
                    existing.lastSeen = clock()
                    cache[pid] = existing
                }
            }
            return normalized
        }

        let now = clock()
        if let cached = lock.withLock({ cache[pid] }),
           now.timeIntervalSince(cached.lastSeen) <= retention {
            return cached.openFilePaths
        }

        throw DarwinProcError.processUnavailable
    }

    private func prune(now: Date) {
        lock.withLock {
            cache = cache.filter { now.timeIntervalSince($0.value.lastSeen) <= retention }
        }
    }
}
