import Foundation
import SQLite3

public enum LedgerStatus: String, Sendable {
    case imported
    case failed
    case baseline
}

public enum LedgerCheck: Equatable, Sendable {
    case handled
    case new(FileFingerprint)
    case previouslyFailed(FileFingerprint)
}

public struct LedgerEntry: Equatable, Sendable {
    public let fingerprint: FileFingerprint
    public let path: String
    public let modified: Date
    public let status: LedgerStatus
    public let timestamp: Date
    public let assetID: String?
    public let errorMessage: String?
    public let attempts: Int

    public init(
        fingerprint: FileFingerprint,
        path: String,
        modified: Date,
        status: LedgerStatus,
        timestamp: Date,
        assetID: String? = nil,
        errorMessage: String? = nil,
        attempts: Int = 1
    ) {
        self.fingerprint = fingerprint
        self.path = path
        self.modified = modified
        self.status = status
        self.timestamp = timestamp
        self.assetID = assetID
        self.errorMessage = errorMessage
        self.attempts = attempts
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

public struct BaselineItem: Sendable {
    public let fingerprint: FileFingerprint
    public let url: URL
    public let modified: Date

    public init(fingerprint: FileFingerprint, url: URL, modified: Date) {
        self.fingerprint = fingerprint
        self.url = url
        self.modified = modified
    }
}

public struct LedgerError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }

    public init(message: String) {
        self.message = message
    }
}

