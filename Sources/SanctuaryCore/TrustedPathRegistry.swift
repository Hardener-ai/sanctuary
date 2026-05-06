// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

public protocol TrustedPathChecking: Sendable {
    func contains(_ path: String) -> Bool
}

public final class TrustedPathRegistry: TrustedPathChecking, @unchecked Sendable {
    private let core: PolicyPathRegistryCore

    public convenience init() throws {
        try self.init(databasePath: SanctuaryPaths.policyDatabasePath())
    }

    public convenience init(path: String) throws {
        try self.init(databasePath: path)
    }

    public init(databasePath: String) throws {
        self.core = try PolicyPathRegistryCore(
            databasePath: databasePath,
            table: "trusted_paths",
            index: "idx_trusted_paths_path"
        )
    }

    public func add(_ path: String) throws {
        try core.add(path)
    }

    public func remove(_ path: String) throws {
        try core.remove(path)
    }

    public func contains(_ path: String) -> Bool {
        core.contains(path)
    }

    public func list() -> [String] {
        core.list()
    }
}
