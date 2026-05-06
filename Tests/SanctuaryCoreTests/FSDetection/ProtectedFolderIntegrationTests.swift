// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
@testable import SanctuaryCore

struct ProtectedFolderIntegrationTests {
    @Test func realFSEventsWatcherAuditsOnlyAgentAttributedFolderAccess() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_FS_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_FS_TESTS=1")
            return
        }

        let fileManager = FileManager.default
        let folderURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sanctuary-fs-test-folder-\(UUID().uuidString)", isDirectory: true)
        let auditURL = ProcessInfo.processInfo.environment["SANCTUARY_AUDIT_PATH"]
            .map { URL(fileURLWithPath: $0) } ??
            URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sanctuary-fs-audit-\(UUID().uuidString).log")
        try? fileManager.removeItem(at: folderURL)
        try? fileManager.removeItem(at: auditURL)
        defer {
            try? fileManager.removeItem(at: folderURL)
            try? fileManager.removeItem(at: auditURL)
        }

        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let secretFile = folderURL.appendingPathComponent("secret.txt")
        try Data("fixture".utf8).write(to: secretFile)

        let registry = try ProtectedFolderRegistry(inMemory: true)
        try registry.protect(path: folderURL.path, source: "user")
        let agents = FolderMutableAgentSnapshotProvider()
        let watcher = ProtectedFolderWatcher(
            protectedPaths: try registry.existingWatchedPaths(),
            agentSnapshotProvider: agents,
            openFileProvider: DarwinOpenFileProvider(),
            auditLogger: AuditLog(path: auditURL.path, signingKeyProvider: FolderIntegrationAuditSigningKeyProvider())
        )
        try watcher.start()
        defer { watcher.stop() }

        try Data("non-agent".utf8).write(to: secretFile)
        Thread.sleep(forTimeInterval: 0.4)
        #expect(!fileManager.fileExists(atPath: auditURL.path))

        let holdingAgent = try startFolderFileHoldingProcess(path: secretFile.path)
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

        try Data("agent".utf8).write(to: secretFile)

        let auditLine = try waitForFolderAuditLine(at: auditURL, timeout: 3)
        print("protected-folder audit: \(auditLine)")
        #expect(auditLine.contains(#""action":"DETECT_ALERT""#))
        #expect(auditLine.contains(#""policy":"protected_folder""#))
        #expect(auditLine.contains(#""level":"definite""#) || auditLine.contains(#""level":"probable""#))

        try registry.unprotect(path: folderURL.path)
        try watcher.updateProtectedPaths(try registry.existingWatchedPaths())
        let beforeStopContents = try String(contentsOf: auditURL, encoding: .utf8)
        try Data("after-unprotect".utf8).write(to: secretFile)
        Thread.sleep(forTimeInterval: 0.4)
        let afterStopContents = try String(contentsOf: auditURL, encoding: .utf8)
        #expect(afterStopContents == beforeStopContents)
    }
}

private struct FolderIntegrationAuditSigningKeyProvider: AuditSigningKeyProviding {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 13, count: 32))

    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func publicKeyData(keychainAccount: String) throws -> Data {
        key.publicKey.rawRepresentation
    }
}

private final class FolderMutableAgentSnapshotProvider: AgentProcessSnapshotProviding, @unchecked Sendable {
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

private func startFolderFileHoldingProcess(path: String) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "exec 3< \"$1\"; sleep 5", "sh", path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    Thread.sleep(forTimeInterval: 0.2)
    return process
}

private func waitForFolderAuditLine(at url: URL, timeout: TimeInterval) throws -> String {
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