public final class ImportLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw lastError()
        }
        try execute("""
            CREATE TABLE IF NOT EXISTS entries (
                name TEXT NOT NULL,
                size INTEGER NOT NULL,
                head_hash TEXT NOT NULL,
                path TEXT NOT NULL,
                modified REAL NOT NULL,
                status TEXT NOT NULL,
                timestamp REAL NOT NULL,
                asset_id TEXT,
                error TEXT,
                attempts INTEGER NOT NULL,
                PRIMARY KEY (name, size, head_hash)
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS entries_path ON entries (path)")
        try execute("CREATE INDEX IF NOT EXISTS entries_status_timestamp ON entries (status, timestamp)")
    }

    deinit {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        sqlite3_close(db)
    }

    public func check(_ url: URL) throws -> LedgerCheck {
        guard let snapshot = FileSnapshot.read(at: url) else {
            throw LedgerError(message: "Cannot read file at \(url.path)")
        }
        if let known = try lock.withLock({ try unchangedMatch(path: url.path, snapshot: snapshot) }) {
            return known
        }
        // Hashing stays outside the lock so a slow drive does not block other callers.
        let fingerprint = try FileFingerprint(url: url)
        return try lock.withLock {
            try contentMatch(fingerprint, path: url.path, modified: snapshot.modified)
        }
    }

    public func markImported(
        _ fingerprint: FileFingerprint,
        url: URL,
        modified: Date,
        assetID: String?,
        at timestamp: Date = Date()
    ) throws {
        try lock.withLock {
            try execute("""
                INSERT INTO entries (name, size, head_hash, path, modified, status, timestamp, asset_id, error, attempts)
                VALUES (?1, ?2, ?3, ?4, ?5, 'imported', ?6, ?7, NULL, 1)
                ON CONFLICT (name, size, head_hash) DO UPDATE SET
                    path = excluded.path, modified = excluded.modified, status = 'imported',
                    timestamp = excluded.timestamp, asset_id = excluded.asset_id, error = NULL,
                    attempts = attempts + 1
                """, identity(fingerprint) + [.text(url.path), .date(modified), .date(timestamp), .optionalText(assetID)])
        }
    }

    public func markFailed(
        _ fingerprint: FileFingerprint,
        url: URL,
        modified: Date,
        error: String,
        at timestamp: Date = Date()
    ) throws {
        try lock.withLock {
            // A failure never downgrades a row that is already imported or baseline.
            try execute("""
                INSERT INTO entries (name, size, head_hash, path, modified, status, timestamp, asset_id, error, attempts)
                VALUES (?1, ?2, ?3, ?4, ?5, 'failed', ?6, NULL, ?7, 1)
                ON CONFLICT (name, size, head_hash) DO UPDATE SET
                    path = excluded.path, modified = excluded.modified, timestamp = excluded.timestamp,
                    error = excluded.error, attempts = attempts + 1
                WHERE status = 'failed'
                """, identity(fingerprint) + [.text(url.path), .date(modified), .date(timestamp), .text(error)])
        }
    }

    public func markBaseline(
        _ fingerprint: FileFingerprint,
        url: URL,
        modified: Date,
        at timestamp: Date = Date()
    ) throws {
        try markBaseline([BaselineItem(fingerprint: fingerprint, url: url, modified: modified)], at: timestamp)
    }

    public func markBaseline(_ items: [BaselineItem], at timestamp: Date = Date()) throws {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                for item in items {
                    try execute("""
                        INSERT INTO entries (name, size, head_hash, path, modified, status, timestamp, asset_id, error, attempts)
                        VALUES (?1, ?2, ?3, ?4, ?5, 'baseline', ?6, NULL, NULL, 0)
                        ON CONFLICT (name, size, head_hash) DO UPDATE SET
                            path = excluded.path, modified = excluded.modified, status = 'baseline',
                            timestamp = excluded.timestamp, error = NULL
                        WHERE status = 'failed'
                        """, identity(item.fingerprint) + [.text(item.url.path), .date(item.modified), .date(timestamp)])
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func failedEntries() throws -> [LedgerEntry] {
        try lock.withLock {
            try query("SELECT \(Self.entryColumns) FROM entries WHERE status = 'failed' ORDER BY timestamp, rowid", read: entry)
        }
    }

    public func importedCount(since date: Date) throws -> Int {
        try lock.withLock {
            try query("SELECT COUNT(*) FROM entries WHERE status = 'imported' AND timestamp >= ?1", [.date(date)]) {
                Int(sqlite3_column_int64($0, 0))
            }.first ?? 0
        }
    }

    public func recent(limit: Int) throws -> [LedgerEntry] {
        try lock.withLock {
            try query("""
                SELECT \(Self.entryColumns) FROM entries WHERE status IN ('imported', 'failed')
                ORDER BY timestamp DESC, rowid DESC LIMIT ?1
                """, [.integer(Int64(limit))], read: entry)
        }
    }

    public func entryCount() throws -> Int {
        try lock.withLock {
            try query("SELECT COUNT(*) FROM entries") { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
        }
    }

    private func unchangedMatch(path: String, snapshot: FileSnapshot) throws -> LedgerCheck? {
        // Dates are compared loosely because the same file time can differ by rounding depending on who read it.
        let matches = try query("""
            SELECT name, size, head_hash, status FROM entries
            WHERE path = ?1 AND size = ?2 AND ABS(modified - ?3) < 0.001
            ORDER BY status = 'failed' LIMIT 1
            """, [.text(path), .integer(snapshot.size), .date(snapshot.modified)]) { row in
            (fingerprint: fingerprint(row), status: text(row, 3))
        }
        guard let match = matches.first else { return nil }
        return match.status == LedgerStatus.failed.rawValue ? .previouslyFailed(match.fingerprint) : .handled
    }

    private func contentMatch(_ fingerprint: FileFingerprint, path: String, modified: Date) throws -> LedgerCheck {
        let statuses = try query(
            "SELECT status FROM entries WHERE name = ?1 AND size = ?2 AND head_hash = ?3",
            identity(fingerprint)
        ) { text($0, 0) }
        guard let status = statuses.first else { return .new(fingerprint) }

        try execute(
            "UPDATE entries SET path = ?4, modified = ?5 WHERE name = ?1 AND size = ?2 AND head_hash = ?3",
            identity(fingerprint) + [.text(path), .date(modified)]
        )
        return status == LedgerStatus.failed.rawValue ? .previouslyFailed(fingerprint) : .handled
    }

    // MARK: - SQLite plumbing

    private enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
        case null

        static func date(_ date: Date) -> Value { .real(date.timeIntervalSince1970) }
        static func optionalText(_ text: String?) -> Value { text.map(Value.text) ?? .null }
    }

    private static let entryColumns = "name, size, head_hash, path, modified, status, timestamp, asset_id, error, attempts"

    private func identity(_ fingerprint: FileFingerprint) -> [Value] {
        [.text(fingerprint.name), .integer(fingerprint.size), .text(fingerprint.headHash)]
    }

    private func fingerprint(_ row: OpaquePointer) -> FileFingerprint {
        FileFingerprint(name: text(row, 0) ?? "", size: sqlite3_column_int64(row, 1), headHash: text(row, 2) ?? "")
    }

    private func entry(_ row: OpaquePointer) -> LedgerEntry {
        LedgerEntry(
            fingerprint: fingerprint(row),
            path: text(row, 3) ?? "",
            modified: Date(timeIntervalSince1970: sqlite3_column_double(row, 4)),
            status: text(row, 5).flatMap(LedgerStatus.init) ?? .failed,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(row, 6)),
            assetID: text(row, 7),
            errorMessage: text(row, 8),
            attempts: Int(sqlite3_column_int64(row, 9))
        )
    }

    private func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }

    private func lastError() -> LedgerError {
        LedgerError(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the import ledger")
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in }
    }

    private func query<Row>(_ sql: String, _ values: [Value] = [], read: (OpaquePointer) -> Row) throws -> [Row] {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (offset, value) in values.enumerated() {
            try bind(value, to: statement, at: Int32(offset + 1))
        }

        var rows: [Row] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(statement))
            case SQLITE_DONE: return rows
            default: throw lastError()
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        statements[sql] = statement
        return statement
    }

    private func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) throws {
        // SQLITE_TRANSIENT, which Swift cannot import: tells SQLite to copy the string.
        let copyText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = switch value {
        case .text(let text): sqlite3_bind_text(statement, index, text, -1, copyText)
        case .integer(let number): sqlite3_bind_int64(statement, index, number)
        case .real(let number): sqlite3_bind_double(statement, index, number)
        case .null: sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw lastError() }
    }
}
