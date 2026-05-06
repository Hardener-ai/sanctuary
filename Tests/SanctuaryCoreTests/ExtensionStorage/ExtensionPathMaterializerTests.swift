// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct ExtensionPathMaterializerTests {
    private let id = "nkbihfbeogaeaoehlefnkodbefgpgknn"

    @Test func missingProfileReturnsEmptyPaths() {
        let materializer = ExtensionPathMaterializer()
        let paths = materializer.materialize(profilePath: "/tmp/sanctuary-missing-\(UUID().uuidString)", extensionID: id)
        #expect(paths.isEmpty)
    }

    @Test func fixedPathsAreMaterializedWhenProfileExists() throws {
        let profile = try makeProfile()
        let paths = ExtensionPathMaterializer().materialize(profilePath: profile.path, extensionID: id)

        #expect(paths.contains(path(profile, "Local Extension Settings/\(id)")))
        #expect(paths.contains(path(profile, "Sync Extension Settings/\(id)")))
        #expect(paths.contains(path(profile, "Extensions/\(id)")))
    }

    @Test func trailingSlashIsNormalized() throws {
        let profile = try makeProfile()
        let noSlash = ExtensionPathMaterializer().materialize(profilePath: profile.path, extensionID: id)
        let withSlash = ExtensionPathMaterializer().materialize(profilePath: profile.path + "/", extensionID: id)
        #expect(noSlash == withSlash)
    }

    @Test func wildcardIndexedDBExpansionFindsMatchingDirectories() throws {
        let profile = try makeProfile()
        try createDirectory(profile.appendingPathComponent("IndexedDB/chrome-extension_\(id)_0.indexeddb.leveldb"))
        try createDirectory(profile.appendingPathComponent("IndexedDB/chrome-extension_other_0.indexeddb.leveldb"))

        let paths = ExtensionPathMaterializer().materialize(profilePath: profile.path, extensionID: id)

        #expect(paths.contains(normalized(profile.appendingPathComponent("IndexedDB/chrome-extension_\(id)_0.indexeddb.leveldb"))))
        #expect(!paths.contains(normalized(profile.appendingPathComponent("IndexedDB/chrome-extension_other_0.indexeddb.leveldb"))))
    }

    @Test func wildcardDatabasesExpansionFindsMatchingDirectories() throws {
        let profile = try makeProfile()
        try createDirectory(profile.appendingPathComponent("databases/chrome-extension_\(id)_1"))

        let paths = ExtensionPathMaterializer().materialize(profilePath: profile.path, extensionID: id)

        #expect(paths.contains(normalized(profile.appendingPathComponent("databases/chrome-extension_\(id)_1"))))
    }

    @Test func wildcardExpansionIgnoresFiles() throws {
        let profile = try makeProfile()
        try createDirectory(profile.appendingPathComponent("IndexedDB"))
        let file = profile.appendingPathComponent("IndexedDB/chrome-extension_\(id)_file")
        FileManager.default.createFile(atPath: file.path, contents: Data())

        let paths = ExtensionPathMaterializer().materialize(profilePath: profile.path, extensionID: id)

        #expect(!paths.contains(normalized(file)))
    }

    private func makeProfile() throws -> URL {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("sanctuary-profile-\(UUID().uuidString)", isDirectory: true)
        try createDirectory(profile)
        return profile
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func normalized(_ url: URL) -> String {
        ExtensionPathMaterializer.normalize(url.path)
    }

    private func path(_ profile: URL, _ relative: String) -> String {
        URL(fileURLWithPath: ExtensionPathMaterializer.normalize(profile.path))
            .appendingPathComponent(relative)
            .path
    }
}
