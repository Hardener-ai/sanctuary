// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public struct InstalledBrowserExtension: Equatable, Sendable {
    public let profilePath: String
    public let extensionID: String
    public let friendlyName: String

    public init(profilePath: String, extensionID: String, friendlyName: String) {
        self.profilePath = profilePath
        self.extensionID = extensionID
        self.friendlyName = friendlyName
    }
}

public struct SanctuarySetupSummary: Equatable, Sendable {
    public let foldersProtected: Int
    public let extensionsProtected: Int
    public let auditLogPath: String
    public let daemonStatus: String

    public init(foldersProtected: Int, extensionsProtected: Int, auditLogPath: String, daemonStatus: String) {
        self.foldersProtected = foldersProtected
        self.extensionsProtected = extensionsProtected
        self.auditLogPath = auditLogPath
        self.daemonStatus = daemonStatus
    }
}

public final class SanctuarySetupFlow: @unchecked Sendable {
    public typealias Prompt = @Sendable (_ question: String, _ defaultYes: Bool) -> Bool
    public typealias Writer = @Sendable (String) -> Void

    private let folderRegistry: ProtectedFolderRegistry
    private let extensionRegistry: ProtectedExtensionRegistry
    private let defaultPaths: @Sendable () -> [String]
    private let installedExtensions: @Sendable () -> [InstalledBrowserExtension]
    private let prompt: Prompt
    private let write: Writer
    private let daemonStatus: @Sendable () -> String
    private let auditLogPath: String

    public init(
        folderRegistry: ProtectedFolderRegistry,
        extensionRegistry: ProtectedExtensionRegistry,
        defaultPaths: @escaping @Sendable () -> [String] = { DefaultSensitivePaths.existingPaths() },
        installedExtensions: @escaping @Sendable () -> [InstalledBrowserExtension] = { BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions() },
        prompt: @escaping Prompt,
        write: @escaping Writer,
        daemonStatus: @escaping @Sendable () -> String = { SanctuaryDaemonDetector.statusText() },
        auditLogPath: String = SanctuaryPaths.auditLogPath()
    ) {
        self.folderRegistry = folderRegistry
        self.extensionRegistry = extensionRegistry
        self.defaultPaths = defaultPaths
        self.installedExtensions = installedExtensions
        self.prompt = prompt
        self.write = write
        self.daemonStatus = daemonStatus
        self.auditLogPath = auditLogPath
    }

    public func run(auto: Bool = false, reset: Bool = false) throws -> SanctuarySetupSummary? {
        if reset {
            let confirmed = auto || prompt("This will clear all Sanctuary protections. Confirm [y/N]?", false)
            guard confirmed else {
                write("Reset cancelled.")
                return nil
            }
            try folderRegistry.reset()
            try extensionRegistry.reset()
        } else if try folderRegistry.isSetupComplete() {
            write("Already configured. Use --reset to re-run from scratch.")
            return nil
        }

        write("Registry: v\(AgentClassifier.registrySchemaVersion) from \(AgentClassifier.registryUpdatedDate), \(AgentClassifier.knownAgents.count) agents")

        var protectedFolders = 0
        for path in defaultPaths() {
            let display = DefaultSensitivePaths.displayPath(path)
            let accepted = auto || prompt("Protect \(display)? [Y/n]", true)
            if accepted {
                try folderRegistry.protect(path: path, source: "default")
                protectedFolders += 1
            }
        }

        var protectedExtensions = 0
        for installed in installedExtensions() {
            let accepted = auto || prompt("Protect \(installed.friendlyName) in \(installed.profilePath)? [Y/n]", true)
            if accepted {
                try extensionRegistry.protect(
                    profilePath: installed.profilePath,
                    extensionID: installed.extensionID,
                    friendlyName: installed.friendlyName
                )
                protectedExtensions += 1
            }
        }

        try folderRegistry.markSetupComplete()
        let summary = SanctuarySetupSummary(
            foldersProtected: protectedFolders,
            extensionsProtected: protectedExtensions,
            auditLogPath: auditLogPath,
            daemonStatus: daemonStatus()
        )
        write("Setup complete.")
        write("Folders protected: \(summary.foldersProtected)")
        write("Extensions protected: \(summary.extensionsProtected)")
        write("Audit log: \(summary.auditLogPath)")
        write("Daemon: \(summary.daemonStatus)")
        return summary
    }
}

public enum BrowserProfileExtensionDiscovery {
    public static func discoverInstalledKnownExtensions(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [InstalledBrowserExtension] {
        var discovered: [InstalledBrowserExtension] = []
        for profile in candidateProfiles(homeDirectory: homeDirectory, fileManager: fileManager) {
            let extensionsURL = profile.appendingPathComponent("Extensions", isDirectory: true)
            guard let contents = try? fileManager.contentsOfDirectory(
                at: extensionsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for url in contents {
                let id = url.lastPathComponent.lowercased()
                guard
                    KnownExtensions.isValidChromiumExtensionID(id),
                    let friendlyName = KnownExtensions.displayName(for: id)
                else {
                    continue
                }
                discovered.append(.init(profilePath: profile.path, extensionID: id, friendlyName: friendlyName))
            }
        }
        return discovered.sorted {
            if $0.profilePath != $1.profilePath {
                return $0.profilePath < $1.profilePath
            }
            return $0.friendlyName < $1.friendlyName
        }
    }

    static func candidateProfiles(homeDirectory: URL, fileManager: FileManager = .default) -> [URL] {
        let roots = [
            homeDirectory.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/Arc/User Data", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/Vivaldi", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Application Support/com.operasoftware.Opera", isDirectory: true)
        ]
        var profiles: [URL] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            if fileManager.fileExists(atPath: root.appendingPathComponent("Extensions", isDirectory: true).path) {
                profiles.append(root)
            }
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            profiles += children.filter { url in
                let name = url.lastPathComponent
                return name == "Default" || name.hasPrefix("Profile ")
            }
        }
        return profiles
    }
}

public struct SanctuaryStatusSnapshot: Equatable, Sendable {
    public let version: String
    public let commitHash: String
    public let registryVersion: Int
    public let registryUpdatedDate: String
    public let registryAgentCount: Int
    public let daemon: String
    public let defaultFolderCount: Int
    public let userFolderCount: Int
    public let extensionCount: Int
    public let browserProfileCount: Int
    public let recentAgentClassifications: Int
    public let recentProtectedResourceAccesses: Int
    public let recentDenials: Int
    public let auditLogPath: String
    public let auditLogSizeBytes: UInt64
    public let auditLogLineCount: Int

