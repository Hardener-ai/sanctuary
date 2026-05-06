// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum ProtectedFolderAttribution: Equatable, Sendable {
    case definite(ProcessIdentity)
    case probable(ProcessIdentity, age: TimeInterval)
    case correlated([ProcessIdentity])
    case unattributed

    public var level: String {
        switch self {
        case .definite:
            return "definite"
        case .probable:
            return "probable"
        case .correlated:
            return "correlated"
        case .unattributed:
            return "unattributed"
        }
    }
}

public final class ProtectedFolderWatcher: @unchecked Sendable {
    private struct RecentAccess: Sendable {
        let path: String
        let identity: ProcessIdentity
        let timestamp: Date
    }

    private let watcher: ExtensionStorageWatcher
    private let agentSnapshotProvider: any AgentProcessSnapshotProviding
    private let openFileProvider: any ProcessOpenFileProviding
    private let auditLogger: any ExtensionAuditLogging
    private let clock: @Sendable () -> Date
    private let auditErrorHandler: @Sendable (Error) -> Void
    private let historyWindow: TimeInterval
    private let lock = NSLock()
    private var recentAccesses: [RecentAccess] = []

    public init(
        protectedPaths: [String],
        backend: any FSEventsBackend = SystemFSEventsBackend(),
        agentSnapshotProvider: any AgentProcessSnapshotProviding = DarwinAgentProcessSnapshotProvider(),
        openFileProvider: any ProcessOpenFileProviding = DarwinOpenFileProvider(),
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        clock: @escaping @Sendable () -> Date = { Date() },
        historyWindow: TimeInterval = 5,
        auditErrorHandler: @escaping @Sendable (Error) -> Void = { error in
            FileHandle.standardError.write(Data("Sanctuary protected-folder audit failed: \(error)\n".utf8))
        }
    ) {
        self.watcher = ExtensionStorageWatcher(protectedPaths: protectedPaths, backend: backend, latency: 0.1)
        self.agentSnapshotProvider = agentSnapshotProvider
        self.openFileProvider = openFileProvider
        self.auditLogger = auditLogger
        self.clock = clock
        self.historyWindow = historyWindow
        self.auditErrorHandler = auditErrorHandler
    }

    public var isRunning: Bool {
        watcher.isRunning
    }

    public func start() throws {
        try watcher.start { [weak self] event in
            self?.handle(event)
        }
    }

    public func stop() {
        watcher.stop()
    }

    public func updateProtectedPaths(_ paths: [String]) throws {
        try watcher.updateProtectedPaths(paths)
    }

    public func handle(_ event: ExtensionStorageEvent) {
        let attribution = attribute(event)
        guard shouldAudit(attribution) else {
            return
        }

        do {
            try auditLogger.append(
                AuditEntry(
                    ts: Self.iso8601(clock()),
                    kind: "fs_access",
                    action: "DETECT_ALERT",
                    attribution: Self.auditAttribution(attribution),
                    policy: "protected_folder",
                    path: event.path,
                    flags: event.flags,
                    process: Self.auditProcess(attribution)
                )
            )
        } catch {
            auditErrorHandler(error)
        }
    }

    public func attribute(_ event: ExtensionStorageEvent) -> ProtectedFolderAttribution {
        let now = clock()
        let eventPath = ExtensionPathMaterializer.normalize(event.path)
        let agents = agentSnapshotProvider.runningAgents()
        guard !agents.isEmpty else {
            return .unattributed
        }

        pruneHistory(now: now)

        for agent in agents {
            guard let paths = try? openFileProvider.openFilePaths(pid: agent.pid) else {
                continue
            }
            if paths.contains(where: { Self.path($0, matches: eventPath) || Self.path(eventPath, matches: $0) }) {
                remember(path: eventPath, identity: agent, timestamp: now)
                return .definite(agent)
            }
        }

        if let recent = recentMatch(for: eventPath, now: now) {
            return .probable(recent.identity, age: now.timeIntervalSince(recent.timestamp))
        }

        return .correlated(agents)
    }

    private func shouldAudit(_ attribution: ProtectedFolderAttribution) -> Bool {
        switch attribution {
        case .definite, .probable, .correlated:
            return true
        case .unattributed:
            return false
        }
    }

    private func remember(path: String, identity: ProcessIdentity, timestamp: Date) {
        lock.withLock {
            recentAccesses.append(.init(path: path, identity: identity, timestamp: timestamp))
        }
    }

    private func recentMatch(for path: String, now: Date) -> RecentAccess? {
        lock.withLock {
            recentAccesses.first { recent in
                now.timeIntervalSince(recent.timestamp) <= historyWindow
                    && (Self.path(recent.path, matches: path) || Self.path(path, matches: recent.path))
            }
        }
    }

    private func pruneHistory(now: Date) {
        lock.withLock {
            recentAccesses.removeAll { now.timeIntervalSince($0.timestamp) > historyWindow }
        }
    }

    private static func path(_ lhs: String, matches rhs: String) -> Bool {
        let left = ExtensionPathMaterializer.normalize(lhs)
        let right = ExtensionPathMaterializer.normalize(rhs)
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func auditAttribution(_ attribution: ProtectedFolderAttribution) -> AuditEntry.Attribution {
        switch attribution {
        case let .definite(identity):
            return .init(level: "definite", pid: identity.pid, processPath: identity.executablePath, agentPids: [identity.pid])
        case let .probable(identity, _):
            return .init(level: "probable", pid: identity.pid, processPath: identity.executablePath, agentPids: [identity.pid])
        case let .correlated(agents):
            return .init(level: "correlated", pid: nil, processPath: nil, agentPids: agents.map(\.pid))
        case .unattributed:
            return .init(level: "unattributed", pid: nil, processPath: nil, agentPids: [])
        }
    }

    private static func auditProcess(_ attribution: ProtectedFolderAttribution) -> AuditEntry.Process? {
        switch attribution {
        case let .definite(identity), let .probable(identity, _):
            return .init(identity: identity)
        case .correlated, .unattributed:
            return nil
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
