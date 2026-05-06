// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct UserTaggedAgentRegistryTests {
    @Test func addStoresCanonicalPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(binary.path)

        #expect(registry.list() == [canonical])
    }

    @Test func containsReturnsTrueForStoredPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)

        try registry.add(binary.path)

        #expect(registry.contains(binary.path))
    }

    @Test func removeDeletesStoredPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)

        try registry.add(binary.path)
        try registry.remove(binary.path)

        #expect(!registry.contains(binary.path))
        #expect(registry.list().isEmpty)
    }

    @Test func removeIsIdempotent() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)

        try registry.remove(binary.path)

        #expect(registry.list().isEmpty)
    }

    @Test func addIsUpsertNotDuplicate() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(binary.path)
        try registry.add(binary.path)

        #expect(registry.list() == [canonical])
    }

    @Test func symlinkCanonicalizesToRealPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("agent")
        let link = fixture.root.appendingPathComponent("agent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let registry = try UserTaggedAgentRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(link.path)

        #expect(registry.list() == [canonical])
        #expect(registry.contains(link.path))
    }
}

struct TrustedPathRegistryTests {
    @Test func addStoresCanonicalPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let registry = try TrustedPathRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(binary.path)

        #expect(registry.list() == [canonical])
    }

    @Test func containsReturnsTrueForStoredPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let registry = try TrustedPathRegistry(path: fixture.db.path)

        try registry.add(binary.path)

        #expect(registry.contains(binary.path))
    }

    @Test func removeDeletesStoredPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let registry = try TrustedPathRegistry(path: fixture.db.path)

        try registry.add(binary.path)
        try registry.remove(binary.path)

        #expect(!registry.contains(binary.path))
        #expect(registry.list().isEmpty)
    }

    @Test func removeIsIdempotent() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let registry = try TrustedPathRegistry(path: fixture.db.path)

        try registry.remove(binary.path)

        #expect(registry.list().isEmpty)
    }

    @Test func addIsUpsertNotDuplicate() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let registry = try TrustedPathRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(binary.path)
        try registry.add(binary.path)

        #expect(registry.list() == [canonical])
    }

    @Test func symlinkCanonicalizesToRealPath() throws {
        let fixture = try RegistryFixture()
        let binary = try fixture.makeExecutable("trusted")
        let link = fixture.root.appendingPathComponent("trusted-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let registry = try TrustedPathRegistry(path: fixture.db.path)
        let canonical = try PolicyExecutablePath.canonicalize(binary.path)

        try registry.add(link.path)

        #expect(registry.list() == [canonical])
        #expect(registry.contains(link.path))
    }
}

private struct RegistryFixture {
    let root: URL
    let db: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-policy-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        db = root.appendingPathComponent("policy.sqlite")
    }

    func makeExecutable(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