    public init(
        version: String = "0.1",
        commitHash: String = "unknown",
        registryVersion: Int = AgentClassifier.registrySchemaVersion,
        registryUpdatedDate: String = AgentClassifier.registryUpdatedDate,
        registryAgentCount: Int = AgentClassifier.knownAgents.count,
        daemon: String,
        defaultFolderCount: Int,
        userFolderCount: Int,
        extensionCount: Int,
        browserProfileCount: Int,
        recentAgentClassifications: Int,
        recentProtectedResourceAccesses: Int,
        recentDenials: Int,
        auditLogPath: String,
        auditLogSizeBytes: UInt64,
        auditLogLineCount: Int
    ) {
        self.version = version
        self.commitHash = commitHash
        self.registryVersion = registryVersion
        self.registryUpdatedDate = registryUpdatedDate
        self.registryAgentCount = registryAgentCount
        self.daemon = daemon
        self.defaultFolderCount = defaultFolderCount
        self.userFolderCount = userFolderCount
        self.extensionCount = extensionCount
        self.browserProfileCount = browserProfileCount
        self.recentAgentClassifications = recentAgentClassifications
        self.recentProtectedResourceAccesses = recentProtectedResourceAccesses
        self.recentDenials = recentDenials
        self.auditLogPath = auditLogPath
        self.auditLogSizeBytes = auditLogSizeBytes
        self.auditLogLineCount = auditLogLineCount
    }
}

public enum SanctuaryStatusFormatter {
    public static func format(_ snapshot: SanctuaryStatusSnapshot) -> String {
        """
        Sanctuary v\(snapshot.version) (\(snapshot.commitHash))
        Registry: v\(snapshot.registryVersion) from \(snapshot.registryUpdatedDate), \(snapshot.registryAgentCount) agents

        Daemon: \(snapshot.daemon)

        Protections:
          Folders: \(snapshot.defaultFolderCount) (default), \(snapshot.userFolderCount) (user-added)
          Extensions: \(snapshot.extensionCount)
          Browser profiles: \(snapshot.browserProfileCount)

        Recent activity (last hour):
          \(snapshot.recentAgentClassifications) agent classifications
          \(snapshot.recentProtectedResourceAccesses) protected resource accesses logged
          \(snapshot.recentDenials) denials

        Audit log: \(snapshot.auditLogPath) (\(byteCount(snapshot.auditLogSizeBytes)), \(snapshot.auditLogLineCount) lines)
        """
    }

    private static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

public enum SanctuaryStatusReader {
    public static func snapshot(
        folderRegistry: ProtectedFolderRegistry,
        extensionRegistry: ProtectedExtensionRegistry,
        auditLogPath: String = SanctuaryPaths.auditLogPath(),
        daemon: String = SanctuaryDaemonDetector.statusText(),
        commitHash: String = ProcessInfo.processInfo.environment["SANCTUARY_COMMIT"] ?? "unknown"
    ) throws -> SanctuaryStatusSnapshot {
        let folders = try folderRegistry.list()
        let extensions = try extensionRegistry.list()
        let audit = auditLogStats(path: auditLogPath)
        return SanctuaryStatusSnapshot(
            commitHash: commitHash,
            daemon: daemon,
            defaultFolderCount: folders.filter { $0.source == "default" }.count,
            userFolderCount: folders.filter { $0.source == "user" }.count,
            extensionCount: extensions.count,
            browserProfileCount: Set(extensions.map(\.profilePath)).count,
            recentAgentClassifications: 0,
            recentProtectedResourceAccesses: audit.detectAlertCount,
            recentDenials: audit.denialCount,
            auditLogPath: auditLogPath,
            auditLogSizeBytes: audit.size,
            auditLogLineCount: audit.lines
        )
    }

    private static func auditLogStats(path: String) -> (size: UInt64, lines: Int, detectAlertCount: Int, denialCount: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return (0, 0, 0, 0)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return (
            UInt64(data.count),
            lines.count,
            lines.filter { $0.contains("\"DETECT_ALERT\"") }.count,
            lines.filter { $0.contains("\"DENY") || $0.contains("\"DROP") }.count
        )
    }
}

public enum SanctuaryDaemonDetector {
    public static func statusText(
        proc: any DarwinProcProviding = DarwinProc(),
        collector: any ProcessIdentityCollecting = ProcessIdentityCollector()
    ) -> String {
        guard let pids = try? proc.listPIDs() else {
            return "not running"
        }
        for pid in CurrentProcessExclusion.filterPids(pids) {
            guard let identity = collector.collect(pid: pid) else {
                continue
            }
            if URL(fileURLWithPath: identity.executablePath).lastPathComponent == "sanctuaryd" {
                return "running (pid \(pid))"
            }
        }
        return "not running"
    }
}
