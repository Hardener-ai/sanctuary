// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import SanctuaryCore

struct ActivityRendererTests {
    @Test func sshAccessSummarizesWithCollapsedFolder() {
        let activity = ActivityRenderer.summarize(Self.entry(policy: "protected_folder", path: "\(NSHomeDirectory())/.ssh/id_ed25519"), now: Self.now)

        #expect(activity.summaryText == "Codex CLI accessed ~/.ssh")
        #expect(activity.attributionText == "Detected · definite")
        #expect(!activity.isDenial)
    }

    @Test func awsAccessSummarizesWithCollapsedFolder() {
        let activity = ActivityRenderer.summarize(Self.entry(policy: "protected_folder", path: "\(NSHomeDirectory())/.aws/credentials"), now: Self.now)

        #expect(activity.summaryText == "Codex CLI accessed ~/.aws")
    }

    @Test func otherProtectedPathUsesTildeCollapsedPath() {
        let activity = ActivityRenderer.summarize(Self.entry(policy: "protected_folder", path: "\(NSHomeDirectory())/Vault/seed.txt"), now: Self.now)

        #expect(activity.summaryText == "Codex CLI accessed ~/Vault/seed.txt")
    }

    @Test func metamaskAccessUsesFriendlyNameAndHermesInstallPath() {
        let activity = ActivityRenderer.summarize(Self.entry(
            policy: "protected_extension_storage",
            path: "/tmp/Profile/Local Extension Settings/nkbihfbeogaeaoehlefnkodbefgpgknn/vault.ldb",
            processPath: "\(NSHomeDirectory())/.hermes/hermes-agent/venv/bin/python3.11"
        ), now: Self.now)

        #expect(activity.summaryText == "Hermes Agent (Nous Research) tried to read MetaMask")
    }

    @Test func phantomAccessUsesFriendlyName() {
        let activity = ActivityRenderer.summarize(Self.entry(
            policy: "protected_extension_storage",
            path: "/tmp/Profile/Local Extension Settings/bfnaelmomeimhlpmgjnjophhpkkoljpa/vault.ldb"
        ), now: Self.now)

        #expect(activity.summaryText == "Codex CLI tried to read Phantom")
    }

    @Test func unknownExtensionFallsBackToStorageLabel() {
        let activity = ActivityRenderer.summarize(Self.entry(
            policy: "protected_extension_storage",
            path: "/tmp/Profile/Local Extension Settings/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/vault.ldb"
        ), now: Self.now)

        #expect(activity.summaryText == "Codex CLI tried to read extension storage")
    }

    @Test func cdpBlockSummarizesBrowserAndBlockedStatus() {
        let activity = ActivityRenderer.summarize(Self.entry(
            action: "DENY",
            policy: "cdp_guard",
            profilePath: "\(NSHomeDirectory())/Library/Application Support/BraveSoftware/Brave-Browser/Default"
        ), now: Self.now)

        #expect(activity.summaryText == "Codex CLI tried to attach to Brave")
        #expect(activity.attributionText == "Blocked")
        #expect(activity.isDenial)
    }

    @Test func unknownAgentFallsBackToExecutableBasename() {
        let activity = ActivityRenderer.summarize(Self.entry(
            policy: "protected_folder",
            path: "\(NSHomeDirectory())/.ssh/id_ed25519",
            processPath: "/tmp/custom-loop"
        ), now: Self.now)

        #expect(activity.summaryText == "custom-loop accessed ~/.ssh")
    }

    @Test func relativeTimeBoundariesRenderPlainLanguage() {
        #expect(ActivityRenderer.relativeTime(from: Self.now.addingTimeInterval(-30), to: Self.now) == "just now")
        #expect(ActivityRenderer.relativeTime(from: Self.now.addingTimeInterval(-90), to: Self.now) == "1 minute ago")
        #expect(ActivityRenderer.relativeTime(from: Self.now.addingTimeInterval(-3700), to: Self.now) == "1 hour ago")
        #expect(ActivityRenderer.relativeTime(from: Self.now.addingTimeInterval(-172800), to: Self.now) == "2 days ago")
    }

    @Test func attributionLevelsRenderForDetectionOnlyEntries() {
        #expect(ActivityRenderer.summarize(Self.entry(level: "definite"), now: Self.now).attributionText == "Detected · definite")
        #expect(ActivityRenderer.summarize(Self.entry(level: "probable"), now: Self.now).attributionText == "Detected · probable")
        #expect(ActivityRenderer.summarize(Self.entry(level: "correlated"), now: Self.now).attributionText == "Detected · correlated")
        #expect(ActivityRenderer.summarize(Self.entry(level: "unattributed"), now: Self.now).attributionText == "Detected · unattributed")
    }

    @Test func activityEntryCodableDoesNotLeakAuditOnlyFields() throws {
        let activity = ActivityRenderer.summarize(Self.entry(
            policy: "protected_folder",
            path: "\(NSHomeDirectory())/.ssh/id_ed25519",
            processPath: "/opt/homebrew/bin/codex"
        ), now: Self.now)
        let json = String(decoding: try JSONEncoder().encode(activity), as: UTF8.self)

        #expect(!json.contains(NSHomeDirectory()))
        #expect(!json.contains("id_ed25519"))
        #expect(!json.contains("processPath"))
        #expect(!json.contains("agentPids"))
        #expect(!json.contains("sig"))
    }

    private static let now = ISO8601DateFormatter().date(from: "2026-05-06T12:00:00Z")!

    private static func entry(
        action: String = "DETECT_ALERT",
        level: String = "definite",
        policy: String,
        path: String? = nil,
        processPath: String = "/opt/homebrew/bin/codex",
        profilePath: String? = nil
    ) -> AuditEntry {
        AuditEntry(
            ts: "2026-05-06T11:59:30Z",
            kind: policy == "cdp_guard" ? "cdp_access" : "fs_access",
            action: action,
            attribution: .init(level: level, pid: 42, processPath: processPath, agentPids: [42]),
            policy: policy,
            path: path,
            profilePath: profilePath
        )
    }

    private static func entry(level: String) -> AuditEntry {
        Self.entry(policy: "protected_folder", path: "\(NSHomeDirectory())/.ssh/id_ed25519").withAttributionLevel(level)
    }
}

private extension AuditEntry {
    func withAttributionLevel(_ level: String) -> AuditEntry {
        AuditEntry(
            ts: ts,
            kind: kind,
            action: action,
            attribution: .init(level: level, pid: attribution?.pid, processPath: attribution?.processPath, agentPids: attribution?.agentPids ?? []),
            policy: policy,
            path: path,
            flags: flags,
            process: process,
            profilePath: profilePath,
            resource: resource
        )
    }
}
