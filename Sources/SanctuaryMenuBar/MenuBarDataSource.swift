// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Observation
import SanctuaryCore

public enum ProtectionStatus: Equatable, Sendable {
    case active
    case inactive
    case noDaemon
    case starting
    case requiresApproval
}

public enum CDPGuardHealth: Equatable, Sendable {
    case healthy
    case rulesReloaded(timestamp: Date)
    case suspectedTamper(reason: String)
}

public struct ProtectedFolderEntry: Equatable, Sendable {
    public let path: String
    public let displayPath: String
    public let source: String

    public init(path: String? = nil, displayPath: String, source: String) {
        self.path = path ?? displayPath
        self.displayPath = displayPath
        self.source = source
    }
}

public struct ProtectedExtensionEntry: Equatable, Sendable {
    public let profilePath: String
    public let extensionID: String
    public let friendlyName: String
    public let profile: String

    public init(
        profilePath: String = "",
        extensionID: String = "",
        friendlyName: String,
        profile: String
    ) {
        self.profilePath = profilePath
        self.extensionID = extensionID
        self.friendlyName = friendlyName
        self.profile = profile
    }
}

public struct AgentGroup: Equatable, Sendable {
    public let rootIdentity: String
    public let category: InventoryCategory
    public let processCount: Int
    public let representativePid: pid_t
    public let representativeVerdict: AgentVerdict

    public init(
        rootIdentity: String,
        category: InventoryCategory,
        processCount: Int,
        representativePid: pid_t,
        representativeVerdict: AgentVerdict
    ) {
        self.rootIdentity = rootIdentity
        self.category = category
        self.processCount = processCount
        self.representativePid = representativePid
        self.representativeVerdict = representativeVerdict
    }
}

@Observable
public final class MenuBarDataSource {
    public var status: ProtectionStatus = .inactive
    public var folders: [ProtectedFolderEntry] = []
    public var extensions: [ProtectedExtensionEntry] = []
    public var agents: [InventoryEntry] = []
    public var activities: [ActivityEntry] = []
    public var lastDenialAt: Date?
    public var userTaggedAgentCount: Int = 0
    public var trustedPathCount: Int = 0
    public var protectionEnabled: Bool = false
    public var installationStatus: DaemonInstallation.Status = .notInstalled
    public var peerHealthStatus: PeerHealthStatus = .healthy
    public var cdpGuardHealth: CDPGuardHealth = .healthy
    public var agentGroups: [AgentGroup] {
        Self.groupAgents(agents)
    }

    @ObservationIgnored private let folderLoader: () throws -> [ProtectedFolder]
    @ObservationIgnored private let extensionLoader: () throws -> [ProtectedExtension]
    @ObservationIgnored private let inventoryLoader: () -> [InventoryEntry]
    @ObservationIgnored private let daemonIsRunning: () -> Bool
    @ObservationIgnored private let auditLogPath: () -> String
    @ObservationIgnored private let userTaggedAgentCountLoader: () -> Int
    @ObservationIgnored private let trustedPathCountLoader: () -> Int
    @ObservationIgnored private let installationStatusLoader: () -> DaemonInstallation.Status
    @ObservationIgnored private let installProtection: () async throws -> Void
    @ObservationIgnored private let uninstallProtection: () async throws -> Void
    @ObservationIgnored private let auditTailReader: AuditTailReader
    @ObservationIgnored private let activityLoader: () -> [ActivityEntry]
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timer: DispatchSourceTimer?

    private struct Snapshot {
        let folders: [ProtectedFolderEntry]
        let extensions: [ProtectedExtensionEntry]
        let agents: [InventoryEntry]
        let activities: [ActivityEntry]
        let lastDenialAt: Date?
        let userTaggedAgentCount: Int
        let trustedPathCount: Int
        let installationStatus: DaemonInstallation.Status
        let protectionEnabled: Bool
        let status: ProtectionStatus
        let cdpGuardHealth: CDPGuardHealth
    }

