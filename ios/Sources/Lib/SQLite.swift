import Foundation
import SQLite3

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLite {
    private var db: OpaquePointer?

    init(path: URL) throws {
        try check(sqlite3_open(path.path, &db))
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        sqlite3_close(db)
    }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil))
    }

    func run(_ sql: String, _ parameters: [Any?] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), expecting: SQLITE_DONE)
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ parameters: [Any?] = []) throws -> [Row] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(Row(statement))
            status = sqlite3_step(statement)
        }
        try check(status, expecting: SQLITE_DONE)
        return rows
    }

    private func prepare(_ sql: String, _ parameters: [Any?]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            switch parameter {
            case let value as Int:
                sqlite3_bind_int64(statement, position, Int64(value))
            case let value as String:
                sqlite3_bind_text(statement, position, value, -1, transient)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), transient) }
            case nil:
                sqlite3_bind_null(statement, position)
            default:
                throw SQLiteError(message: "unsupported parameter \(type(of: parameter))")
            }
        }
        return statement
    }

    private func check(_ status: Int32, expecting: Int32 = SQLITE_OK) throws {
        guard status == expecting else {
            throw SQLiteError(message: String(cString: sqlite3_errmsg(db)))
        }
    }
}

struct SQLiteError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct Row {
    private let values: [Any?]

    fileprivate init(_ statement: OpaquePointer?) {
        values = (0..<sqlite3_column_count(statement)).map { column in
            switch sqlite3_column_type(statement, column) {
            case SQLITE_INTEGER:
                return Int(sqlite3_column_int64(statement, column))
            case SQLITE_TEXT:
                return String(cString: sqlite3_column_text(statement, column))
            case SQLITE_BLOB:
                guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
                return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
            default:
                return nil
            }
        }
    }

    func int(_ column: Int) -> Int {
        values[column] as? Int ?? 0
    }

    func text(_ column: Int) -> String {
        values[column] as? String ?? ""
    }

    func blob(_ column: Int) -> Data {
        if let text = values[column] as? String {
            return Data(text.utf8)
        }
        return values[column] as? Data ?? Data()
    }
}
