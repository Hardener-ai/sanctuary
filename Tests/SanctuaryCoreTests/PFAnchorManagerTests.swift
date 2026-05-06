// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import SanctuaryCore

@Suite(.serialized)
struct PFAnchorManagerTests {
    @Test func generateRulesFileForSingleRedirect() {
        let rules = PFAnchorManager.generateRulesFile(redirects: [
            .init(fromPort: 9222, toPort: 49222)
        ])

        #expect(rules == "rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222\n")
    }

    @Test func generateRulesFileForMultipleRedirectsSortsBySourcePort() {
        let rules = PFAnchorManager.generateRulesFile(redirects: [
            .init(fromPort: 9333, toPort: 49222),
            .init(fromPort: 9222, toPort: 49222)
        ])

        #expect(rules.contains("port 9222 -> 127.0.0.1 port 49222\nrdr"))
        #expect(rules.contains("port 9333 -> 127.0.0.1 port 49222\n"))
    }

    @Test func generateRulesFileForEmptyRedirectsIsEmpty() {
        #expect(PFAnchorManager.generateRulesFile(redirects: []) == "")
    }

    @Test func generateRulesFileKeepsDistinctDestinationPorts() {
        let rules = PFAnchorManager.generateRulesFile(redirects: [
            .init(fromPort: 9222, toPort: 50001),
            .init(fromPort: 9223, toPort: 50002)
        ])

        #expect(rules.contains("port 9222 -> 127.0.0.1 port 50001"))
        #expect(rules.contains("port 9223 -> 127.0.0.1 port 50002"))
    }

