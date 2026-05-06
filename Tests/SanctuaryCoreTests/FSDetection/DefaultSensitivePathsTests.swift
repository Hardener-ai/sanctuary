// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SanctuaryCore

struct DefaultSensitivePathsTests {
    @Test func expandsTildeAgainstHomeDirectory() {
        let home = URL(fileURLWithPath: "/tmp/sanctuary-home")

        #expect(DefaultSensitivePaths.expand(template: "~/.ssh", homeDirectory: home) == "/tmp/sanctuary-home/.ssh")
    }

    @Test func displayPathCompactsHomeDirectory() {
        let home = URL(fileURLWithPath: "/tmp/sanctuary-home")

        #expect(DefaultSensitivePaths.displayPath("/tmp/sanctuary-home/.aws", homeDirectory: home) == "~/.aws")
    }

    @Test func missingDefaultsAreFiltered() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-empty-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(DefaultSensitivePaths.existingPaths(homeDirectory: home).isEmpty)
    }

    @Test func existingDefaultsAreReturned() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("sanctuary-home-\(UUID().uuidString)", isDirectory: true)
        let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
        let ledger = home.appendingPathComponent("Library/Application Support/Ledger Live", isDirectory: true)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = DefaultSensitivePaths.existingPaths(homeDirectory: home)

        #expect(paths.contains(ExtensionPathMaterializer.normalize(ssh.path)))
        #expect(paths.contains(ExtensionPathMaterializer.normalize(ledger.path)))
    }

    @Test func templatesIncludeCryptoWalletPaths() {
        #expect(DefaultSensitivePaths.templates.contains("~/Library/Application Support/Electrum"))
        #expect(DefaultSensitivePaths.templates.contains("~/Library/Application Support/io.kek-wallet"))
        #expect(DefaultSensitivePaths.templates.contains("~/.config/solana"))
    }
}
