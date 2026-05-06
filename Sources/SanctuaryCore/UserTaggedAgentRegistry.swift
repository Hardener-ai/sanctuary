// SPDX-License-Identifier: AGPL-3.0-only
import Darwin
import Foundation
import SQLite3

private let userTaggedAgentSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public protocol UserTaggedAgentChecking: Sendable {
    func contains(_ path: String) -> Bool
}

public enum PolicyExecutablePath {
    public static func canonicalize(_ path: String, requireExists: Bool = false) throws -> String {
        let expanded = path.replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [.anchored])
        if let resolved = expanded.withCString({ realpath($0, nil) }) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        if requireExists {
            throw PolicyPathRegistryError.pathDoesNotExist(path)
        }
        return ExtensionPathMaterializer.normalize(expanded)
    }
}

public enum PolicyPathRegistryError: Error, Equatable, CustomStringConvertible {
    case sqlite(String)
    case pathDoesNotExist(String)

    public var description: String {
        switch self {
        case let .sqlite(message):
            return "SQLite error: \(message)"
        case let .pathDoesNotExist(path):
            return "path does not exist: \(path)"
        }
    }
}

public final class UserTaggedAgentRegistry: UserTaggedAgentChecking, @unchecked Sendable {
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
            table: "user_tagged_agents",
            index: "idx_user_tagged_agents_path"
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

final class PolicyPathRegistryCore: @unchecked Sendable {
    private let db: OpaquePointer?
    private let table: String
    private let index: String
    private let lock = NSLock()

    init(databasePath: String, table: String, index: String) throws {
        self.table = table
        self.index = index
        if databasePath != ":memory:" {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: databasePath).deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databasePath, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open database"
            throw PolicyPathRegistryError.sqlite(message)
        }
        self.db = db
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    func add(_ path: String) throws {
        let canonical = try PolicyExecutablePath.canonicalize(path)
        let now = Int64(Date().timeIntervalSince1970)
        try lock.withLock {
            try execute(
                """
                INSERT INTO \(table) (executable_path, added_at)
                VALUES (?, ?)
                ON CONFLICT(executable_path)
                DO UPDATE SET added_at=excluded.added_at
                """,
                bindings: [.text(canonical), .int(now)]
            )
        }
    }

    func remove(_ path: String) throws {
        let canonical = try PolicyExecutablePath.canonicalize(path)
        try lock.withLock {
            try execute("DELETE FROM \(table) WHERE executable_path = ?", bindings: [.text(canonical)])
        }
    }

    func contains(_ path: String) -> Bool {
        guard let canonical = try? PolicyExecutablePath.canonicalize(path) else {
            return false
        }
        return lock.withLock {
            do {
                var statement: OpaquePointer?
                try prepare("SELECT 1 FROM \(table) WHERE executable_path = ? LIMIT 1", statement: &statement)
                defer { sqlite3_finalize(statement) }
                try bind([.text(canonical)], to: statement)
                return sqlite3_step(statement) == SQLITE_ROW
            } catch {
                return false
            }
        }
    }

    func list() -> [String] {
        lock.withLock {
            do {
                var statement: OpaquePointer?
                try prepare("SELECT executable_path FROM \(table) ORDER BY executable_path", statement: &statement)
                defer { sqlite3_finalize(statement) }
                var rows: [String] = []
                while sqlite3_step(statement) == SQLITE_ROW {
                    rows.append(String(cString: sqlite3_column_text(statement, 0)))
                }
                return rows
            } catch {
                return []
            }
        }
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS \(table) (
                id INTEGER PRIMARY KEY,
                executable_path TEXT NOT NULL UNIQUE,
                added_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS \(index)
            ON \(table)(executable_path);
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
                throw PolicyPathRegistryError.sqlite(lastErrorMessage)
            }
        }
    }

    private func prepare(_ sql: String, statement: inout OpaquePointer?) throws {
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PolicyPathRegistryError.sqlite(lastErrorMessage)
        }
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer?) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, userTaggedAgentSQLiteTransient)
            case let .int(value):
                result = sqlite3_bind_int64(statement, index, value)
            }
            guard result == SQLITE_OK else {
                throw PolicyPathRegistryError.sqlite(lastErrorMessage)
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