    @Test func generateRulesFileAddsNoRDRBypassBeforeRedirect() {
        let rules = PFAnchorManager.generateRulesFile(redirects: [
            .init(fromPort: 9222, toPort: 49222, bypassSourcePort: 49223)
        ])

        #expect(rules == """
        no rdr on lo0 inet proto tcp from 127.0.0.1 port 49223 to 127.0.0.1 port 9222
        rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222

        """)
    }

    @Test func generateRulesFileAddsNoRDRBypassRangeBeforeRedirect() {
        let rules = PFAnchorManager.generateRulesFile(redirects: [
            .init(fromPort: 9222, toPort: 49222, bypassSourcePortRange: 49223...49322)
        ])

        #expect(rules.contains("no rdr on lo0 inet proto tcp from 127.0.0.1 port 49223:49322 to 127.0.0.1 port 9222"))
        #expect(rules.contains("rdr on lo0 inet proto tcp from 127.0.0.1 to 127.0.0.1 port 9222 -> 127.0.0.1 port 49222"))
    }

    @Test func installFailsFastWhenNotRoot() throws {
        let manager = PFAnchorManager(
            anchorPath: temporaryAnchorURL(),
            commandRunner: RecordingCommandRunner(),
            effectiveUserID: { 501 }
        )

        #expect(throws: PFError.notRoot) {
            try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222)])
        }
    }

    @Test func ensurePFEnabledRunsEnableWhenPFIsDisabled() throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(exitCode: 0, stdout: "Status: Disabled\n", stderr: ""),
            CommandResult(exitCode: 0, stdout: "pf enabled\n", stderr: "No ALTQ support in kernel\n")
        ])
        let manager = PFAnchorManager(anchorPath: temporaryAnchorURL(), commandRunner: runner)

        try manager.ensurePFEnabled()

        #expect(runner.calls.map(\.arguments) == [["-s", "info"], ["-e"]])
    }

    @Test func ensurePFEnabledDoesNotEnableWhenStatusAlreadyEnabled() throws {
        let runner = RecordingCommandRunner(results: [
            CommandResult(
                exitCode: 0,
                stdout: try pfFixture(named: "pfctl-info-enabled.txt"),
                stderr: "No ALTQ support in kernel\nALTQ related functions disabled\n"
            )
        ])
        let manager = PFAnchorManager(anchorPath: temporaryAnchorURL(), commandRunner: runner)

        try manager.ensurePFEnabled()

        #expect(runner.calls.map(\.arguments) == [["-s", "info"]])
    }

    @Test func parsePFStatusFixtures() throws {
        #expect(PFAnchorManager.parsePFStatus(stdout: try pfFixture(named: "pfctl-info-enabled.txt")) == .enabled)
        #expect(PFAnchorManager.parsePFStatus(stdout: try pfFixture(named: "pfctl-info-disabled.txt")) == .disabled)
        #expect(PFAnchorManager.parsePFStatus(stdout: "not pf output") == .unknown)
    }

    @Test func anchorFileNameSanitizesAppleNamespace() {
        #expect(PFAnchorManager.anchorFileName(for: "com.apple/250.SanctuaryRedirect") == "com.apple-250.SanctuaryRedirect")
        #expect(PFAnchorManager.anchorFileName(for: #"com.apple/250."Quoted""#) == "com.apple-250.Quoted")
    }

    @Test func pfIntegrationEnsurePFEnabledIsGated() throws {
        guard shouldRunPFIntegrationTests() else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let manager = makeIntegrationManager("Enable")
        try manager.ensurePFEnabled()
    }

    @Test func pfIntegrationInstallRuleVisibleInAnchorIsGated() throws {
        guard shouldRunPFIntegrationTests() else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let manager = makeIntegrationManager("Visible")
        try manager.ensurePFEnabled()
        try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222)])
        defer { try? manager.uninstall() }

        let rules = try String(contentsOfFile: integrationAnchorPath(integrationAnchorName("Visible")), encoding: .utf8)
        #expect(rules.contains("9222"))
        #expect(rules.contains("49222"))
    }

    @Test func pfIntegrationInstallThenUninstallClearsAnchorIsGated() throws {
        guard shouldRunPFIntegrationTests() else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let anchorName = integrationAnchorName("Uninstall")
        let anchorPath = integrationAnchorPath(anchorName)
        let manager = PFAnchorManager(anchorName: anchorName)
        try manager.ensurePFEnabled()
        try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222)])
        try manager.uninstall()

        #expect(!FileManager.default.fileExists(atPath: anchorPath))
    }

    @Test func pfIntegrationInstallTwoRedirectsIsGated() throws {
        guard shouldRunPFIntegrationTests() else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let manager = makeIntegrationManager("TwoRedirects")
        try manager.ensurePFEnabled()
        try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222), .init(fromPort: 9333, toPort: 49222)])
        defer { try? manager.uninstall() }

        let rules = try String(contentsOfFile: integrationAnchorPath(integrationAnchorName("TwoRedirects")), encoding: .utf8)
        #expect(rules.contains("9222"))
        #expect(rules.contains("9333"))
    }

    @Test func pfIntegrationInstallOverExistingAnchorReplacesCleanlyIsGated() throws {
        guard shouldRunPFIntegrationTests() else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        let manager = makeIntegrationManager("Replace")
        try manager.ensurePFEnabled()
        try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222)])
        try manager.install(redirects: [.init(fromPort: 9333, toPort: 49222)])
        defer { try? manager.uninstall() }

        let rules = try String(contentsOfFile: integrationAnchorPath(integrationAnchorName("Replace")), encoding: .utf8)
        #expect(!rules.contains("port 9222 ->"))
        #expect(rules.contains("9333"))
    }

    @Test func pfIntegrationNotRootErrorIsGated() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_PF_TESTS"] == "1" else {
            print("skipped: requires sudo and SANCTUARY_RUN_PF_TESTS=1")
            return
        }

        guard currentEffectiveUserID() != 0 else {
            print("skipped: notRoot branch requires running without sudo")
            return
        }

        let manager = makeIntegrationManager("NotRoot")
        #expect(throws: PFError.notRoot) {
            try manager.install(redirects: [.init(fromPort: 9222, toPort: 49222)])
        }
    }

    private func shouldRunPFIntegrationTests() -> Bool {
        ProcessInfo.processInfo.environment["SANCTUARY_RUN_PF_TESTS"] == "1" && currentEffectiveUserID() == 0
    }

    private func temporaryAnchorURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-pf-anchor-\(UUID().uuidString)")
    }

    private func makeIntegrationManager(_ suffix: String) -> PFAnchorManager {
        PFAnchorManager(anchorName: integrationAnchorName(suffix))
    }

    private func integrationAnchorName(_ suffix: String) -> String {
        "com.apple/250.Sanctuary\(suffix)"
    }

    private func integrationAnchorPath(_ anchorName: String) -> String {
        "/etc/pf.anchors/\(PFAnchorManager.anchorFileName(for: anchorName))"
    }

    private func pfFixture(named name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PF/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var queuedResults: [CommandResult]
    private(set) var calls: [(executable: String, arguments: [String])] = []

    init(results: [CommandResult] = []) {
        self.queuedResults = results
    }

    func run(executable: String, arguments: [String]) throws -> CommandResult {
        lock.withLock {
            calls.append((executable, arguments))
            if queuedResults.isEmpty {
                return CommandResult(exitCode: 0, stdout: "", stderr: "")
            }
            return queuedResults.removeFirst()
        }
    }
}
