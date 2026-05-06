// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public final class ProtectedPathAccessPoller: SanctuaryDaemonService, @unchecked Sendable {
    public let name: String

    private let protectedPaths: [String]
    private let policy: String
    private let agentSnapshotProvider: any AgentProcessSnapshotProviding
    private let openFileProvider: any ProcessOpenFileProviding
    private let auditLogger: any ExtensionAuditLogging
    private let interval: TimeInterval
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var emittedKeys: Set<String> = []

    public init(
        name: String = "protected-path-access-poller",
        protectedPaths: [String],
        policy: String,
        agentSnapshotProvider: any AgentProcessSnapshotProviding,
        openFileProvider: any ProcessOpenFileProviding,
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        interval: TimeInterval = 0.25,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.name = name
        self.protectedPaths = protectedPaths.map(ExtensionPathMaterializer.normalize)
        self.policy = policy
        self.agentSnapshotProvider = agentSnapshotProvider
        self.openFileProvider = openFileProvider
        self.auditLogger = auditLogger
        self.interval = interval
        self.clock = clock
    }

    public func start() {
        guard !protectedPaths.isEmpty else {
            return
        }
        stop()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.protected-path-poller"))
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in
            self?.scanOnce()
        }
        lock.withLock {
            timer = source
        }
        source.resume()
    }

    public func stop() {
        let old = lock.withLock { () -> DispatchSourceTimer? in
            let timer = self.timer
            self.timer = nil
            return timer
        }
        old?.cancel()
    }

    public func scanOnce() {
        let agents = agentSnapshotProvider.runningAgents()
        guard !agents.isEmpty else {
            return
        }

        for agent in agents {
            guard let openPaths = try? openFileProvider.openFilePaths(pid: agent.pid) else {
                continue
            }

            for openPath in openPaths.map(ExtensionPathMaterializer.normalize) {
                guard let protectedPath = protectedPaths.first(where: { Self.path(openPath, isInside: $0) }) else {
                    continue
                }
                emit(agent: agent, path: openPath, protectedPath: protectedPath)
            }
        }
    }

    private func emit(agent: ProcessIdentity, path: String, protectedPath: String) {
        let key = "\(agent.pid):\(path):\(policy)"
        let shouldEmit = lock.withLock {
            emittedKeys.insert(key).inserted
        }
        guard shouldEmit else {
            return
        }

        do {
            try auditLogger.append(
                AuditEntry(
                    ts: Self.iso8601(clock()),
                    kind: "fs_access",
                    action: "DETECT_ALERT",
                    attribution: .init(level: "definite", pid: agent.pid, processPath: agent.executablePath, agentPids: [agent.pid]),
                    policy: policy,
                    path: path,
                    process: .init(identity: agent),
                    resource: protectedPath
                )
            )
        } catch {
            FileHandle.standardError.write(Data("Sanctuary protected-path poller audit failed: \(error)\n".utf8))
        }
    }

    private static func path(_ lhs: String, isInside rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
