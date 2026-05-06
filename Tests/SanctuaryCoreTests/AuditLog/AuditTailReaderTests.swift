// SPDX-License-Identifier: AGPL-3.0-only
import CryptoKit
import Foundation
import Testing
import SanctuaryCore

struct AuditTailReaderTests {
    @Test func emptyLogReturnsEmptyArray() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("audit.log").path

        #expect(AuditTailReader(path: path).recentEntries().isEmpty)
    }

    @Test func singleValidSignedEntryReturnsActivity() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.log.append(fixture.entry(ts: "2026-05-06T12:00:00Z"))

        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:00:30Z") }).recentEntries()

        #expect(entries.count == 1)
        #expect(entries.first?.summaryText == "Codex CLI accessed ~/.ssh")
        #expect(entries.first?.relativeTimeText == "just now")
    }

    @Test func hundredEntriesLimitReturnsMostRecentFive() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<100 {
            try fixture.appendRaw(fixture.entry(
                ts: String(format: "2026-05-06T12:%02d:00Z", index % 60),
                path: "\(NSHomeDirectory())/.ssh/file-\(index)"
            ))
        }

        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:59:30Z") }).recentEntries(limit: 5)

        #expect(entries.count == 5)
        #expect(entries.allSatisfy { $0.summaryText == "Codex CLI accessed ~/.ssh" })
    }

    @Test func entriesOlderThanWindowAreFiltered() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.appendRaw(fixture.entry(ts: "2026-05-06T10:00:00Z"))
        try fixture.appendRaw(fixture.entry(ts: "2026-05-06T11:59:00Z"))

        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:00:00Z") }).recentEntries(within: 300)

        #expect(entries.count == 1)
        #expect(entries.first?.relativeTimeText == "1 minute ago")
    }

    @Test func malformedLineIsSkipped() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.appendRaw(fixture.entry(ts: "2026-05-06T12:00:00Z"))
        try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path)).appendLine("not json at all")
        try fixture.appendRaw(fixture.entry(ts: "2026-05-06T12:01:00Z"))

        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:01:10Z") }).recentEntries(limit: 5)

        #expect(entries.count == 2)
    }

    @Test func multiMBLogTailReadStaysFast() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
        defer { try? handle.close() }
        let filler = String(repeating: "x", count: 2048)
        for _ in 0..<1200 {
            handle.appendLine(#"{"ignored":""# + filler + #""}"#)
        }
        for index in 0..<10 {
            handle.appendLine(try fixture.rawLine(fixture.entry(ts: "2026-05-06T12:00:0\(index)Z")))
        }

        let start = ContinuousClock.now
        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:00:30Z") }).recentEntries(limit: 5)
        let elapsed = start.duration(to: .now)
        print("AuditTailReader multi-MB fixture latency: \(elapsed)")

        #expect(entries.count == 5)
        #expect(elapsed < .milliseconds(50))
    }

    @Test func thousandEntryFixtureLatencyIsMeasured() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for index in 0..<1000 {
            try fixture.appendRaw(fixture.entry(
                ts: String(format: "2026-05-06T12:%02d:%02dZ", (index / 60) % 60, index % 60),
                path: "\(NSHomeDirectory())/.ssh/file-\(index)"
            ))
        }

        let start = ContinuousClock.now
        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:59:59Z") }).recentEntries(limit: 5)
        let elapsed = start.duration(to: .now)
        print("AuditTailReader 1000-entry fixture latency: \(elapsed)")

        #expect(entries.count == 5)
        #expect(elapsed < .milliseconds(50))
    }

    @Test func allowEntriesAreSkipped() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.appendRaw(fixture.entry(action: "ALLOW", ts: "2026-05-06T12:00:00Z"))
        try fixture.appendRaw(fixture.entry(action: "DETECT_ALERT", ts: "2026-05-06T12:01:00Z"))

        let entries = AuditTailReader(path: fixture.path, now: { Self.date("2026-05-06T12:01:30Z") }).recentEntries(limit: 5)

        #expect(entries.count == 1)
        #expect(entries.first?.attributionText == "Detected · definite")
    }

    @Test func unsignedJSONLBackCompatParses() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.appendRaw(fixture.entry(ts: "2026-05-06T12:00:00Z"))

        let entry = try #require(AuditTailReader.parseEntryLine(try String(contentsOfFile: fixture.path).trimmingCharacters(in: .whitespacesAndNewlines)))

        #expect(entry.policy == "protected_folder")
        #expect(entry.action == "DETECT_ALERT")
    }

    private struct Fixture {
        let root: URL
        let path: String
        let log: AuditLog

        init() throws {
            root = try AuditTailReaderTests.makeTemporaryDirectory()
            path = root.appendingPathComponent("audit.log").path
            FileManager.default.createFile(atPath: path, contents: nil)
            log = AuditLog(path: path, signingKeyProvider: TailFixedSigningKeyProvider())
        }

        func entry(
            action: String = "DETECT_ALERT",
            ts: String,
            path: String = "\(NSHomeDirectory())/.ssh/id_ed25519"
        ) -> AuditEntry {
            AuditEntry(
                ts: ts,
                kind: "fs_access",
                action: action,
                attribution: .init(level: "definite", pid: 42, processPath: "/opt/homebrew/bin/codex", agentPids: [42]),
                policy: "protected_folder",
                path: path
            )
        }

        func appendRaw(_ entry: AuditEntry) throws {
            try FileHandle(forWritingTo: URL(fileURLWithPath: path)).appendLine(rawLine(entry))
        }

        func rawLine(_ entry: AuditEntry) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return String(decoding: try encoder.encode(entry), as: UTF8.self)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-audit-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }
}

private struct TailFixedSigningKeyProvider: AuditSigningKeyProviding {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 9, count: 32))

    func loadOrCreate(keychainAccount: String) throws -> Curve25519.Signing.PrivateKey {
        key
    }

    func publicKeyData(keychainAccount: String) throws -> Data {
        key.publicKey.rawRepresentation
    }
}

private extension FileHandle {
    func appendLine(_ line: String) {
        seekToEndOfFile()
        write(Data((line + "\n").utf8))
    }
}
