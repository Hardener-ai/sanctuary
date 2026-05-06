// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import AppKit
import SwiftUI
import Testing
import SanctuaryCore
@testable import SanctuaryMenuBar

struct SecurityOverviewTests {
    @Test func overviewIncludesEveryCategory() {
        let snapshot = Self.snapshot()

        #expect(snapshot.categories.map(\.id) == SecurityOverviewCategoryID.allCases)
    }

    @Test func sshFolderCountsAsProtectedIdentity() {
        let snapshot = Self.snapshot(folders: [Self.folder("\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh")])

        #expect(snapshot.category(.sshIdentities)?.protectedCount == 1)
        #expect(snapshot.category(.sshIdentities)?.resources.first?.title == "SSH key directory")
    }

    @Test func awsFolderCountsAsCloudCredentials() {
        let snapshot = Self.snapshot(folders: [Self.folder("\(NSHomeDirectory())/.aws", displayPath: "~/.aws")])

        #expect(snapshot.category(.cloudCredentials)?.protectedCount == 1)
        #expect(snapshot.category(.cloudCredentials)?.resources.first?.title == "AWS credentials")
    }

    @Test func gpgFolderCountsAsGPGKeys() {
        let snapshot = Self.snapshot(folders: [Self.folder("\(NSHomeDirectory())/.gnupg", displayPath: "~/.gnupg")])

        #expect(snapshot.category(.gpgKeys)?.protectedCount == 1)
    }

    @Test func userAddedFolderCountsAsCustomResource() {
        let snapshot = Self.snapshot(folders: [Self.folder("/tmp/sanctuary-custom", source: "user")])

        #expect(snapshot.category(.customResources)?.protectedCount == 1)
    }

    @Test func standaloneWalletPathCountsAsWalletApp() {
        let snapshot = Self.snapshot(folders: [
            Self.folder("\(NSHomeDirectory())/Library/Application Support/Ledger Live", displayPath: "~/Library/Application Support/Ledger Live")
        ])

        #expect(snapshot.category(.standaloneWalletApps)?.protectedCount == 1)
    }

    @Test func standalonePasswordManagerPathCountsAsPasswordManagerApp() {
        let snapshot = Self.snapshot(folders: [
            Self.folder("\(NSHomeDirectory())/Library/Application Support/1Password", displayPath: "~/Library/Application Support/1Password")
        ])

        #expect(snapshot.category(.standalonePasswordManagerApps)?.protectedCount == 1)
    }

    @Test func metamaskExtensionCountsAsWalletExtension() {
        let snapshot = Self.snapshot(extensions: [Self.extension(name: "MetaMask", id: "nkbihfbeogaeaoehlefnkodbefgpgknn")])

        #expect(snapshot.category(.browserWalletExtensions)?.protectedCount == 1)
        #expect(snapshot.category(.browserPasswordManagerExtensions)?.protectedCount == 0)
    }

