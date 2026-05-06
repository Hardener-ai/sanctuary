// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public protocol SanctuaryDaemonService: AnyObject, Sendable {
    var name: String { get }
    func start() throws
    func stop()
}

public final class SanctuaryDaemonRuntime: @unchecked Sendable {
    public let folderWatchPathCount: Int
    public let extensionWatchPathCount: Int

    private let services: [any SanctuaryDaemonService]

    public init(
        services: [any SanctuaryDaemonService],
        folderWatchPathCount: Int = 0,
        extensionWatchPathCount: Int = 0
    ) {
        self.services = services
        self.folderWatchPathCount = folderWatchPathCount
        self.extensionWatchPathCount = extensionWatchPathCount
    }

    public static func live() throws -> SanctuaryDaemonRuntime {
        let folderRegistry = try ProtectedFolderRegistry()
        let extensionRegistry = try ProtectedExtensionRegistry()
        let userTaggedAgents = try UserTaggedAgentRegistry()
        let trustedPaths = try TrustedPathRegistry()
        let classifier = AgentClassifier(userTaggedAgents: userTaggedAgents, trustedPaths: trustedPaths)
        let folderPaths = try folderRegistry.existingWatchedPaths()
        let extensionPaths = try extensionRegistry.pathsForActiveProtections()
        let auditLog = AuditLog()
        try auditLog.recoverFromTamperingIfNeeded()
        let activityCache = AgentActivityCache(classifier: classifier)
        let peerMonitor = PeerMonitorService(auditLogger: auditLog)

        let folderWatcher = ProtectedFolderWatcher(
            protectedPaths: folderPaths,
            agentSnapshotProvider: activityCache,
            openFileProvider: activityCache,
            auditLogger: auditLog
        )
        let extensionWatcher = ExtensionStorageWatcher(protectedPaths: extensionPaths)
        let extensionService = ExtensionStorageProtectionService(
            watcher: extensionWatcher,
            agentSnapshotProvider: activityCache,
            openFileProvider: activityCache,
            auditLogger: auditLog
        )
        let extensionReadPoller = ProtectedPathAccessPoller(
            name: "extension-storage-read-poller",
            protectedPaths: extensionPaths,
            policy: "protected_extension_storage",
            agentSnapshotProvider: DarwinAgentProcessSnapshotProvider(classifier: classifier),
            openFileProvider: DarwinOpenFileProvider(),
            auditLogger: auditLog
        )
        let inventorySnapshotPath = SanctuaryPaths.inventorySnapshotPath()
        let serviceInventory = ServiceInventory(
            classifier: classifier,
            collector: ProcessIdentityCollector(),
            snapshotPath: inventorySnapshotPath
        )

        return SanctuaryDaemonRuntime(
            services: [
                peerMonitor,
                AgentActivityCacheService(cache: activityCache),
                ProtectedFolderWatcherService(watcher: folderWatcher),
                ExtensionStorageProtectionDaemonService(service: extensionService),
                extensionReadPoller,
                ServiceInventoryDaemonService(inventory: serviceInventory)
            ],
            folderWatchPathCount: folderPaths.count,
            extensionWatchPathCount: extensionPaths.count
        )
    }

    public func start() throws {
        var started: [any SanctuaryDaemonService] = []
        do {
            for service in services {
                try service.start()
                started.append(service)
            }
        } catch {
            for service in started.reversed() {
                service.stop()
            }
            throw error
        }
    }

    public func stop() {
        for service in services.reversed() {
            service.stop()
        }
    }

    public var serviceNames: [String] {
        services.map(\.name)
    }
}

private final class AgentActivityCacheService: SanctuaryDaemonService, @unchecked Sendable {
    let name = "agent-activity-cache"
    private let cache: AgentActivityCache

    init(cache: AgentActivityCache) {
        self.cache = cache
    }

    func start() {
        cache.startContinuousRefresh(interval: 0.25)
    }

    func stop() {
        cache.stop()
    }
}

private final class ProtectedFolderWatcherService: SanctuaryDaemonService, @unchecked Sendable {
    let name = "protected-folder-watcher"
    private let watcher: ProtectedFolderWatcher

    init(watcher: ProtectedFolderWatcher) {
        self.watcher = watcher
    }

    func start() throws {
        try watcher.start()
    }

    func stop() {
        watcher.stop()
    }
}

private final class ExtensionStorageProtectionDaemonService: SanctuaryDaemonService, @unchecked Sendable {
    let name = "extension-storage-protection"
    private let service: ExtensionStorageProtectionService

    init(service: ExtensionStorageProtectionService) {
        self.service = service
    }

    func start() throws {
        try service.start()
    }

    func stop() {
        service.stop()
    }
}

private final class ServiceInventoryDaemonService: SanctuaryDaemonService, @unchecked Sendable {
    let name = "service-inventory"
    private let inventory: ServiceInventory

    init(inventory: ServiceInventory) {
        self.inventory = inventory
    }

    func start() {
        inventory.startContinuousRefresh(interval: 5.0)
    }

    func stop() {
        inventory.stop()
    }
}
