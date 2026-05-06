// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
@testable import SanctuaryCore

struct ExtensionStorageIntegrationTests {
    @Test func realFSEventsWatcherAuditsOnlyAgentAttributedStorageAccess() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_FS_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_FS_TESTS=1")
            return
        }

        let fileManager = FileManager.default
        let profileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sanctuary-test-profile-\(UUID().uuidString)", isDirectory: true)
        let auditURL = ProcessInfo.processInfo.environment["SANCTUARY_AUDIT_PATH"]
            .map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sanctuary-audit-\(UUID().uuidString).log")
        try? fileManager.removeItem(at: profileURL)
        try? fileManager.removeItem(at: auditURL)
        defer {
            try? fileManager.removeItem(at: profileURL)
            try? fileManager.removeItem(at: auditURL)
        }

        let extensionID = "nkbihfbeogaeaoehlefnkodbefgpgknn"
        let extensionDir = profileURL
            .appendingPathComponent("Local Extension Settings", isDirectory: true)
            .appendingPathComponent(extensionID, isDirectory: true)
        try fileManager.createDirectory(at: extensionDir, withIntermediateDirectories: true)
        let vaultFile = extensionDir.appendingPathComponent("vault.ldb")
        try Data("fixture".utf8).write(to: vaultFile)

        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: profileURL.path, extensionID: extensionID, friendlyName: "MetaMask")
        let watcher = ExtensionStorageWatcher(protectedPaths: try registry.pathsForActiveProtections())
        let agents = MutableAgentSnapshotProvider()
        let service = ExtensionStorageProtectionService(
            watcher: watcher,
            agentSnapshotProvider: agents,
            openFileProvider: DarwinOpenFileProvider(),
            auditLogger: AuditLog(path: auditURL.path, signingKeyProvider: IntegrationAuditSigningKeyProvider())
        )
        try service.start()
        defer { service.stop() }

        try runProcess("/bin/cat", [vaultFile.path])
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!fileManager.fileExists(atPath: auditURL.path))

        let holdingAgent = try startFileHoldingProcess(path: vaultFile.path)
        defer {
            holdingAgent.terminate()
            holdingAgent.waitUntilExit()
        }
        agents.set([
            ProcessIdentity(
                pid: pid_t(holdingAgent.processIdentifier),
                executablePath: "/usr/local/bin/claude"
            )
        ])

        try Data("fixture-updated".utf8).write(to: vaultFile)

        let auditLine = try waitForAuditLine(at: auditURL, timeout: 3)
        print("extension-storage audit: \(auditLine)")
        #expect(auditLine.contains(#""action":"DETECT_ALERT""#))
        #expect(auditLine.contains(#""level":"definite""#))
        #expect(auditLine.contains(#""policy":"protected_extension_storage""#))

        service.stop()
        let beforeStopContents = try String(contentsOf: auditURL, encoding: .utf8)
        try Data("fixture-after-stop".utf8).write(to: vaultFile)
        Thread.sleep(forTimeInterval: 0.4)
        let afterStopContents = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(afterStopContents == beforeStopContents)
    }
}

private struct IntegrationAuditSigningKeyProvider: AuditSigningKeyProviding {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 11, count: 32))

    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func publicKeyData(keychainAccount: String) throws -> Data {
        key.publicKey.rawRepresentation
    }
}

private final class MutableAgentSnapshotProvider: AgentProcessSnapshotProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var identities: [ProcessIdentity] = []

    func set(_ identities: [ProcessIdentity]) {
        lock.withLock {
            self.identities = identities
        }
    }

    func runningAgents() -> [ProcessIdentity] {
        lock.withLock { identities }
    }
}

private func runProcess(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

private func startFileHoldingProcess(path: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exec 3< \"$1\"; sleep 5", "sh", path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    Thread.sleep(forTimeInterval: 0.2)
    return process
}

private func waitForAuditLine(at url: URL, timeout: TimeInterval) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let contents = try? String(contentsOf: url, encoding: .utf8),
           let line = contents.split(separator: "\n").last {
            return String(line)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return ""
}
