// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct SetupStatusTests {
    @Test func setupAutoProtectsExistingDefaultFolders() throws {
        let fixture = try SetupFixture()
        let folder = try fixture.makeDirectory("ssh")
        let flow = try fixture.flow(defaultPaths: [folder.path], installedExtensions: [])

        let summary = try flow.run(auto: true)

        #expect(summary?.foldersProtected == 1)
        #expect(try fixture.folderRegistry.list().map(\.path) == [ExtensionPathMaterializer.normalize(folder.path)])
        #expect(try fixture.folderRegistry.isSetupComplete())
    }

    @Test func setupInteractiveAcceptsDefaultYesForFolder() throws {
        let fixture = try SetupFixture(answers: [""])
        let folder = try fixture.makeDirectory("aws")
        let flow = try fixture.flow(defaultPaths: [folder.path], installedExtensions: [])

        let summary = try flow.run()

        #expect(summary?.foldersProtected == 1)
        #expect(fixture.output.contains("Protect \(DefaultSensitivePaths.displayPath(folder.path))? [Y/n]"))
    }

    @Test func setupInteractiveRejectsNoAnswer() throws {
        let fixture = try SetupFixture(answers: ["n"])
        let folder = try fixture.makeDirectory("gnupg")
        let flow = try fixture.flow(defaultPaths: [folder.path], installedExtensions: [])

        let summary = try flow.run()

        #expect(summary?.foldersProtected == 0)
        #expect(try fixture.folderRegistry.list().isEmpty)
    }

    @Test func setupAutoProtectsInstalledKnownExtensions() throws {
        let fixture = try SetupFixture()
        let installed = InstalledBrowserExtension(
            profilePath: "/tmp/profile",
            extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn",
            friendlyName: "MetaMask"
        )
        let flow = try fixture.flow(defaultPaths: [], installedExtensions: [installed])

        let summary = try flow.run(auto: true)

        #expect(summary?.extensionsProtected == 1)
        #expect(try fixture.extensionRegistry.list().first?.friendlyName == "MetaMask")
    }

    @Test func setupInteractivePromptsForExtension() throws {
        let fixture = try SetupFixture(answers: [""])
        let installed = InstalledBrowserExtension(
            profilePath: "/tmp/profile",
            extensionID: "bfnaelmomeimhlpmgjnjophhpkkoljpa",
            friendlyName: "Phantom"
        )
        let flow = try fixture.flow(defaultPaths: [], installedExtensions: [installed])

        _ = try flow.run()

        #expect(fixture.output.contains("Protect Phantom in /tmp/profile? [Y/n]"))
        #expect(try fixture.extensionRegistry.list().count == 1)
    }

    @Test func setupSecondRunReportsAlreadyConfigured() throws {
        let fixture = try SetupFixture()
        let flow = try fixture.flow(defaultPaths: [], installedExtensions: [])

        _ = try flow.run(auto: true)
        let second = try flow.run(auto: true)

        #expect(second == nil)
        #expect(fixture.output.contains("Already configured. Use --reset to re-run from scratch."))
    }

    @Test func setupResetCancelledLeavesExistingProtections() throws {
        let fixture = try SetupFixture(answers: ["n"])
        try fixture.folderRegistry.protect(path: "/tmp/keep", source: "user")
        let flow = try fixture.flow(defaultPaths: [], installedExtensions: [])

        let summary = try flow.run(reset: true)

        #expect(summary == nil)
        #expect(try fixture.folderRegistry.list().map(\.path) == ["/tmp/keep"])
    }

    @Test func setupResetAutoClearsAndRecreatesTables() throws {
        let fixture = try SetupFixture()
        try fixture.folderRegistry.protect(path: "/tmp/old", source: "user")
        try fixture.extensionRegistry.protect(profilePath: "/tmp/profile", extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn")
        let folder = try fixture.makeDirectory("new")
        let flow = try fixture.flow(defaultPaths: [folder.path], installedExtensions: [])

        let summary = try flow.run(auto: true, reset: true)

        #expect(summary?.foldersProtected == 1)
        #expect(try fixture.folderRegistry.list().map(\.path) == [ExtensionPathMaterializer.normalize(folder.path)])
        #expect(try fixture.extensionRegistry.list().isEmpty)
    }

    @Test func statusFormatterIncludesRequiredSections() {
        let text = SanctuaryStatusFormatter.format(.init(
            commitHash: "abc123",
            daemon: "running (pid 42)",
            defaultFolderCount: 2,
            userFolderCount: 1,
            extensionCount: 3,
            browserProfileCount: 2,
            recentAgentClassifications: 4,
            recentProtectedResourceAccesses: 5,
            recentDenials: 0,
            auditLogPath: "/tmp/audit.log",
            auditLogSizeBytes: 100,
            auditLogLineCount: 6
        ))

        #expect(text.contains("Sanctuary v0.1 (abc123)"))
        #expect(text.contains("Registry: v1 from 2026-05-06"))
        #expect(text.contains("Daemon: running (pid 42)"))
        #expect(text.contains("Folders: 2 (default), 1 (user-added)"))
        #expect(text.contains("Audit log: /tmp/audit.log"))
    }

    @Test func statusReaderCountsPolicyRowsAndAuditLines() throws {
        let fixture = try SetupFixture()
        try fixture.folderRegistry.protect(path: "/tmp/default", source: "default")
        try fixture.folderRegistry.protect(path: "/tmp/user", source: "user")
        try fixture.extensionRegistry.protect(profilePath: "/tmp/profile", extensionID: "nkbihfbeogaeaoehlefnkodbefgpgknn")
        let audit = fixture.root.appendingPathComponent("audit.log")
        try """
        {"action":"DETECT_ALERT"}
        {"action":"DENY_READ"}

        """.write(to: audit, atomically: true, encoding: .utf8)

        let snapshot = try SanctuaryStatusReader.snapshot(
            folderRegistry: fixture.folderRegistry,
            extensionRegistry: fixture.extensionRegistry,
            auditLogPath: audit.path,
            daemon: "not running",
            commitHash: "test"
        )

        #expect(snapshot.defaultFolderCount == 1)
        #expect(snapshot.userFolderCount == 1)
        #expect(snapshot.extensionCount == 1)
        #expect(snapshot.browserProfileCount == 1)
        #expect(snapshot.recentProtectedResourceAccesses == 1)
        #expect(snapshot.recentDenials == 1)
        #expect(snapshot.auditLogLineCount == 2)
    }

    @Test func browserProfileDiscoveryFindsKnownExtensions() throws {
        let fixture = try SetupFixture()
        let profile = fixture.root
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default", isDirectory: true)
        let extensionDir = profile.appendingPathComponent("Extensions/nkbihfbeogaeaoehlefnkodbefgpgknn", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)

        let installed = BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions(homeDirectory: fixture.root)

        #expect(installed.map(\.extensionID) == ["nkbihfbeogaeaoehlefnkodbefgpgknn"])
        #expect(installed.map(\.friendlyName) == ["MetaMask"])
        #expect(installed.first?.profilePath.hasSuffix("Library/Application Support/Google/Chrome/Default") == true)
    }

    @Test func browserProfileDiscoveryCoversAdditionalChromiumBrowsers() throws {
        let fixture = try SetupFixture()
        let profiles = [
            "Library/Application Support/Microsoft Edge/Default",
            "Library/Application Support/Vivaldi/Profile 1",
            "Library/Application Support/com.operasoftware.Opera"
        ]
        for profile in profiles {
            let extensionDir = fixture.root
                .appendingPathComponent(profile, isDirectory: true)
                .appendingPathComponent("Extensions/dmkamcknogkgcdfhhbddcghachkejeap", isDirectory: true)
            try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        }

        let installed = BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions(homeDirectory: fixture.root)

        #expect(installed.count == 3)
        #expect(Set(installed.map(\.friendlyName)) == ["Keplr"])
        #expect(installed.contains { $0.profilePath.hasSuffix("Microsoft Edge/Default") })
        #expect(installed.contains { $0.profilePath.hasSuffix("Vivaldi/Profile 1") })
        #expect(installed.contains { $0.profilePath.hasSuffix("com.operasoftware.Opera") })
    }

    @Test func browserProfileDiscoveryIgnoresUnknownExtensions() throws {
        let fixture = try SetupFixture()
        let extensionDir = fixture.root
            .appendingPathComponent("Library/Application Support/Google/Chrome/Default/Extensions/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isDirectory: true)
        try FileManager.default.createDirectory(at: extensionDir, withIntermediateDirectories: true)

        #expect(BrowserProfileExtensionDiscovery.discoverInstalledKnownExtensions(homeDirectory: fixture.root).isEmpty)
    }

    @Test func currentProcessExclusionFiltersPids() {
        let filtered = CurrentProcessExclusion.filterPids([1, 2, 3], excluding: [2])

        #expect(filtered == [1, 3])
    }

    @Test func currentProcessExclusionFiltersInventoryEntries() {
        let entries = [
            inventoryEntry(pid: 10),
            inventoryEntry(pid: 11)
        ]

        let filtered = CurrentProcessExclusion.filterAgentSnapshot(entries, excluding: [11])

        #expect(filtered.map(\.pid) == [10])
    }

    @Test func currentProcessGroupIncludesDescendants() {
        let group = CurrentProcessExclusion.processGroup(
            containing: 10,
            listPIDs: { [10, 11, 12, 20] },
            parentPID: { pid in
                [11: 10, 12: 11, 20: 1][pid]
            }
        )

        #expect(group == [10, 11, 12])
    }

    @Test func currentProcessGroupHandlesMissingProcList() {
        let group = CurrentProcessExclusion.processGroup(
            containing: 10,
            listPIDs: { throw DarwinProcError.processUnavailable },
            parentPID: { _ in nil }
        )

        #expect(group == [10])
    }

    @Test func currentProcessExclusionCurrentPidIsPositive() {
        #expect(CurrentProcessExclusion.currentPid > 0)
        #expect(CurrentProcessExclusion.currentProcessGroup.contains(CurrentProcessExclusion.currentPid))
    }

    private func inventoryEntry(pid: pid_t) -> InventoryEntry {
        InventoryEntry(
            pid: pid,
            executablePath: "/tmp/agent-\(pid)",
            displayName: "agent-\(pid)",
            category: .foregroundCoding,
            verdict: .agent(reason: .knownList("agent"), confidence: .high),
            parentPid: nil,
            parentDisplayName: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastClassified: Date(timeIntervalSince1970: 0),
            mcpTransport: nil
        )
    }
}

private final class SetupFixture: @unchecked Sendable {
    let root: URL
    let folderRegistry: ProtectedFolderRegistry
    let extensionRegistry: ProtectedExtensionRegistry
    var answers: [String]
    var output: String = ""

    init(answers: [String] = []) throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.folderRegistry = try ProtectedFolderRegistry(path: root.appendingPathComponent("db.sqlite").path)
        self.extensionRegistry = try ProtectedExtensionRegistry(path: root.appendingPathComponent("db.sqlite").path)
        self.answers = answers
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func flow(
        defaultPaths: [String],
        installedExtensions: [InstalledBrowserExtension]
    ) throws -> SanctuarySetupFlow {
        SanctuarySetupFlow(
            folderRegistry: folderRegistry,
            extensionRegistry: extensionRegistry,
            defaultPaths: { defaultPaths },
            installedExtensions: { installedExtensions },
            prompt: { [weak self] question, defaultYes in
                self?.output += question + "\n"
                guard let self, !self.answers.isEmpty else {
                    return defaultYes
                }
                let answer = self.answers.removeFirst().lowercased()
                if answer.isEmpty {
                    return defaultYes
                }
                return answer == "y" || answer == "yes"
            },
            write: { [weak self] line in
                self?.output += line + "\n"
            },
            daemonStatus: { "not running" },
            auditLogPath: root.appendingPathComponent("audit.log").path
        )
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
