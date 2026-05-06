// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ProtectedFolderRegistryTests {
    @Test func protectAndListUserFolder() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        try registry.protect(path: "/tmp/sanctuary-folder", source: "user")

        #expect(try registry.list() == [
            ProtectedFolder(path: "/tmp/sanctuary-folder", addedAt: try #require(try registry.list().first).addedAt, source: "user"),
        ])
    }

    @Test func duplicateProtectUpdatesSource() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        try registry.protect(path: "/tmp/sanctuary-folder", source: "user")
        try registry.protect(path: "/tmp/sanctuary-folder", source: "default")

        #expect(try registry.list().map(\.source) == ["default"])
    }

    @Test func unprotectRemovesFolder() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)
        try registry.protect(path: "/tmp/sanctuary-folder", source: "user")

        try registry.unprotect(path: "/tmp/sanctuary-folder")

        #expect(try registry.list().isEmpty)
    }

    @Test func listBySourceFiltersRows() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)
        try registry.protect(path: "/tmp/user-folder", source: "user")
        try registry.protect(path: "/tmp/default-folder", source: "default")

        #expect(try registry.list(bySource: "user").map(\.path) == ["/tmp/user-folder"])
        #expect(try registry.list(bySource: "default").map(\.path) == ["/tmp/default-folder"])
    }

    @Test func invalidProtectSourceThrows() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        #expect(throws: ProtectedFolderRegistryError.invalidSource("system")) {
            try registry.protect(path: "/tmp/x", source: "system")
        }
    }

    @Test func invalidListSourceThrows() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        #expect(throws: ProtectedFolderRegistryError.invalidSource("system")) {
            _ = try registry.list(bySource: "system")
        }
    }

    @Test func setupSentinelIsHiddenFromList() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        try registry.markSetupComplete()

        #expect(try registry.isSetupComplete())
        #expect(try registry.list().isEmpty)
    }

    @Test func setupCompleteDefaultsToFalse() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        #expect(try !registry.isSetupComplete())
    }

    @Test func existingWatchedPathsFiltersMissingPaths() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-existing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        try registry.protect(path: existing.path, source: "user")
        try registry.protect(path: "/tmp/does-not-exist-\(UUID().uuidString)", source: "user")

        #expect(try registry.existingWatchedPaths() == [ExtensionPathMaterializer.normalize(existing.path)])
    }

    @Test func normalizesTrailingSlash() throws {
        let registry = try ProtectedFolderRegistry(inMemory: true)

        try registry.protect(path: "/tmp/sanctuary-folder/", source: "user")

        #expect(try registry.list().map(\.path) == ["/tmp/sanctuary-folder"])
    }
}