    public convenience init() {
        self.init(
            folderLoader: {
                try ProtectedFolderRegistry().list()
            },
            extensionLoader: {
                try ProtectedExtensionRegistry().list()
            },
            inventoryLoader: {
                Self.loadInventorySnapshot(path: SanctuaryPaths.inventorySnapshotPath())
            },
            daemonIsRunning: {
                SanctuaryDaemonDetector.statusText().hasPrefix("running")
            },
            auditLogPath: {
                SanctuaryPaths.auditLogPath()
            },
            userTaggedAgentCountLoader: {
                (try? UserTaggedAgentRegistry().list().count) ?? 0
            },
            trustedPathCountLoader: {
                (try? TrustedPathRegistry().list().count) ?? 0
            },
            installationStatusLoader: {
                DaemonInstallation.currentStatus()
            },
            installProtection: {
                try await DaemonInstallation.install()
            },
            uninstallProtection: {
                try await DaemonInstallation.uninstall()
            }
        )
    }

    public init(
        folderLoader: @escaping () throws -> [ProtectedFolder],
        extensionLoader: @escaping () throws -> [ProtectedExtension],
        inventoryLoader: @escaping () -> [InventoryEntry],
        daemonIsRunning: @escaping () -> Bool,
        auditLogPath: @escaping () -> String,
        userTaggedAgentCountLoader: @escaping () -> Int = { 0 },
        trustedPathCountLoader: @escaping () -> Int = { 0 },
        installationStatusLoader: @escaping () -> DaemonInstallation.Status = { .installed(running: true) },
        installProtection: @escaping () async throws -> Void = {},
        uninstallProtection: @escaping () async throws -> Void = {},
        activityLoader: (() -> [ActivityEntry])? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.folderLoader = folderLoader
        self.extensionLoader = extensionLoader
        self.inventoryLoader = inventoryLoader
        self.daemonIsRunning = daemonIsRunning
        self.auditLogPath = auditLogPath
        self.userTaggedAgentCountLoader = userTaggedAgentCountLoader
        self.trustedPathCountLoader = trustedPathCountLoader
        self.installationStatusLoader = installationStatusLoader
        self.installProtection = installProtection
        self.uninstallProtection = uninstallProtection
        let reader = AuditTailReader(path: auditLogPath(), now: now)
        self.auditTailReader = reader
        self.activityLoader = activityLoader ?? {
            reader.recentEntries(within: 3600, limit: 5)
        }
        self.now = now
    }

    deinit {
        stop()
    }

    public func refresh() {
        apply(loadSnapshot())
    }

