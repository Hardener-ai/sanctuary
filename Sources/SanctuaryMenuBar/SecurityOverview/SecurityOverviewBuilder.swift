// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SanctuaryCore

public enum SecurityOverviewBuilder {
    public static func build(
        folders: [ProtectedFolderEntry],
        extensions: [ProtectedExtensionEntry],
        discoveredResources: [DiscoveredResource],
        dismissedResources: [DismissedResource],
        activities: [ActivityEntry],
        coverageGaps: [CoverageGapSummary],
        lastSuccessfulScanAt: Date?,
        pathExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: Date = Date()
    ) -> SecurityOverviewSnapshot {
        var buckets = Dictionary(
            uniqueKeysWithValues: SecurityOverviewCategoryID.allCases.map { ($0, [SecurityOverviewResource]()) }
        )

        for folder in folders {
            let categoryID = category(forPath: folder.path, source: folder.source)
            let missing = !pathExists(folder.path)
            buckets[categoryID, default: []].append(
                SecurityOverviewResource(
                    id: "folder:\(folder.path)",
                    categoryID: categoryID,
                    title: title(forPath: folder.path, categoryID: categoryID),
                    displayPath: folder.displayPath,
                    state: missing ? .missing : .protected,
                    risk: risk(for: categoryID),
                    lastActivityAt: mostRecentActivity(for: categoryID, activities: activities)
                )
            )
        }

        for item in extensions {
            let categoryID = extensionCategory(friendlyName: item.friendlyName, extensionID: item.extensionID)
            buckets[categoryID, default: []].append(
                SecurityOverviewResource(
                    id: "extension:\(item.profilePath):\(item.extensionID)",
                    categoryID: categoryID,
                    title: item.friendlyName,
                    displayPath: item.profile,
                    state: .protected,
                    risk: risk(for: categoryID),
                    lastActivityAt: mostRecentActivity(for: categoryID, activities: activities)
                )
            )
        }

        for profile in Set(extensions.map(\.profile)).sorted() {
            buckets[.browserProfileSessions, default: []].append(
                SecurityOverviewResource(
                    id: "browser-session:\(profile)",
                    categoryID: .browserProfileSessions,
                    title: profile,
                    displayPath: "CDP Guard",
                    state: .protected,
                    risk: risk(for: .browserProfileSessions),
                    lastActivityAt: mostRecentActivity(for: .browserProfileSessions, activities: activities)
                )
            )
        }

        let protectedKeys = Set(
            folders.map { resourceKey(path: $0.path) } +
            extensions.map { resourceKey(profilePath: $0.profilePath, extensionID: $0.extensionID) }
        )
        for resource in discoveredResources {
            guard !protectedKeys.contains(resourceKey(resource)) else {
                continue
            }
            buckets[resource.categoryID, default: []].append(
                SecurityOverviewResource(
                    id: "discovered:\(resource.id)",
                    categoryID: resource.categoryID,
                    title: resource.title,
                    displayPath: resource.path.map { DefaultSensitivePaths.displayPath($0) } ?? profileDisplay(resource),
                    state: .needsReview,
                    risk: risk(for: resource.categoryID),
                    lastActivityAt: resource.discoveredAt
                )
            )
        }

        for resource in dismissedResources {
            buckets[resource.categoryID, default: []].append(
                SecurityOverviewResource(
                    id: "dismissed:\(resource.id)",
                    categoryID: resource.categoryID,
                    title: resource.title,
                    displayPath: resource.path.map { DefaultSensitivePaths.displayPath($0) },
                    state: .dismissed,
                    risk: risk(for: resource.categoryID),
                    lastActivityAt: resource.dismissedAt
                )
            )
        }

        appendUnsupportedPlaceholders(to: &buckets)

        let categories = SecurityOverviewCategoryID.allCases.map { id in
            let resources = (buckets[id] ?? []).sorted(by: sortResources)
            return SecurityOverviewCategory(
                id: id,
                title: title(for: id),
                subtitle: subtitle(for: id),
                risk: risk(for: id),
                resources: resources,
                mostRecentActivityAt: mostRecentActivity(for: id, activities: activities)
            )
        }

        return SecurityOverviewSnapshot(
            categories: categories,
            coverageGaps: coverageGaps,
            lastSuccessfulScanAt: lastSuccessfulScanAt,
            hasActiveTamper: hasActiveTamper(activities: activities, now: now)
        )
    }

