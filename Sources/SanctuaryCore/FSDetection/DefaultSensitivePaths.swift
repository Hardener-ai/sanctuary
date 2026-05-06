// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public enum DefaultSensitivePaths {
    public static let templates: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config/solana",
        "~/.config/sui",
        "~/.bitcoin",
        "~/.electrum",
        "~/Library/Application Support/Electrum",
        "~/Library/Application Support/Bitcoin",
        "~/Library/Application Support/Ethereum",
        "~/Library/Application Support/Ledger Live",
        "~/Library/Application Support/Exodus",
        "~/Library/Application Support/Atomic",
        "~/Library/Application Support/io.kek-wallet",
    ]

    public static func existingPaths(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [String] {
        templates
            .map { expand(template: $0, homeDirectory: homeDirectory) }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    public static func expand(template: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let homePath = ExtensionPathMaterializer.normalize(homeDirectory.path)
        if template == "~" {
            return homePath
        }
        if template.hasPrefix("~/") {
            return ExtensionPathMaterializer.normalize(homePath + "/" + String(template.dropFirst(2)))
        }
        return ExtensionPathMaterializer.normalize(template)
    }

    public static func displayPath(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let normalized = ExtensionPathMaterializer.normalize(path)
        let homePath = ExtensionPathMaterializer.normalize(homeDirectory.path)
        if normalized == homePath {
            return "~"
        }
        if normalized.hasPrefix(homePath + "/") {
            return "~/" + String(normalized.dropFirst(homePath.count + 1))
        }
        return normalized
    }
}