    @Test func onePasswordExtensionCountsAsPasswordManagerExtension() {
        let snapshot = Self.snapshot(extensions: [Self.extension(name: "1Password", id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa")])

        #expect(snapshot.category(.browserPasswordManagerExtensions)?.protectedCount == 1)
        #expect(snapshot.category(.browserWalletExtensions)?.protectedCount == 0)
    }

    @Test func protectedExtensionCreatesBrowserSessionCoverage() {
        let snapshot = Self.snapshot(extensions: [Self.extension(profile: "Brave Default")])

        #expect(snapshot.category(.browserProfileSessions)?.protectedCount == 1)
        #expect(snapshot.category(.browserProfileSessions)?.resources.first?.displayPath == "CDP Guard")
    }

    @Test func browserSessionCoverageIsDistinctByProfile() {
        let snapshot = Self.snapshot(extensions: [
            Self.extension(profile: "Brave Default"),
            Self.extension(name: "Phantom", id: "bfnaelmomeimhlpmgjnjophhpkkoljpa", profile: "Brave Default"),
            Self.extension(name: "Phantom", id: "bfnaelmomeimhlpmgjnjophhpkkoljpa", profile: "Chrome Profile 1")
        ])

        #expect(snapshot.category(.browserProfileSessions)?.protectedCount == 2)
    }

    @Test func discoveredFolderAppearsAsNeedsReview() {
        let snapshot = Self.snapshot(discovered: [
            DiscoveredResource(categoryID: .sshIdentities, title: "SSH key directory", path: "\(NSHomeDirectory())/.ssh")
        ])

        #expect(snapshot.category(.sshIdentities)?.unprotectedCount == 1)
    }

    @Test func discoveredProtectedFolderIsDeduplicated() {
        let path = "\(NSHomeDirectory())/.ssh"
        let snapshot = Self.snapshot(
            folders: [Self.folder(path, displayPath: "~/.ssh")],
            discovered: [DiscoveredResource(categoryID: .sshIdentities, title: "SSH key directory", path: path)]
        )

        #expect(snapshot.category(.sshIdentities)?.resources.count == 1)
        #expect(snapshot.category(.sshIdentities)?.protectedCount == 1)
    }

    @Test func discoveredExtensionAppearsAsNeedsReview() {
        let snapshot = Self.snapshot(discovered: [
            DiscoveredResource(
                categoryID: .browserWalletExtensions,
                title: "MetaMask",
                profilePath: "/Users/tg/Library/Application Support/BraveSoftware/Brave-Browser/Default",
                extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn"
            )
        ])

        #expect(snapshot.category(.browserWalletExtensions)?.unprotectedCount == 1)
    }

    @Test func dismissedResourceIsCountedSeparately() {
        let snapshot = Self.snapshot(dismissed: [
            DismissedResource(categoryID: .cloudCredentials, title: "Azure credentials", path: "\(NSHomeDirectory())/.azure")
        ])

        #expect(snapshot.category(.cloudCredentials)?.dismissedCount == 1)
    }

    @Test func missingProtectedFolderIsReportedAsMissing() {
        let snapshot = Self.snapshot(
            folders: [Self.folder("\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh")],
            pathExists: { _ in false }
        )

        #expect(snapshot.category(.sshIdentities)?.missingCount == 1)
        #expect(snapshot.category(.sshIdentities)?.protectedCount == 0)
    }

    @Test func shellHistoryShowsUnsupportedPlaceholder() {
        let snapshot = Self.snapshot()

        #expect(snapshot.category(.shellHistory)?.unsupportedCount == 1)
        #expect(snapshot.category(.shellHistory)?.summaryText == "Not yet supported")
    }

    @Test func categorySummaryIncludesRelevantCounts() {
        let snapshot = Self.snapshot(
            folders: [Self.folder("\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh")],
            discovered: [DiscoveredResource(categoryID: .sshIdentities, title: "Deploy key", path: "\(NSHomeDirectory())/.ssh/deploy_key")]
        )

        #expect(snapshot.category(.sshIdentities)?.summaryText == "2 detected, 1 protected, 1 needs review")
    }

    @Test func sshRiskIsCritical() {
        #expect(SecurityOverviewBuilder.risk(for: .sshIdentities) == .critical)
    }

    @Test func customRiskIsMedium() {
        #expect(SecurityOverviewBuilder.risk(for: .customResources) == .medium)
    }

    @Test func shellHistoryRiskIsLow() {
        #expect(SecurityOverviewBuilder.risk(for: .shellHistory) == .low)
    }

    @Test func sshActivitySetsMostRecentActivity() {
        let activity = ActivityEntry(
            timestamp: Date(timeIntervalSince1970: 100),
            relativeTimeText: "just now",
            summaryText: "Codex accessed ~/.ssh",
            attributionText: "Detected · definite",
            isDenial: false
        )
        let snapshot = Self.snapshot(activities: [activity])

        #expect(snapshot.category(.sshIdentities)?.mostRecentActivityAt == activity.timestamp)
    }

    @Test func cdpActivitySetsBrowserSessionActivity() {
        let activity = ActivityEntry(
            timestamp: Date(timeIntervalSince1970: 200),
            relativeTimeText: "just now",
            summaryText: "Codex tried to attach to Brave",
            attributionText: "Blocked",
            isDenial: true
        )
        let snapshot = Self.snapshot(activities: [activity])

        #expect(snapshot.category(.browserProfileSessions)?.mostRecentActivityAt == activity.timestamp)
    }

    @Test func recentTamperActivitySetsTamperFlag() {
        let snapshot = Self.snapshot(activities: [
            ActivityEntry(
                timestamp: Date(timeIntervalSince1970: 1_000),
                relativeTimeText: "just now",
                summaryText: "Tamper detected: pf_rules_flushed",
                attributionText: "",
                isDenial: false
            )
        ], now: Date(timeIntervalSince1970: 1_100))

        #expect(snapshot.hasActiveTamper)
    }

    @Test func oldTamperActivityDoesNotSetTamperFlag() {
        let snapshot = Self.snapshot(activities: [
            ActivityEntry(
                timestamp: Date(timeIntervalSince1970: 1_000),
                relativeTimeText: "10 minutes ago",
                summaryText: "Tamper detected: pf_rules_flushed",
                attributionText: "",
                isDenial: false
            )
        ], now: Date(timeIntervalSince1970: 1_400))

        #expect(!snapshot.hasActiveTamper)
    }

    @Test func coverageGapParserReadsGapTitles() {
        let gaps = SecurityOverviewBuilder.coverageGaps(from: Self.coverageMarkdown)

        #expect(gaps.map(\.title) == ["Filesystem read prevention", "Clipboard sniffing"])
    }

    @Test func coverageGapParserReadsStatusAndSeverity() throws {
        let gap = try #require(SecurityOverviewBuilder.coverageGaps(from: Self.coverageMarkdown).first)

        #expect(gap.status == "Detection only")
        #expect(gap.severity == "High")
    }

    @Test func defaultCoverageGapsAreAvailableForRuntimeUI() {
        #expect(!SecurityOverviewBuilder.defaultCoverageGaps().isEmpty)
    }

    @Test func resourcesSortNeedsReviewBeforeProtected() throws {
        let snapshot = Self.snapshot(
            folders: [Self.folder("\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh")],
            discovered: [DiscoveredResource(categoryID: .sshIdentities, title: "Deploy key", path: "\(NSHomeDirectory())/.ssh/deploy_key")]
        )
        let states = try #require(snapshot.category(.sshIdentities)?.resources.map(\.state))

        #expect(states == [.needsReview, .protected])
    }

    @Test func dataSourceRefreshBuildsOverviewFromProtectedState() {
        let source = MenuBarDataSource(
            folderLoader: { [ProtectedFolder(path: "\(NSHomeDirectory())/.ssh", addedAt: 0, source: "default")] },
            extensionLoader: { [ProtectedExtension(profilePath: "/Users/tg/Library/Application Support/BraveSoftware/Brave-Browser/Default", extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn", friendlyName: "MetaMask", addedAt: 0)] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            coverageGapLoader: { [Self.gap] },
            pathExists: { _ in true }
        )

        source.refresh()

        #expect(source.securityOverview.category(.sshIdentities)?.protectedCount == 1)
        #expect(source.securityOverview.category(.browserWalletExtensions)?.protectedCount == 1)
    }

    @MainActor
    @Test func dataSourceRescanUpdatesTimestampAndDiscoveredResources() {
        let scanDate = Date(timeIntervalSince1970: 500)
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            discoveredResourceLoader: {
                [DiscoveredResource(categoryID: .sshIdentities, title: "SSH key directory", path: "\(NSHomeDirectory())/.ssh")]
            },
            coverageGapLoader: { [Self.gap] },
            now: { scanDate }
        )

        source.rescanSecurityOverview()

        #expect(source.lastSecurityOverviewScanAt == scanDate)
        #expect(source.securityOverview.category(.sshIdentities)?.unprotectedCount == 1)
    }

    @Test func dataSourceRefreshDoesNotRunDiscoveryScan() {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let state = State()
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            discoveredResourceLoader: {
                state.lock.withLock {
                    state.calls += 1
                }
                return []
            },
            coverageGapLoader: { [Self.gap] }
        )

        source.refresh()

        #expect(state.lock.withLock { state.calls } == 0)
    }

    @MainActor
    @Test func dataSourceRescanRunsDiscoveryExactlyOnce() {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var calls = 0
        }
        let state = State()
        let source = MenuBarDataSource(
            folderLoader: { [] },
            extensionLoader: { [] },
            inventoryLoader: { [] },
            daemonIsRunning: { true },
            auditLogPath: { "/tmp/missing-audit.log" },
            discoveredResourceLoader: {
                state.lock.withLock {
                    state.calls += 1
                }
                return []
            },
            coverageGapLoader: { [Self.gap] }
        )

        source.rescanSecurityOverview()

        #expect(state.lock.withLock { state.calls } == 1)
    }

    @MainActor
    @Test func captureSecurityOverviewScreenshotsWhenRequested() throws {
        guard let outputDirectory = ProcessInfo.processInfo.environment["SANCTUARY_SECURITY_OVERVIEW_SCREENSHOT_DIR"] else {
            return
        }

        let root = URL(fileURLWithPath: outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureSnapshot = Self.snapshot(
            folders: [
                Self.folder("\(NSHomeDirectory())/.ssh", displayPath: "~/.ssh"),
                Self.folder("\(NSHomeDirectory())/.aws", displayPath: "~/.aws")
            ],
            extensions: [
                Self.extension(name: "MetaMask", id: "nkbihfbeogaeaoehlefnkodbefgpgknn", profile: "Brave Default"),
                Self.extension(name: "1Password", id: "aeblfdkhhhdcdjpifhhbdiojplfjncoa", profile: "Chrome Profile 1")
            ],
            discovered: [
                DiscoveredResource(categoryID: .browserWalletExtensions, title: "Phantom", profilePath: "/Users/tg/Library/Application Support/BraveSoftware/Brave-Browser/Default", extensionID: "bfnaelmomeimhlpmgjnjophhpkkoljpa")
            ],
            activities: [
                ActivityEntry(timestamp: Date(), relativeTimeText: "just now", summaryText: "Codex tried to read MetaMask", attributionText: "Detected · definite", isDenial: false)
            ]
        )
        let snapshot = SecurityOverviewSnapshot(
            categories: fixtureSnapshot.categories,
            coverageGaps: fixtureSnapshot.coverageGaps,
            lastSuccessfulScanAt: Date(),
            hasActiveTamper: fixtureSnapshot.hasActiveTamper
        )

        try Self.render(
            SecurityOverviewSection(snapshot: snapshot)
                .frame(width: 320)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light),
            to: root.appendingPathComponent("security-overview-light.png")
        )
        try Self.render(
            SecurityOverviewSection(snapshot: snapshot)
                .frame(width: 320)
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark),
            to: root.appendingPathComponent("security-overview-dark.png")
        )
    }

    private static let gap = CoverageGapSummary(
        id: "Gap 1",
        title: "Filesystem read prevention",
        status: "Detection only",
        severity: "High"
    )

    private static let coverageMarkdown = """
    ### Gap 1: Filesystem read prevention
    **Status:** Detection only
    **Severity:** High.

    ### Gap 3: Clipboard sniffing
    **Status:** Not covered
    **Severity:** High.
    """

    private static func snapshot(
        folders: [ProtectedFolderEntry] = [],
        extensions: [ProtectedExtensionEntry] = [],
        discovered: [DiscoveredResource] = [],
        dismissed: [DismissedResource] = [],
        activities: [ActivityEntry] = [],
        pathExists: @escaping (String) -> Bool = { _ in true },
        now: Date = Date(timeIntervalSince1970: 1_000)
    ) -> SecurityOverviewSnapshot {
        SecurityOverviewBuilder.build(
            folders: folders,
            extensions: extensions,
            discoveredResources: discovered,
            dismissedResources: dismissed,
            activities: activities,
            coverageGaps: [gap],
            lastSuccessfulScanAt: Date(timeIntervalSince1970: 50),
            pathExists: pathExists,
            now: now
        )
    }

    private static func folder(_ path: String, displayPath: String? = nil, source: String = "default") -> ProtectedFolderEntry {
        ProtectedFolderEntry(path: path, displayPath: displayPath ?? path, source: source)
    }

    private static func `extension`(
        name: String = "MetaMask",
        id: String = "nkbihfbeogaeaoehlefnkodbefgpgknn",
        profilePath: String = "/Users/tg/Library/Application Support/BraveSoftware/Brave-Browser/Default",
        profile: String = "Brave Default"
    ) -> ProtectedExtensionEntry {
        ProtectedExtensionEntry(
            profilePath: profilePath,
            extensionID: id,
            friendlyName: name,
            profile: profile
        )
    }

    @MainActor
    private static func render<V: View>(_ view: V, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw ScreenshotError.renderFailed
        }
        try data.write(to: url)
    }

    private enum ScreenshotError: Error {
        case renderFailed
    }
}