    public static func defaultDiscoveredResources(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [DiscoveredResource] {
        let folderResources = DefaultSensitivePaths.existingPaths(homeDirectory: homeDirectory, fileManager: fileManager).map { path in
            let categoryID = category(forPath: path, source: "default")
            return DiscoveredResource(
                categoryID: categoryID,
                title: title(forPath: path, categoryID: categoryID),
                path: path,
                discoveredAt: Date()
            )
        }

        let extensionResources = BrowserProfileExtensionDiscovery
            .discoverInstalledKnownExtensions(homeDirectory: homeDirectory, fileManager: fileManager)
            .map { installed in
                DiscoveredResource(
                    categoryID: extensionCategory(friendlyName: installed.friendlyName, extensionID: installed.extensionID),
                    title: installed.friendlyName,
                    profilePath: installed.profilePath,
                    extensionID: installed.extensionID,
                    discoveredAt: Date()
                )
            }

        return (folderResources + extensionResources).sorted {
            if $0.categoryID.rawValue != $1.categoryID.rawValue {
                return $0.categoryID.rawValue < $1.categoryID.rawValue
            }
            return $0.title < $1.title
        }
    }

    public static func defaultCoverageGaps() -> [CoverageGapSummary] {
        for candidate in coverageGapCandidatePaths() {
            guard let markdown = try? String(contentsOfFile: candidate, encoding: .utf8) else {
                continue
            }
            let parsed = coverageGaps(from: markdown)
            if !parsed.isEmpty {
                return parsed
            }
        }
        return fallbackCoverageGaps()
    }

    public static func coverageGaps(from markdown: String) -> [CoverageGapSummary] {
        var results: [CoverageGapSummary] = []
        var current: (id: String, title: String, status: String?, severity: String?)?

        func flush() {
            guard let item = current else {
                return
            }
            results.append(
                CoverageGapSummary(
                    id: item.id,
                    title: item.title,
                    status: item.status ?? "Unknown",
                    severity: item.severity ?? "Unknown"
                )
            )
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### Gap ") {
                flush()
                let trimmed = line.replacingOccurrences(of: "### ", with: "")
                let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                current = (
                    id: parts.first ?? trimmed,
                    title: parts.count > 1 ? parts[1] : trimmed,
                    status: nil,
                    severity: nil
                )
            } else if line.hasPrefix("**Status:**") {
                current?.status = line.replacingOccurrences(of: "**Status:**", with: "").trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("**Severity:**") {
                current?.severity = line.replacingOccurrences(of: "**Severity:**", with: "").trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
        }
        flush()
        return results
    }

    public static func category(forPath path: String, source: String = "default") -> SecurityOverviewCategoryID {
        let lower = path.lowercased()
        if lower.contains("/.ssh") {
            return .sshIdentities
        }
        if lower.contains("/.aws") || lower.contains("/.azure") || lower.contains("/.gcloud") {
            return .cloudCredentials
        }
        if lower.contains("/.gnupg") {
            return .gpgKeys
        }
        if lower.contains("ledger live") || lower.contains("trezor") || lower.contains("electrum") || lower.contains("exodus") || lower.contains("atomic") || lower.contains("/.bitcoin") || lower.contains("/.config/solana") || lower.contains("/.config/sui") || lower.contains("kek-wallet") {
            return .standaloneWalletApps
        }
        if lower.contains("1password") || lower.contains("bitwarden") || lower.contains("dashlane") || lower.contains("lastpass") || lower.contains("nordpass") || lower.contains("enpass") || lower.contains("keepass") {
            return .standalonePasswordManagerApps
        }
        return .customResources
    }

    public static func extensionCategory(friendlyName: String, extensionID: String) -> SecurityOverviewCategoryID {
        let name = (KnownExtensions.displayName(for: extensionID) ?? friendlyName).lowercased()
        if passwordManagerNames.contains(where: { name.contains($0) }) {
            return .browserPasswordManagerExtensions
        }
        return .browserWalletExtensions
    }

    public static func risk(for categoryID: SecurityOverviewCategoryID) -> SecurityOverviewRiskLevel {
        switch categoryID {
        case .sshIdentities, .browserWalletExtensions, .browserPasswordManagerExtensions, .browserProfileSessions:
            return .critical
        case .cloudCredentials, .gpgKeys, .standaloneWalletApps, .standalonePasswordManagerApps:
            return .high
        case .customResources:
            return .medium
        case .shellHistory:
            return .low
        }
    }

    public static func title(for categoryID: SecurityOverviewCategoryID) -> String {
        switch categoryID {
        case .sshIdentities:
            return "SSH identities"
        case .cloudCredentials:
            return "Cloud credentials"
        case .gpgKeys:
            return "GPG keys"
        case .browserWalletExtensions:
            return "Wallet extensions"
        case .browserPasswordManagerExtensions:
            return "Password manager extensions"
        case .standaloneWalletApps:
            return "Wallet apps"
        case .standalonePasswordManagerApps:
            return "Password manager apps"
        case .browserProfileSessions:
            return "Browser sessions"
        case .customResources:
            return "Custom resources"
        case .shellHistory:
            return "Shell history"
        }
    }

    private static let passwordManagerNames = [
        "1password", "bitwarden", "dashlane", "lastpass", "keepass", "nordpass", "enpass", "keeper", "proton pass"
    ]

    private static func subtitle(for categoryID: SecurityOverviewCategoryID) -> String {
        switch categoryID {
        case .sshIdentities:
            return "Keys and deploy identities"
        case .cloudCredentials:
            return "AWS, GCP, Azure, and CLI secrets"
        case .gpgKeys:
            return "Signing and encryption material"
        case .browserWalletExtensions:
            return "Chromium wallet extension storage"
        case .browserPasswordManagerExtensions:
            return "Chromium password manager storage"
        case .standaloneWalletApps:
            return "Desktop wallet data directories"
        case .standalonePasswordManagerApps:
            return "Desktop password manager data"
        case .browserProfileSessions:
            return "CDP Guard browser attach surface"
        case .customResources:
            return "User-added protected paths"
        case .shellHistory:
            return "Terminal history and state"
        }
    }

    private static func title(forPath path: String, categoryID: SecurityOverviewCategoryID) -> String {
        switch categoryID {
        case .sshIdentities:
            return "SSH key directory"
        case .cloudCredentials:
            if path.lowercased().contains("/.aws") {
                return "AWS credentials"
            }
            if path.lowercased().contains("/.azure") {
                return "Azure credentials"
            }
            if path.lowercased().contains("/.gcloud") {
                return "GCP credentials"
            }
            return "Cloud credentials"
        case .gpgKeys:
            return "GPG keyring"
        case .standaloneWalletApps:
            return "Wallet data"
        case .standalonePasswordManagerApps:
            return "Password manager data"
        case .customResources:
            return "Custom resource"
        case .browserWalletExtensions, .browserPasswordManagerExtensions, .browserProfileSessions, .shellHistory:
            return DefaultSensitivePaths.displayPath(path)
        }
    }

    private static func appendUnsupportedPlaceholders(to buckets: inout [SecurityOverviewCategoryID: [SecurityOverviewResource]]) {
        let unsupported: [(SecurityOverviewCategoryID, String)] = [
            (.shellHistory, "Shell history detection is tracked as a v0.2 lower-priority surface")
        ]

        for (categoryID, title) in unsupported where buckets[categoryID, default: []].isEmpty {
            buckets[categoryID, default: []].append(
                SecurityOverviewResource(
                    id: "unsupported:\(categoryID.rawValue)",
                    categoryID: categoryID,
                    title: title,
                    state: .unsupported,
                    risk: risk(for: categoryID)
                )
            )
        }
    }

    private static func sortResources(_ lhs: SecurityOverviewResource, _ rhs: SecurityOverviewResource) -> Bool {
        if stateRank(lhs.state) != stateRank(rhs.state) {
            return stateRank(lhs.state) < stateRank(rhs.state)
        }
        if lhs.title != rhs.title {
            return lhs.title < rhs.title
        }
        return (lhs.displayPath ?? "") < (rhs.displayPath ?? "")
    }

    private static func stateRank(_ state: SecurityOverviewResourceState) -> Int {
        switch state {
        case .needsReview:
            return 0
        case .missing:
            return 1
        case .protected:
            return 2
        case .inactive:
            return 3
        case .dismissed:
            return 4
        case .unsupported:
            return 5
        }
    }

    private static func profileDisplay(_ resource: DiscoveredResource) -> String? {
        guard let profilePath = resource.profilePath else {
            return nil
        }
        return MenuBarDataSource.profileDisplayName(for: profilePath)
    }

    private static func mostRecentActivity(for categoryID: SecurityOverviewCategoryID, activities: [ActivityEntry]) -> Date? {
        activities
            .filter { activityMatches($0, categoryID: categoryID) }
            .map(\.timestamp)
            .max()
    }

    private static func activityMatches(_ activity: ActivityEntry, categoryID: SecurityOverviewCategoryID) -> Bool {
        let summary = activity.summaryText.lowercased()
        switch categoryID {
        case .sshIdentities:
            return summary.contains(".ssh") || summary.contains("ssh")
        case .cloudCredentials:
            return summary.contains(".aws") || summary.contains(".azure") || summary.contains(".gcloud") || summary.contains("cloud")
        case .gpgKeys:
            return summary.contains(".gnupg") || summary.contains("gpg")
        case .browserWalletExtensions:
            return KnownExtensions.all
                .filter { extensionInfo in
                    let name = extensionInfo.friendlyName.lowercased()
                    return !passwordManagerNames.contains { name.contains($0) }
                }
                .contains { summary.contains($0.friendlyName.lowercased()) }
        case .browserPasswordManagerExtensions:
            return passwordManagerNames.contains { summary.contains($0) }
        case .browserProfileSessions:
            return summary.contains("attach") || summary.contains("cdp") || summary.contains("brave") || summary.contains("chrome")
        case .standaloneWalletApps:
            return summary.contains("ledger") || summary.contains("trezor") || summary.contains("wallet")
        case .standalonePasswordManagerApps:
            return summary.contains("password")
        case .customResources:
            return summary.contains("protected")
        case .shellHistory:
            return summary.contains("shell") || summary.contains("history")
        }
    }

    private static func hasActiveTamper(activities: [ActivityEntry], now: Date) -> Bool {
        activities.contains { entry in
            now.timeIntervalSince(entry.timestamp) <= 300 &&
            (entry.summaryText.localizedCaseInsensitiveContains("tamper") || entry.attributionText.localizedCaseInsensitiveContains("tamper"))
        }
    }

    private static func resourceKey(_ resource: DiscoveredResource) -> String {
        if let path = resource.path {
            return resourceKey(path: path)
        }
        if let profilePath = resource.profilePath, let extensionID = resource.extensionID {
            return resourceKey(profilePath: profilePath, extensionID: extensionID)
        }
        return resource.id
    }

    private static func resourceKey(path: String) -> String {
        "path:\(path)"
    }

    private static func resourceKey(profilePath: String, extensionID: String) -> String {
        "extension:\(profilePath):\(extensionID.lowercased())"
    }

    private static func coverageGapCandidatePaths() -> [String] {
        [
            "specs/COVERAGE_GAPS.md",
            "\(FileManager.default.currentDirectoryPath)/specs/COVERAGE_GAPS.md",
            Bundle.main.resourceURL?.appendingPathComponent("COVERAGE_GAPS.md").path
        ].compactMap { $0 }
    }

    private static func fallbackCoverageGaps() -> [CoverageGapSummary] {
        [
            CoverageGapSummary(id: "Gap 1", title: "Filesystem read prevention", status: "Detection only", severity: "High"),
            CoverageGapSummary(id: "Gap 3", title: "Clipboard sniffing", status: "Not covered", severity: "High"),
            CoverageGapSummary(id: "Gap 4", title: "Screen capture", status: "Not covered", severity: "High"),
            CoverageGapSummary(id: "Gap 5", title: "Accessibility API automation", status: "Not covered", severity: "High")
        ]
    }
}