    public func startAutoRefresh(interval: TimeInterval = 5.0) {
        stop()
        refreshAsync()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ai.hardener.sanctuary.menubar.refresh"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.refreshAsync()
        }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func refreshAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                return
            }
            let snapshot = self.loadSnapshot()
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    @MainActor
    public func enableProtection() async throws {
        try await installProtection()
        refresh()
    }

    @MainActor
    public func disableProtection() async throws {
        try await uninstallProtection()
        refresh()
    }

    @MainActor
    public func protectFolder(_ path: String) async throws {
        try ProtectedFolderRegistry().protect(path: path, source: "user")
        refresh()
    }

    @MainActor
    public func unprotectFolder(_ path: String) async throws {
        try ProtectedFolderRegistry().unprotect(path: path)
        refresh()
    }

    @MainActor
    public func protectExtension(_ extensionInfo: InstalledBrowserExtension) async throws {
        try ProtectedExtensionRegistry().protect(
            profilePath: extensionInfo.profilePath,
            extensionID: extensionInfo.extensionID,
            friendlyName: extensionInfo.friendlyName
        )
        refresh()
    }

    @MainActor
    public func unprotectExtension(_ entry: ProtectedExtensionEntry) async throws {
        try ProtectedExtensionRegistry().unprotect(profilePath: entry.profilePath, extensionID: entry.extensionID)
        refresh()
    }

    public func detectedExtensions() -> [InstalledBrowserExtension] {
        BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions()
    }

    private func loadSnapshot() -> Snapshot {
        let loadedFolders = (try? folderLoader()) ?? []
        let loadedExtensions = (try? extensionLoader()) ?? []
        let daemonRunning = daemonIsRunning()

        let folderEntries = loadedFolders.map {
            ProtectedFolderEntry(
                path: $0.path,
                displayPath: DefaultSensitivePaths.displayPath($0.path),
                source: $0.source
            )
        }
        let extensionEntries = loadedExtensions.map {
            ProtectedExtensionEntry(
                profilePath: $0.profilePath,
                extensionID: $0.extensionID,
                friendlyName: $0.friendlyName ?? KnownExtensions.displayName(for: $0.extensionID) ?? $0.extensionID,
                profile: Self.profileDisplayName(for: $0.profilePath)
            )
        }
        let loadedAgents = inventoryLoader()
        let loadedActivities = activityLoader()
        let loadedInstallationStatus = installationStatusLoader()
        let loadedAuditLogPath = auditLogPath()
        return Snapshot(
            folders: folderEntries,
            extensions: extensionEntries,
            agents: loadedAgents,
            activities: loadedActivities,
            lastDenialAt: loadedActivities.first(where: \.isDenial)?.timestamp,
            userTaggedAgentCount: userTaggedAgentCountLoader(),
            trustedPathCount: trustedPathCountLoader(),
            installationStatus: loadedInstallationStatus,
            protectionEnabled: Self.protectionEnabled(for: loadedInstallationStatus),
            status: Self.computeStatus(
                protectedCount: folderEntries.count + extensionEntries.count,
                daemonRunning: daemonRunning,
                installationStatus: loadedInstallationStatus
            ),
            cdpGuardHealth: Self.cdpGuardHealth(in: loadedAuditLogPath, now: now())
        )
    }

    private func apply(_ snapshot: Snapshot) {
        folders = snapshot.folders
        extensions = snapshot.extensions
        agents = snapshot.agents
        activities = snapshot.activities
        lastDenialAt = snapshot.lastDenialAt
        userTaggedAgentCount = snapshot.userTaggedAgentCount
        trustedPathCount = snapshot.trustedPathCount
        installationStatus = snapshot.installationStatus
        protectionEnabled = snapshot.protectionEnabled
        status = snapshot.status
        cdpGuardHealth = snapshot.cdpGuardHealth
    }

    public static func computeStatus(protectedCount: Int, daemonRunning: Bool) -> ProtectionStatus {
        computeStatus(protectedCount: protectedCount, daemonRunning: daemonRunning, installationStatus: nil)
    }

    public static func computeStatus(
        protectedCount: Int,
        daemonRunning: Bool,
        installationStatus: DaemonInstallation.Status?
    ) -> ProtectionStatus {
        if let installationStatus {
            switch installationStatus {
            case .notInstalled:
                return .inactive
            case .requiresApproval:
                return .requiresApproval
            case let .installed(running):
                if !running {
                    return .starting
                }
                return .active
            }
        }
        if protectedCount == 0 {
            return .inactive
        }
        return daemonRunning ? .active : .noDaemon
    }

    public static func protectionEnabled(for installationStatus: DaemonInstallation.Status) -> Bool {
        switch installationStatus {
        case .installed, .requiresApproval:
            return true
        case .notInstalled:
            return false
        }
    }

    public static func groupAgents(_ entries: [InventoryEntry]) -> [AgentGroup] {
        let entriesByPID = Dictionary(uniqueKeysWithValues: entries.map { ($0.pid, $0) })
        var grouped: [pid_t: [InventoryEntry]] = [:]

        for entry in entries {
            let root = rootEntry(for: entry, entriesByPID: entriesByPID)
            grouped[root.pid, default: []].append(entry)
        }

        return grouped.values.compactMap { group in
            guard let root = group.first(where: { entry in
                group.allSatisfy { rootEntry(for: $0, entriesByPID: entriesByPID).pid == entry.pid }
            }) ?? group.min(by: { $0.pid < $1.pid }) else {
                return nil
            }
            return AgentGroup(
                rootIdentity: root.displayName,
                category: root.category,
                processCount: group.count,
                representativePid: root.pid,
                representativeVerdict: root.verdict
            )
        }
        .sorted {
            if $0.category.rawValue != $1.category.rawValue {
                return $0.category.rawValue < $1.category.rawValue
            }
            if $0.rootIdentity != $1.rootIdentity {
                return $0.rootIdentity < $1.rootIdentity
            }
            return $0.representativePid < $1.representativePid
        }
    }

    public static func mostRecentDetectAlert(in path: String) -> Date? {
        guard let contents = tail(path: path, byteCount: 8 * 1024) else {
            return nil
        }

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.contains(#""action":"DETECT_ALERT""#),
                  let timestamp = timestamp(in: String(line))
            else {
                continue
            }
            return timestamp
        }
        return nil
    }

    public static func cdpGuardHealth(in path: String, now: Date = Date()) -> CDPGuardHealth {
        guard let contents = tail(path: path, byteCount: 16 * 1024) else {
            return .healthy
        }

        var recentTamperCount = 0
        var latestRecovery: Date?
        var latestTamper: (date: Date, reason: String)?
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let raw = String(line)
            guard raw.contains(#""policy":"cdp_guard_pf""#),
                  let timestamp = timestamp(in: raw)
            else {
                continue
            }

            let age = now.timeIntervalSince(timestamp)
            if raw.contains(#""action":"TAMPER_DETECTED""#), age <= 600 {
                recentTamperCount += 1
                if latestTamper == nil {
                    latestTamper = (timestamp, pfReason(in: raw) ?? "pf_rules_tampered")
                }
            }
            if raw.contains(#""action":"PF_RULES_VALIDATED""#) || raw.contains(#""action":"PF_RULES_MISSING""#) || raw.contains(#""action":"PF_RULES_MODIFIED""#) {
                if latestRecovery == nil, age <= 300 {
                    latestRecovery = timestamp
                }
            }
        }

        if recentTamperCount >= 3 {
            return .suspectedTamper(reason: "repeated pf rule tampering")
        }
        if let latestTamper, now.timeIntervalSince(latestTamper.date) <= 300 {
            return .rulesReloaded(timestamp: latestTamper.date)
        }
        if let latestRecovery {
            return .rulesReloaded(timestamp: latestRecovery)
        }
        return .healthy
    }

    public static func loadInventorySnapshot(path: String) -> [InventoryEntry] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InventoryEntry].self, from: data)) ?? []
    }

    public static func profileDisplayName(for profilePath: String) -> String {
        let components = URL(fileURLWithPath: profilePath).pathComponents
        var profile = components.last ?? profilePath
        let path = profilePath.lowercased()
        let browser: String
        if path.contains("/bravesoftware/brave-browser/") {
            browser = "Brave"
        } else if path.contains("/google/chrome/") {
            browser = "Chrome"
        } else if path.contains("/arc/user data/") {
            browser = "Arc"
        } else if path.contains("/microsoft edge/") {
            browser = "Edge"
        } else if path.contains("/vivaldi/") {
            browser = "Vivaldi"
        } else if path.contains("/com.operasoftware.opera") {
            browser = "Opera"
            if profile == "com.operasoftware.Opera" {
                profile = "Default"
            }
        } else {
            browser = "Browser"
        }
        return "\(browser) \(profile)"
    }

    private static func timestamp(in line: String) -> Date? {
        guard let keyRange = line.range(of: #""ts":""#) else {
            return nil
        }
        let start = keyRange.upperBound
        guard let end = line[start...].firstIndex(of: "\"") else {
            return nil
        }
        let raw = String(line[start..<end])
        return parseISO8601(raw)
    }

    private static func pfReason(in line: String) -> String? {
        guard let range = line.range(of: #"reason=[^;"]+"#, options: .regularExpression) else {
            return nil
        }
        return String(line[range]).replacingOccurrences(of: "reason=", with: "")
    }

    private static func tail(path: String, byteCount: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > byteCount ? size - byteCount : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func rootEntry(
        for entry: InventoryEntry,
        entriesByPID: [pid_t: InventoryEntry]
    ) -> InventoryEntry {
        var current = entry
        var visited: Set<pid_t> = []
        while let parentPid = current.parentPid,
              let parent = entriesByPID[parentPid],
              !visited.contains(current.pid),
              shouldGroup(current, under: parent) {
            visited.insert(current.pid)
            current = parent
        }
        return current
    }

    private static func shouldGroup(_ child: InventoryEntry, under parent: InventoryEntry) -> Bool {
        switch child.verdict {
        case let .agent(reason, _):
            switch reason {
            case let .knownList(name):
                // If one known agent launches a different known agent, show both roots.
                // Helper processes with the same known identity still collapse upward.
                return name == parent.displayName || name == child.parentDisplayName
            case .pythonRuntime, .nodeRuntime, .parentChain, .mcpServer, .serviceLaunch, .userTagged:
                return true
            }
        case .suspicious:
            return true
        case .notAgent:
            return false
        }
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
