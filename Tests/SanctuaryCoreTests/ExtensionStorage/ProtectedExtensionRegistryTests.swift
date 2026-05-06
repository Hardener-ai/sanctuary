// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ProtectedExtensionRegistryTests {
    private let id = "nkbihfbeogaeaoehlefnkodbefgpgknn"

    @Test func protectAndListRoundTrips() throws {
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: "/tmp/profile", extensionID: id, friendlyName: "MetaMask")

        let rows = try registry.list()

        #expect(rows.count == 1)
        #expect(rows[0].profilePath == "/tmp/profile")
        #expect(rows[0].extensionID == id)
        #expect(rows[0].friendlyName == "MetaMask")
    }

    @Test func duplicateProtectUpsertsSingleRow() throws {
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: "/tmp/profile", extensionID: id, friendlyName: "MetaMask")
        try registry.protect(profilePath: "/tmp/profile", extensionID: id, friendlyName: "MetaMask")

        #expect(try registry.list().count == 1)
    }

    @Test func unprotectRemovesMatchingRowOnly() throws {
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: "/tmp/profile-a", extensionID: id, friendlyName: "MetaMask")
        try registry.protect(profilePath: "/tmp/profile-b", extensionID: id, friendlyName: "MetaMask")

        try registry.unprotect(profilePath: "/tmp/profile-a", extensionID: id)

        let rows = try registry.list()
        #expect(rows.count == 1)
        #expect(rows[0].profilePath == "/tmp/profile-b")
    }

    @Test func protectRejectsInvalidExtensionID() throws {
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())

        #expect(throws: ProtectedExtensionRegistryError.invalidExtensionID("not-an-id")) {
            try registry.protect(profilePath: "/tmp/profile", extensionID: "not-an-id")
        }
    }

    @Test func pathsForActiveProtectionsMaterializesExistingProfile() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-registry-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: profile.appendingPathComponent("IndexedDB/chrome-extension_\(id)_0.indexeddb.leveldb"),
            withIntermediateDirectories: true
        )
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: profile.path, extensionID: id, friendlyName: nil)

        let paths = try registry.pathsForActiveProtections()

        #expect(paths.contains(URL(fileURLWithPath: ExtensionPathMaterializer.normalize(profile.path)).appendingPathComponent("Local Extension Settings/\(id)").path))
        #expect(paths.contains(ExtensionPathMaterializer.normalize(profile.appendingPathComponent("IndexedDB/chrome-extension_\(id)_0.indexeddb.leveldb").path)))
    }

    @Test func friendlyNameDefaultsFromKnownExtension() throws {
        let registry = try ProtectedExtensionRegistry(inMemoryWith: ExtensionPathMaterializer())
        try registry.protect(profilePath: "/tmp/profile", extensionID: id)

        #expect(try registry.list().first?.friendlyName == "MetaMask")
    }
}
