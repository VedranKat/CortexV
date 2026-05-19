import Foundation
import SQLite3

enum SQLiteError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
    case missingGeneratedID
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): "Failed to open SQLite database: \(message)"
        case .prepareFailed(let message): "Failed to prepare SQLite statement: \(message)"
        case .stepFailed(let message): "Failed to execute SQLite statement: \(message)"
        case .bindFailed(let message): "Failed to bind SQLite value: \(message)"
        case .missingGeneratedID: "SQLite did not return a generated id."
        case .notFound(let message): message
        }
    }
}

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case bool(Bool)
    case date(Date)
}

final class SQLiteDatabase {
    private let path: String
    private let dateFormatter = ISO8601DateFormatter()

    init(path: String = AppPaths.databaseFile.path) {
        self.path = path
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        try withConnection { connection in
            try execute(sql, values: values, connection: connection)
        }
    }

    func query<T>(_ sql: String, values: [SQLiteValue] = [], map: (SQLiteStatement) throws -> T) throws -> [T] {
        try withConnection { connection in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw SQLiteError.prepareFailed(lastErrorMessage(connection))
            }
            defer { sqlite3_finalize(statement) }

            try bind(values, to: statement, connection: connection)
            var rows: [T] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_ROW {
                    rows.append(try map(SQLiteStatement(statement: statement, dateFormatter: dateFormatter)))
                } else if result == SQLITE_DONE {
                    return rows
                } else {
                    throw SQLiteError.stepFailed(lastErrorMessage(connection))
                }
            }
        }
    }

    func insert(_ sql: String, values: [SQLiteValue] = []) throws -> Int64 {
        try withConnection { connection in
            try insert(sql, values: values, connection: connection)
        }
    }

    func transaction(_ work: (SQLiteTransaction) throws -> Void) throws {
        try withConnection { connection in
            let transaction = SQLiteTransaction(database: self, connection: connection)
            try transaction.execute("BEGIN IMMEDIATE")
            do {
                try work(transaction)
                try transaction.execute("COMMIT")
            } catch {
                try? transaction.execute("ROLLBACK")
                throw error
            }
        }
    }

    fileprivate func execute(_ sql: String, values: [SQLiteValue] = [], connection: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(lastErrorMessage(connection))
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement, connection: connection)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(lastErrorMessage(connection))
        }
    }

    fileprivate func insert(_ sql: String, values: [SQLiteValue] = [], connection: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(lastErrorMessage(connection))
        }
        defer { sqlite3_finalize(statement) }

        try bind(values, to: statement, connection: connection)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(lastErrorMessage(connection))
        }
        let id = sqlite3_last_insert_rowid(connection)
        guard id > 0 else { throw SQLiteError.missingGeneratedID }
        return id
    }

    func nowString() -> String {
        dateFormatter.string(from: Date())
    }

    func dateString(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private func withConnection<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        guard sqlite3_open(path, &connection) == SQLITE_OK, let connection else {
            throw SQLiteError.openFailed(lastErrorMessage(connection))
        }
        defer { sqlite3_close(connection) }
        return try work(connection)
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer, connection: OpaquePointer) throws {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, position)
            case .int(let value):
                result = sqlite3_bind_int64(statement, position, value)
            case .double(let value):
                result = sqlite3_bind_double(statement, position, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            case .bool(let value):
                result = sqlite3_bind_int(statement, position, value ? 1 : 0)
            case .date(let value):
                result = sqlite3_bind_text(statement, position, dateFormatter.string(from: value), -1, SQLITE_TRANSIENT)
            }
            guard result == SQLITE_OK else {
                throw SQLiteError.bindFailed(lastErrorMessage(connection))
            }
        }
    }

    private func lastErrorMessage(_ connection: OpaquePointer? = nil) -> String {
        guard let connection, let message = sqlite3_errmsg(connection) else {
            return "Unknown SQLite error"
        }
        return String(cString: message)
    }
}

struct SQLiteTransaction {
    fileprivate let database: SQLiteDatabase
    fileprivate let connection: OpaquePointer

    func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        try database.execute(sql, values: values, connection: connection)
    }

    func insert(_ sql: String, values: [SQLiteValue] = []) throws -> Int64 {
        try database.insert(sql, values: values, connection: connection)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SQLiteStatement {
    let statement: OpaquePointer
    let dateFormatter: ISO8601DateFormatter

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func optionalInt64(_ column: Int32) -> Int64? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func bool(_ column: Int32) -> Bool {
        sqlite3_column_int(statement, column) == 1
    }

    func text(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: value)
    }

    func optionalText(_ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(column)
    }

    func date(_ column: Int32) -> Date {
        parseDate(text(column)) ?? Date(timeIntervalSince1970: 0)
    }

    func optionalDate(_ column: Int32) -> Date? {
        guard let value = optionalText(column) else { return nil }
        return parseDate(value)
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = dateFormatter.date(from: value) {
            return date
        }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: value)
    }
}
