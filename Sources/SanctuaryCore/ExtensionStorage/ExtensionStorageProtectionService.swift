// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public enum ExtensionStorageAttribution: Equatable, Sendable {
    case definite(ProcessIdentity)
    case probable(ProcessIdentity)
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

public protocol AgentProcessSnapshotProviding: Sendable {
    func runningAgents() -> [ProcessIdentity]
}

public protocol ProcessOpenFileProviding: Sendable {
    func openFilePaths(pid: pid_t) throws -> [String]
}

public protocol ExtensionAuditLogging: Sendable {
    func append(_ entry: AuditEntry) throws
}

public final class ExtensionStorageProtectionService: @unchecked Sendable {
    private let watcher: ExtensionStorageWatcher
    private let agentSnapshotProvider: any AgentProcessSnapshotProviding
    private let openFileProvider: any ProcessOpenFileProviding
    private let auditLogger: any ExtensionAuditLogging
    private let clock: @Sendable () -> Date
    private let auditErrorHandler: @Sendable (Error) -> Void

    public init(
        watcher: ExtensionStorageWatcher,
        agentSnapshotProvider: any AgentProcessSnapshotProviding,
        openFileProvider: any ProcessOpenFileProviding = DarwinOpenFileProvider(),
        auditLogger: any ExtensionAuditLogging = AuditLog(),
        clock: @escaping @Sendable () -> Date = { Date() },
        auditErrorHandler: @escaping @Sendable (Error) -> Void = { error in
            FileHandle.standardError.write(Data("Sanctuary extension-storage audit failed: \(error)\n".utf8))
        }
    ) {
        self.watcher = watcher
        self.agentSnapshotProvider = agentSnapshotProvider
        self.openFileProvider = openFileProvider
        self.auditLogger = auditLogger
        self.clock = clock
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
                    policy: "protected_extension_storage",
                    path: event.path,
                    flags: event.flags
                )
            )
        } catch {
            auditErrorHandler(error)
        }
    }

    public func attribute(_ event: ExtensionStorageEvent) -> ExtensionStorageAttribution {
        let agents = agentSnapshotProvider.runningAgents()
        guard !agents.isEmpty else {
            return .unattributed
        }

        for agent in agents {
            guard let paths = try? openFileProvider.openFilePaths(pid: agent.pid) else {
                continue
            }
            if paths.contains(where: { Self.path($0, matches: event.path) || Self.path(event.path, matches: $0) }) {
                return .definite(agent)
            }
        }

        return .correlated(agents)
    }

    private func shouldAudit(_ attribution: ExtensionStorageAttribution) -> Bool {
        switch attribution {
        case .definite, .probable, .correlated:
            return true
        case .unattributed:
            return false
        }
    }

    private static func path(_ lhs: String, matches rhs: String) -> Bool {
        let left = ExtensionPathMaterializer.normalize(lhs)
        let right = ExtensionPathMaterializer.normalize(rhs)
        return left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }

    private static func auditAttribution(_ attribution: ExtensionStorageAttribution) -> AuditEntry.Attribution {
        switch attribution {
        case let .definite(identity):
            return .init(level: "definite", pid: identity.pid, processPath: identity.executablePath, agentPids: [identity.pid])
        case let .probable(identity):
            return .init(level: "probable", pid: identity.pid, processPath: identity.executablePath, agentPids: [identity.pid])
        case let .correlated(agents):
            return .init(level: "correlated", pid: nil, processPath: nil, agentPids: agents.map(\.pid))
        case .unattributed:
            return .init(level: "unattributed", pid: nil, processPath: nil, agentPids: [])
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public struct DarwinAgentProcessSnapshotProvider: AgentProcessSnapshotProviding {
    private let classifier: AgentClassifier
    private let proc: any DarwinProcProviding
    private let identityCollector: any ProcessIdentityCollecting
    private let currentPID: @Sendable () -> pid_t

    public init(
        classifier: AgentClassifier = AgentClassifier(),
        proc: any DarwinProcProviding = DarwinProc(),
        identityCollector: any ProcessIdentityCollecting = ProcessIdentityCollector(),
        currentPID: @escaping @Sendable () -> pid_t = { getpid() }
    ) {
        self.classifier = classifier
        self.proc = proc
        self.identityCollector = identityCollector
        self.currentPID = currentPID
    }

    public func runningAgents() -> [ProcessIdentity] {
        guard let pids = try? proc.listPIDs() else {
            return []
        }
        let excluded = Set(CurrentProcessExclusion.processGroup(containing: currentPID(), listPIDs: { pids }))
        return CurrentProcessExclusion.filterPids(pids, excluding: excluded).compactMap { pid in
            guard let identity = identityCollector.collect(pid: pid) else {
                return nil
            }
            if case .agent = classifier.classify(identity) {
                return identity
            }
            return nil
        }
    }
}

public struct DarwinOpenFileProvider: ProcessOpenFileProviding {
    public init() {}

    public func openFilePaths(pid: pid_t) throws -> [String] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if byteCount <= 0 {
            throw DarwinProcError.processUnavailable
        }

        let capacity = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
        var descriptors = Array(repeating: proc_fdinfo(), count: capacity)
        let writtenBytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        if writtenBytes <= 0 {
            throw DarwinProcError.processUnavailable
        }

        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(writtenBytes) / MemoryLayout<proc_fdinfo>.stride)
            where Int32(descriptor.proc_fdtype) == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let infoBytes = withUnsafeMutableBytes(of: &info) { buffer in
                proc_pidfdinfo(pid, Int32(descriptor.proc_fd), PROC_PIDFDVNODEPATHINFO, buffer.baseAddress, Int32(buffer.count))
            }
            guard infoBytes > 0 else {
                continue
            }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { buffer -> String in
                let chars = buffer.bindMemory(to: CChar.self)
                return String(cString: chars.baseAddress!)
            }
            if !path.isEmpty {
                paths.append(ExtensionPathMaterializer.normalize(path))
            }
        }
        return Array(Set(paths)).sorted()
    }
}
