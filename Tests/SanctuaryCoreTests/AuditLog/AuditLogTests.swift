// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
@testable import SanctuaryCore

struct AuditLogTests {
    @Test func appendEntryWritesParsableSignedJSONLine() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry(action: "DETECT_ALERT"))

        let line = try #require(try String(contentsOf: fixture.url, encoding: .utf8).split(separator: "\n").first)
        let parsed = try #require(AuditLog.parseSignedLine(String(line)))
        let entry = try JSONDecoder().decode(AuditEntry.self, from: parsed.entryJSON)

        #expect(entry.action == "DETECT_ALERT")
        #expect(entry.kind == "fs_access")
    }

    @Test func appendEntrySignatureVerifiesAgainstPublicKey() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry())

        #expect(try log.verify() == .valid(entryCount: 1))
    }

    @Test func tamperedEntryFailsSignatureVerification() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry(action: "DETECT_ALERT"))

        let original = try String(contentsOf: fixture.url, encoding: .utf8)
        let tampered = original.replacingOccurrences(of: "DETECT_ALERT", with: "DETECT_BLOCK")
        try tampered.write(to: fixture.url, atomically: true, encoding: .utf8)

        #expect(try log.verify() == .invalid(reason: .signatureFailure, entryIndex: 1))
    }

    @Test func rotationTriggersWhenThresholdExceeded() throws {
        let fixture = try Fixture()
        try Data(repeating: 65, count: 16).write(to: fixture.url)
        let log = fixture.log(rotationSizeBytes: 8)

        try log.rotateIfNeeded()

        #expect(!FileManager.default.fileExists(atPath: fixture.url.path))
        #expect(FileManager.default.fileExists(atPath: fixture.url.path + ".1"))
    }

    @Test func rotationRetainsFiveGenerationsAndDropsSixth() throws {
        let fixture = try Fixture()
        try "current".write(to: fixture.url, atomically: true, encoding: .utf8)
        for generation in 1...5 {
            try "generation-\(generation)".write(
                to: URL(fileURLWithPath: fixture.url.path + ".\(generation)"),
                atomically: true,
                encoding: .utf8
            )
        }

        let log = fixture.log(rotationSizeBytes: 1)
        try log.rotateIfNeeded()

        #expect(try String(contentsOfFile: fixture.url.path + ".1") == "current")
        #expect(try String(contentsOfFile: fixture.url.path + ".5") == "generation-4")
    }

    @Test func concurrentAppendsProduceValidIndependentLines() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        let queue = DispatchQueue(label: "ai.hardener.sanctuary.audit-test", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<4 {
            group.enter()
            queue.async {
                try? log.append(fixture.entry(action: "DETECT_ALERT_\(index)"))
                group.leave()
            }
        }
        group.wait()

        #expect(try log.verify() == .valid(entryCount: 4))
    }

    @Test func canonicalSignedEntryJSONIsDeterministic() throws {
        let fixture = try Fixture()
        let line = try fixture.signedLine(entry: fixture.entry(prevHash: AuditLog.genesisPrevHash))
        let parsed = try #require(AuditLog.parseSignedLine(line))

        let first = try AuditLog.canonicalSignedEntryJSON(entryJSON: parsed.entryJSON, signature: parsed.signature)
        let second = try AuditLog.canonicalSignedEntryJSON(entryJSON: parsed.entryJSON, signature: parsed.signature)

        #expect(first == second)
        #expect(try AuditLog.signedEntryHash(entryJSON: parsed.entryJSON, signature: parsed.signature).count == 64)
    }

    @Test func hashChainIsComputedAcrossHundredEntries() throws {
        let fixture = try Fixture()
        let log = fixture.log()

        for index in 0..<100 {
            try log.append(fixture.entry(action: "DETECT_ALERT_\(index)"))
        }

        #expect(try log.verify() == .valid(entryCount: 100))
    }

    @Test func firstEntryUsesGenesisPrevHash() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry())

        let entries = try fixture.decodedEntries()

        #expect(entries.count == 1)
        #expect(entries[0].prevHash == AuditLog.genesisPrevHash)
    }

    @Test func subsequentPrevHashMatchesPreviousSignedEntryHash() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry(action: "FIRST"))
        try log.append(fixture.entry(action: "SECOND"))

        let lines = try fixture.lines()
        let entries = try fixture.decodedEntries()
        let firstParsed = try #require(AuditLog.parseSignedLine(lines[0]))
        let expectedHash = try AuditLog.signedEntryHash(
            entryJSON: firstParsed.entryJSON,
            signature: firstParsed.signature
        )

        #expect(entries[1].prevHash == expectedHash)
        #expect(try log.verify() == .valid(entryCount: 2))
    }

    @Test func verifierAcceptsLegacyLogWithoutPrevHashForBackwardCompatibility() throws {
        let fixture = try Fixture()
        try fixture.signedLine(entry: fixture.entry()).write(to: fixture.url, atomically: true, encoding: .utf8)
        try "\n".append(to: fixture.url)

        #expect(try fixture.log().verify() == .valid(entryCount: 1))
    }

    @Test func missingPrevHashAfterChainStartsBreaksVerification() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry(action: "FIRST"))
        let secondWithoutPrevHash = try fixture.signedLine(entry: fixture.entry(action: "SECOND"))
        try secondWithoutPrevHash.append(to: fixture.url)
        try "\n".append(to: fixture.url)

        #expect(try log.verify() == .invalid(reason: .hashChainBreak, entryIndex: 2))
    }

    @Test func truncatedEntryReturnsParseFailure() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry())
        let original = try String(contentsOf: fixture.url, encoding: .utf8)
        try String(original.dropLast(12)).write(to: fixture.url, atomically: true, encoding: .utf8)

        #expect(try log.verify() == .invalid(reason: .entryParseFailure, entryIndex: 1))
    }

    @Test func deletingMiddleLineBreaksHashChainAtNextEntry() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        for index in 0..<5 {
            try log.append(fixture.entry(action: "DETECT_ALERT_\(index)"))
        }

        var lines = try fixture.lines()
        lines.remove(at: 2)
        try (lines.joined(separator: "\n") + "\n").write(to: fixture.url, atomically: true, encoding: .utf8)

        #expect(try log.verify() == .invalid(reason: .hashChainBreak, entryIndex: 3))
    }

    @Test func deletingTailLinesLeavesRemainingPrefixValid() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        for index in 0..<5 {
            try log.append(fixture.entry(action: "DETECT_ALERT_\(index)"))
        }

        let lines = try fixture.lines().dropLast(2)
        try (lines.joined(separator: "\n") + "\n").write(to: fixture.url, atomically: true, encoding: .utf8)

        #expect(try log.verify() == .valid(entryCount: 3))
    }

    @Test func recoveryRotatesTamperedLogAndStartsFreshTamperEntry() throws {
        let fixture = try Fixture()
        let log = fixture.log()
        try log.append(fixture.entry(action: "FIRST"))
        try log.append(fixture.entry(action: "SECOND"))

        let original = try String(contentsOf: fixture.url, encoding: .utf8)
        try original.replacingOccurrences(of: "FIRST", with: "FORGED").write(
            to: fixture.url,
            atomically: true,
            encoding: .utf8
        )

        try log.recoverFromTamperingIfNeeded()

        let entries = try fixture.decodedEntries()
        let rotated = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.contains(".tampered.") }

        #expect(rotated.count == 1)
        #expect(entries.count == 1)
        #expect(entries[0].action == "TAMPER_DETECTED")
        #expect(try log.verify() == .valid(entryCount: 1))
    }

    @Test func processAuditProjectionDoesNotIncludeEnvironmentNames() throws {
        let identity = ProcessIdentity(
            pid: 123,
            executablePath: "/usr/local/bin/claude",
            codeSigningIdentifier: "com.example.signing",
            environmentVars: ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        )
        let entry = AuditEntry(
            ts: "2026-05-06T00:00:00Z",
            kind: "process",
            action: "TEST",
            process: .init(identity: identity)
        )

        let data = try JSONEncoder.sorted.encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("ANTHROPIC_API_KEY"))
        #expect(!json.contains("OPENAI_API_KEY"))
        #expect(json.contains("com.example.signing"))
    }

    @Test func realKeychainIntegrationIsGated() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_AUDIT_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_AUDIT_TESTS=1")
            return
        }

        let fixture = try Fixture(provider: KeychainAuditSigningKeyProvider())
        let log = fixture.log(keychainAccount: "sanctuary.audit-signing")
        for index in 0..<100 {
            try log.append(fixture.entry(action: "TEST_APPEND_\(index)"))
        }
        let result = try log.verify()
        print("audit integration verify: \(result.totalEntries) total")
        #expect(result.isValid)
        #expect(result.totalEntries >= 100)
    }

    private struct Fixture {
        let directory: URL
        let url: URL
        let provider: any AuditSigningKeyProviding

        init(provider: any AuditSigningKeyProviding = FixedAuditSigningKeyProvider()) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("sanctuary-audit-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("audit.log")
            self.provider = provider
        }

        func log(
            keychainAccount: String = "test",
            rotationSizeBytes: UInt64 = 100 * 1024 * 1024
        ) -> AuditLog {
            AuditLog(
                path: url.path,
                keychainAccount: keychainAccount,
                signingKeyProvider: provider,
                rotationSizeBytes: rotationSizeBytes
            )
        }

        func entry(action: String = "DETECT_ALERT", prevHash: String? = nil) -> AuditEntry {
            AuditEntry(
                ts: "2026-05-06T00:00:00Z",
                kind: "fs_access",
                action: action,
                attribution: .init(level: "definite", pid: 123, processPath: "/usr/local/bin/claude", agentPids: [123]),
                policy: "protected_extension_storage",
                path: "/tmp/profile/file",
                flags: 1,
                prevHash: prevHash
            )
        }

        func lines() throws -> [String] {
            try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }

        func decodedEntries() throws -> [AuditEntry] {
            try lines().map { line in
                let parsed = try #require(AuditLog.parseSignedLine(line))
                return try JSONDecoder().decode(AuditEntry.self, from: parsed.entryJSON)
            }
        }

        func signedLine(entry: AuditEntry) throws -> String {
            let entryJSON = try JSONEncoder.sorted.encode(entry)
            let key = try provider.loadOrCreate(keychainAccount: "test")
            let signature = try key.signature(for: entryJSON).base64EncodedString()
            return String(decoding: entryJSON, as: UTF8.self) + #","sig":""# + signature + #"""#
        }
    }
}

private struct FixedAuditSigningKeyProvider: AuditSigningKeyProviding {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))

    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func publicKeyData(keychainAccount: String) throws -> Data {
        key.publicKey.rawRepresentation
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension String {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(utf8))
    }
}
