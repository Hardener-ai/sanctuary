// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct DaemonShutdownTests {
    @Test func sanctuarydTerminatesOnSIGTERMWithinDeadline() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_DAEMON_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_DAEMON_TESTS=1")
            return
        }
        let harness = try DaemonHarness()
        let process = try harness.launch()

        try harness.waitUntilStarted()
        Darwin.kill(process.processIdentifier, SIGTERM)

        #expect(harness.waitForExit(process, timeout: 5) == 0)
    }

    @Test func sanctuarydTerminatesOnSIGINTWithinDeadlineAndAuditPathSurvives() throws {
        guard ProcessInfo.processInfo.environment["SANCTUARY_RUN_DAEMON_TESTS"] == "1" else {
            print("skipped: requires SANCTUARY_RUN_DAEMON_TESTS=1")
            return
        }
        let harness = try DaemonHarness()
        try "known-entry\n".write(to: harness.auditURL, atomically: true, encoding: .utf8)
        let process = try harness.launch()

        try harness.waitUntilStarted()
        Darwin.kill(process.processIdentifier, SIGINT)

        #expect(harness.waitForExit(process, timeout: 5) == 0)
        #expect(try String(contentsOf: harness.auditURL).contains("known-entry"))
    }
}

private final class DaemonHarness {
    let root: URL
    let auditURL: URL
    private let outputURL: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-daemon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.auditURL = root.appendingPathComponent("audit.log")
        self.outputURL = root.appendingPathComponent("daemon.log")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func launch() throws -> Process {
        let executable = try daemonExecutable()
        let process = Process()
        process.executableURL = executable
        process.environment = [
            "SANCTUARY_DB_PATH": root.appendingPathComponent("db.sqlite").path,
            "SANCTUARY_AUDIT_PATH": auditURL.path,
            "SANCTUARY_INVENTORY_SNAPSHOT_PATH": root.appendingPathComponent("inventory.json").path
        ]
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    func waitUntilStarted() throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? String(contentsOf: outputURL).contains("sanctuaryd started")) == true {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw HarnessError.timeout
    }

    func waitForExit(_ process: Process, timeout: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning {
                return process.terminationStatus
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    private func daemonExecutable() throws -> URL {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/sanctuaryd"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/release/sanctuaryd")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HarnessError.missingExecutable
    }

    enum HarnessError: Error {
        case missingExecutable
        case timeout
    }
}
