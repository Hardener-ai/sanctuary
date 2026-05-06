// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation

public struct ExtensionPathMaterializer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func materialize(profilePath: String, extensionID: String) -> [String] {
        let profileURL = URL(fileURLWithPath: Self.normalize(profilePath), isDirectory: true)
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return []
        }

        let id = extensionID.lowercased()
        var paths: [String] = [
            profileURL.appendingPathComponent("Local Extension Settings/\(id)", isDirectory: true).path,
            profileURL.appendingPathComponent("Sync Extension Settings/\(id)", isDirectory: true).path,
            profileURL.appendingPathComponent("Extensions/\(id)", isDirectory: true).path
        ]

        paths += wildcardDirectories(
            under: profileURL.appendingPathComponent("IndexedDB", isDirectory: true),
            prefix: "chrome-extension_\(id)_"
        )
        paths += wildcardDirectories(
            under: profileURL.appendingPathComponent("databases", isDirectory: true),
            prefix: "chrome-extension_\(id)_"
        )

        return stableUnique(paths.map(Self.normalize))
    }

    public static func normalize(_ path: String) -> String {
        let standardized = NSString(string: path).standardizingPath
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let canonical = realpath(standardized, &resolved).map { String(cString: $0) } ?? standardized
        guard canonical.count > 1 else {
            return canonical
        }
        return canonical.hasSuffix("/") ? String(canonical.dropLast()) : canonical
    }

    private func wildcardDirectories(under root: URL, prefix: String) -> [String] {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return contents.compactMap { url in
            guard url.lastPathComponent.hasPrefix(prefix) else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else {
                return nil
            }

            return url.path
        }.sorted()
    }

    private func stableUnique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in paths where !seen.contains(path) {
            seen.insert(path)
            result.append(path)
        }
        return result
    }
}
