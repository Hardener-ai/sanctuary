// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import SQLite3

private let protectedFolderSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct ProtectedFolder: Equatable, Sendable {
    public let path: String
    public let addedAt: Int64
    public let source: String

    public init(path: String, addedAt: Int64, source: String) {
        self.path = path
        self.addedAt = addedAt
        self.source = source
    }
}

public enum ProtectedFolderRegistryError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    case invalidSource(String)

    public var description: String {
        switch self {
        case let .sqlite(message):
            return "SQLite error: \(message)"
        case let .invalidSource(source):
            return "invalid protected folder source: \(source)"
        }
    }
}

public final class ProtectedFolderRegistry: @unchecked Sendable {
    public static let setupSentinelPath = "__sanctuary_setup_complete__"

    private let db: OpaquePointer?
    private let lock = NSLock()

    public convenience init() throws {
        try self.init(databasePath: Self.defaultDatabasePath())
    }

    public convenience init(path: String) throws {
        try self.init(databasePath: path)
    }

    public init(databasePath: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            throw ProtectedFolderRegistryError.sqlite(message)
        }

        self.db = db
        try migrate()
    }

    public convenience init(inMemory: Bool) throws {
        try self.init(databasePath: inMemory ? ":memory:" : Self.defaultDatabasePath())
    }

    deinit {
        sqlite3_close(db)
    }

    public func protect(path: String, source: String) throws {
        guard source == "default" || source == "user" else {
            throw ProtectedFolderRegistryError.invalidSource(source)
        }
        let normalized = Self.normalize(path)
        let now = Int64(Date().timeIntervalSince1970)
        try lock.withLock {
            try execute(
                """
                INSERT INTO protected_folders (path, added_at, source)
                VALUES (?, ?, ?)
                ON CONFLICT(path)
                DO UPDATE SET added_at=excluded.added_at, source=excluded.source
                """,
                bindings: [.text(normalized), .int(now), .text(source)]
            )
        }
    }

    public func unprotect(path: String) throws {
        let normalized = Self.normalize(path)
        try lock.withLock {
            try execute("DELETE FROM protected_folders WHERE path = ?", bindings: [.text(normalized)])
        }
    }

    public func list() throws -> [ProtectedFolder] {
        try query(whereClause: nil, bindings: [])
    }

    public func list(bySource source: String) throws -> [ProtectedFolder] {
        guard source == "default" || source == "user" else {
            throw ProtectedFolderRegistryError.invalidSource(source)
        }
        return try query(whereClause: "source = ?", bindings: [.text(source)])
    }

    public func markSetupComplete() throws {
        try protect(path: Self.setupSentinelPath, source: "default")
    }

    public func reset() throws {
        try lock.withLock {
            try execute("DROP TABLE IF EXISTS protected_folders", bindings: [])
            try migrate()
        }
    }

    public func isSetupComplete() throws -> Bool {
        try lock.withLock {
            var statement: OpaquePointer?
            try prepare("SELECT 1 FROM protected_folders WHERE path = ? LIMIT 1", statement: &statement)
            defer { sqlite3_finalize(statement) }
            try bind([.text(Self.setupSentinelPath)], to: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    public func existingWatchedPaths(fileManager: FileManager = .default) throws -> [String] {
        try list()
            .map(\.path)
            .filter { $0 != Self.setupSentinelPath }
            .filter { fileManager.fileExists(atPath: $0) }
    }

    public static func defaultDatabasePath() -> String {
        SanctuaryPaths.policyDatabasePath()
    }

    public static func normalize(_ path: String) -> String {
        let expanded = path.replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [.anchored])
        return ExtensionPathMaterializer.normalize(expanded)
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS protected_folders (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                added_at INTEGER NOT NULL,
                source TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_protected_folders_source
            ON protected_folders(source);
            """,
            bindings: []
        )
    }

    private enum SQLiteBinding {
        case text(String)
        case int(Int64)
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding]) throws {
        for statementSQL in splitStatements(sql) {
            var statement: OpaquePointer?
            try prepare(statementSQL, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try bind(bindings, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ProtectedFolderRegistryError.sqlite(lastErrorMessage)
            }
        }
    }

    private func query(whereClause: String?, bindings: [SQLiteBinding]) throws -> [ProtectedFolder] {
        try lock.withLock {
            var sql = """
            SELECT path, added_at, source
            FROM protected_folders
            WHERE path != ?
            """
            var allBindings: [SQLiteBinding] = [.text(Self.setupSentinelPath)]
            if let whereClause {
                sql += " AND \(whereClause)"
                allBindings += bindings
            }
            sql += " ORDER BY source, path"

            var statement: OpaquePointer?
            try prepare(sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try bind(allBindings, to: statement)

            var rows: [ProtectedFolder] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(
                    ProtectedFolder(
                        path: String(cString: sqlite3_column_text(statement, 0)),
                        addedAt: sqlite3_column_int64(statement, 1),
                        source: String(cString: sqlite3_column_text(statement, 2))
                    )
                )
            }
            return rows
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProtectedFolderRegistryError.sqlite(lastErrorMessage)
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, protectedFolderSQLiteTransient)
            case let .int(value):
                result = sqlite3_bind_int64(statement, index, value)
            }
            guard result == SQLITE_OK else {
                throw ProtectedFolderRegistryError.sqlite(lastErrorMessage)
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
