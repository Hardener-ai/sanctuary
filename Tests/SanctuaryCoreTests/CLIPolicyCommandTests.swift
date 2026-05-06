// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
import SanctuaryCore

struct CLIPolicyCommandTests {
    @Test func agentsAddListAndRemoveMutatePolicyDB() throws {
        let fixture = try CLIFixture()
        let binary = try fixture.makeExecutable("dummy-agent")
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        let add = try fixture.run(["agents", "add", binary.path])
        #expect(add.status == 0)
        #expect(add.stdout.contains("Tagged \(canonical) as agent"))
        #expect(try UserTaggedAgentRegistry(path: fixture.db.path).contains(canonical))

        let list = try fixture.run(["agents", "list"])
        #expect(list.stdout.contains("User-tagged agents:"))
        #expect(list.stdout.contains("- \(canonical)"))
        #expect(list.stdout.contains("Bundled known agents:"))

        let remove = try fixture.run(["agents", "remove", binary.path])
        #expect(remove.status == 0)
        let userTaggedAfterRemove = try UserTaggedAgentRegistry(path: fixture.db.path)
        #expect(!userTaggedAfterRemove.contains(canonical))
    }

    @Test func trustAddListAndRemoveMutatePolicyDB() throws {
        let fixture = try CLIFixture()
        let binary = try fixture.makeExecutable("trusted-tool")
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        let add = try fixture.run(["trust", "add", binary.path])
        #expect(add.status == 0)
        #expect(add.stdout.contains("Trusted \(canonical)"))
        #expect(try TrustedPathRegistry(path: fixture.db.path).contains(canonical))

        let list = try fixture.run(["trust", "list"])
        #expect(list.stdout.contains("Trusted paths:"))
        #expect(list.stdout.contains("- \(canonical)"))

        let remove = try fixture.run(["trust", "remove", binary.path])
        #expect(remove.status == 0)
        let trustedAfterRemove = try TrustedPathRegistry(path: fixture.db.path)
        #expect(!trustedAfterRemove.contains(canonical))
    }
}

private struct CLIFixture {
    let root: URL
    let db: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-cli-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = root.appendingPathComponent("policy.sqlite")
    }

    func makeExecutable(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try sanctuaryExecutable()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "SANCTUARY_DB_PATH": db.path,
            "SANCTUARY_AUDIT_PATH": root.appendingPathComponent("audit.log").path,
            "SANCTUARY_INVENTORY_SNAPSHOT_PATH": root.appendingPathComponent("inventory.json").path
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    private func sanctuaryExecutable() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/sanctuary"),
            root.appendingPathComponent(".build/release/sanctuary")
        ]
        guard let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw PolicyPathRegistryError.pathDoesNotExist(".build/debug/sanctuary")
        }
        return match
    }
}
