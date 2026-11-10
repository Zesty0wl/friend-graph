import Foundation
import SQLite3

/// A read-only SQLite connection. Every database this app opens belongs to another app or to macOS,
/// so nothing here can write.
final class Database {
    enum Value {
        case int(Int64), real(Double), text(String), blob(Data), null

        var string: String? {
            switch self {
            case .text(let s): return s
            case .int(let i): return String(i)
            case .real(let d): return String(d)
            default: return nil
            }
        }
        var double: Double? {
            switch self {
            case .real(let d): return d
            case .int(let i): return Double(i)
            case .text(let s): return Double(s)
            default: return nil
            }
        }
        var int: Int? {
            switch self {
            case .int(let i): return Int(i)
            case .real(let d): return Int(d)
            case .text(let s): return Int(s)
            default: return nil
            }
        }
        var data: Data? { if case .blob(let d) = self { return d }; return nil }
    }

    private var handle: OpaquePointer?

    init?(_ path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let escaped = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        if sqlite3_open_v2("file:" + escaped + "?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 2000)
        // A database we cannot actually read (no Full Disk Access) opens fine and fails on first use.
        if sqlite3_exec(handle, "SELECT count(*) FROM sqlite_master", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(handle)
            return nil
        }
    }

    deinit { sqlite3_close(handle) }

    /// Runs a query and hands each row to `body`. A query that fails (a table missing on this
    /// version of macOS, say) yields no rows and returns false.
    @discardableResult
    func each(_ sql: String, _ binds: [String] = [], _ body: ([Value]) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in binds.enumerated() {
            sqlite3_bind_text(statement, Int32(i + 1), value, -1, transient)
        }
        let columns = sqlite3_column_count(statement)
        var row = [Value](repeating: .null, count: Int(columns))
        while sqlite3_step(statement) == SQLITE_ROW {
            for c in 0..<columns {
                switch sqlite3_column_type(statement, c) {
                case SQLITE_INTEGER: row[Int(c)] = .int(sqlite3_column_int64(statement, c))
                case SQLITE_FLOAT: row[Int(c)] = .real(sqlite3_column_double(statement, c))
                case SQLITE_TEXT:
                    // Decode leniently: a stray invalid byte should not lose the row.
                    if let bytes = sqlite3_column_blob(statement, c) {
                        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, c)))
                        row[Int(c)] = .text(String(decoding: data, as: UTF8.self))
                    } else { row[Int(c)] = .text("") }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, c) {
                        row[Int(c)] = .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, c))))
                    } else { row[Int(c)] = .blob(Data()) }
                default: row[Int(c)] = .null
                }
            }
            body(row)
        }
        return true
    }

    func rows(_ sql: String, _ binds: [String] = []) -> [[Value]] {
        var out: [[Value]] = []
        each(sql, binds) { out.append($0) }
        return out
    }
}
