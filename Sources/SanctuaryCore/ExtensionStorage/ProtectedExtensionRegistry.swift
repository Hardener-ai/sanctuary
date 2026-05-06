// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ProtectedExtension: Equatable, Sendable {
    public let profilePath: String
    public let extensionID: String
    public let friendlyName: String?
    public let addedAt: Int64

    public init(profilePath: String, extensionID: String, friendlyName: String?, addedAt: Int64) {
        self.profilePath = profilePath
        self.extensionID = extensionID
        self.friendlyName = friendlyName
        self.addedAt = addedAt
    }
}

public enum ProtectedExtensionRegistryError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    case invalidExtensionID(String)

    public var description: String {
        switch self {
        case let .sqlite(message):
            return "SQLite error: \(message)"
        case let .invalidExtensionID(id):
            return "invalid Chromium extension ID: \(id)"
        }
    }
}

public final class ProtectedExtensionRegistry: @unchecked Sendable {
    private let db: OpaquePointer?
    private let materializer: ExtensionPathMaterializer
    private let lock = NSLock()

    public convenience init(path: String, materializer: ExtensionPathMaterializer = ExtensionPathMaterializer()) throws {
        try self.init(databasePath: path, materializer: materializer)
    }

    public convenience init(materializer: ExtensionPathMaterializer = ExtensionPathMaterializer()) throws {
        try self.init(databasePath: ProtectedExtensionRegistry.defaultDatabasePath(), materializer: materializer)
    }

    public init(databasePath: String, materializer: ExtensionPathMaterializer = ExtensionPathMaterializer()) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            throw ProtectedExtensionRegistryError.sqlite(message)
        }

        self.db = db
        self.materializer = materializer
        try migrate()
    }

    public convenience init(inMemoryWith materializer: ExtensionPathMaterializer) throws {
        try self.init(databasePath: ":memory:", materializer: materializer)
    }

    deinit {
        sqlite3_close(db)
    }

    public func protect(profilePath: String, extensionID: String, friendlyName: String? = nil) throws {
        let normalizedID = extensionID.lowercased()
        guard KnownExtensions.isValidChromiumExtensionID(normalizedID) else {
            throw ProtectedExtensionRegistryError.invalidExtensionID(extensionID)
        }

        let normalizedProfile = ExtensionPathMaterializer.normalize(profilePath)
        let name = friendlyName ?? KnownExtensions.displayName(for: normalizedID)
        let now = Int64(Date().timeIntervalSince1970)
        try lock.withLock {
            try execute(
                """
                INSERT INTO protected_extensions (profile_path, extension_id, friendly_name, added_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(profile_path, extension_id)
                DO UPDATE SET friendly_name=excluded.friendly_name, added_at=excluded.added_at
                """,
                bindings: [.text(normalizedProfile), .text(normalizedID), .optionalText(name), .int(now)]
            )
        }
    }

    public func unprotect(profilePath: String, extensionID: String) throws {
        let normalizedProfile = ExtensionPathMaterializer.normalize(profilePath)
        let normalizedID = extensionID.lowercased()
        try lock.withLock {
            try execute(
                "DELETE FROM protected_extensions WHERE profile_path = ? AND extension_id = ?",
                bindings: [.text(normalizedProfile), .text(normalizedID)]
            )
        }
    }

    public func list() throws -> [ProtectedExtension] {
        try lock.withLock {
            try query(
                """
                SELECT profile_path, extension_id, friendly_name, added_at
                FROM protected_extensions
                ORDER BY profile_path, friendly_name, extension_id
                """
            )
        }
    }

    public func pathsForActiveProtections() throws -> [String] {
        let rows = try list()
        var paths: [String] = []
        for row in rows {
            paths += materializer.materialize(profilePath: row.profilePath, extensionID: row.extensionID)
        }
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    public func reset() throws {
        try lock.withLock {
            try execute("DROP TABLE IF EXISTS protected_extensions", bindings: [])
            try migrate()
        }
    }

    public static func defaultDatabasePath() -> String {
        SanctuaryPaths.policyDatabasePath()
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS protected_extensions (
                id INTEGER PRIMARY KEY,
                profile_path TEXT NOT NULL,
                extension_id TEXT NOT NULL,
                friendly_name TEXT,
                added_at INTEGER NOT NULL,
                UNIQUE(profile_path, extension_id)
            );
            CREATE INDEX IF NOT EXISTS idx_protected_ext_profile
            ON protected_extensions(profile_path);
            """,
            bindings: []
        )
    }

    private enum SQLiteBinding {
        case text(String)
        case optionalText(String?)
        case int(Int64)
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding]) throws {
        for statementSQL in splitStatements(sql) {
            var statement: OpaquePointer?
            try prepare(statementSQL, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ProtectedExtensionRegistryError.sqlite(lastErrorMessage)
            }
        }
    }

    private func query(_ sql: String) throws -> [ProtectedExtension] {
        var statement: OpaquePointer?
        try prepare(sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var rows: [ProtectedExtension] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                ProtectedExtension(
                    profilePath: String(cString: sqlite3_column_text(statement, 0)),
                    extensionID: String(cString: sqlite3_column_text(statement, 1)),
                    friendlyName: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                    addedAt: sqlite3_column_int64(statement, 3)
                )
            )
        }
        return rows
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProtectedExtensionRegistryError.sqlite(lastErrorMessage)
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case let .optionalText(value):
                if let value {
                    result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
                } else {
                    result = sqlite3_bind_null(statement, index)
                }
            case let .int(value):
                result = sqlite3_bind_int64(statement, index, value)
            }

            guard result == SQLITE_OK else {
                throw ProtectedExtensionRegistryError.sqlite(lastErrorMessage)
            }
        }
    }

    private func splitStatements(_ sql: String) -> [String] {
        sql.split(separator: ";").map(String.init).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private var lastErrorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown SQLite error"
    }
}
