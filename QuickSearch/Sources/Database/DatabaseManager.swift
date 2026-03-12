// DatabaseManager.swift — Thread-safe SQLite actor wrapping raw C API
// All queries MUST use parameterised binding; no SQL string concatenation.

import Foundation
import SQLite3

// SQLITE_TRANSIENT is a C macro; define the Swift equivalent here.
private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - FileInsertRecord
// Defined here (Database module) so writeBatch can be a single atomic actor method
// that never suspends internally — avoiding Swift actor re-entrancy issues.

public struct FileInsertRecord: Sendable {
    public let volumeID: Int64
    public let relPath: String
    public let name: String
    public let fileExt: String
    public let size: Int64
    public let modTimeNs: Int64
    public let isDir: Bool
    public let inode: UInt64
    public let updatedAt: Double

    public init(volumeID: Int64, relPath: String, name: String, fileExt: String,
                size: Int64, modTimeNs: Int64, isDir: Bool, inode: UInt64, updatedAt: Double) {
        self.volumeID  = volumeID;  self.relPath   = relPath;   self.name      = name
        self.fileExt   = fileExt;   self.size      = size;      self.modTimeNs = modTimeNs
        self.isDir     = isDir;     self.inode     = inode;     self.updatedAt = updatedAt
    }
}

// MARK: - Errors

public enum DBError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String, sql: String)
    case bindFailed(String)
    case stepFailed(String)
    case schemaFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg):      return "DB open failed: \(msg)"
        case .prepareFailed(let msg, let sql): return "Prepare failed '\(sql)': \(msg)"
        case .bindFailed(let msg):      return "Bind failed: \(msg)"
        case .stepFailed(let msg):      return "Step failed: \(msg)"
        case .schemaFailed(let msg):    return "Schema init failed: \(msg)"
        }
    }
}

// MARK: - Statement wrapper

/// A prepared statement. Not Sendable — use only inside DatabaseManager actor.
public final class Statement {
    let handle: OpaquePointer
    private let db: OpaquePointer

    init(handle: OpaquePointer, db: OpaquePointer) {
        self.handle = handle
        self.db = db
    }

    deinit { sqlite3_finalize(handle) }

    // MARK: Bind helpers (1-based index, matching SQLite convention)

    public func bind(text value: String?, at index: Int32) throws {
        let rc: Int32
        if let v = value {
            rc = sqlite3_bind_text(handle, index, v, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        } else {
            rc = sqlite3_bind_null(handle, index)
        }
        guard rc == SQLITE_OK else { throw DBError.bindFailed(dbErrMsg(db)) }
    }

    public func bind(int value: Int64, at index: Int32) throws {
        let rc = sqlite3_bind_int64(handle, index, value)
        guard rc == SQLITE_OK else { throw DBError.bindFailed(dbErrMsg(db)) }
    }

    public func bind(double value: Double, at index: Int32) throws {
        let rc = sqlite3_bind_double(handle, index, value)
        guard rc == SQLITE_OK else { throw DBError.bindFailed(dbErrMsg(db)) }
    }

    // MARK: Step

    /// Returns true if a row is available, false on DONE.
    @discardableResult
    public func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW  { return true }
        if rc == SQLITE_DONE { return false }
        throw DBError.stepFailed("stmt.step rc=\(rc): \(dbErrMsg(db))")
    }

    public func reset() { sqlite3_reset(handle) }

    // MARK: Column readers

    public func columnText(_ col: Int32)   -> String? { sqlite3_column_text(handle, col).map { String(cString: $0) } }
    public func columnInt64(_ col: Int32)  -> Int64   { sqlite3_column_int64(handle, col) }
    public func columnDouble(_ col: Int32) -> Double  { sqlite3_column_double(handle, col) }
}

// MARK: - DatabaseManager

/// Thread-safe actor that owns the SQLite connection lifecycle.
public actor DatabaseManager {

    private var db: OpaquePointer?
    public let dbURL: URL

    /// Session-level prepared INSERT statement reused across writeBatch calls during bulk builds.
    /// nil = fallback to INSERT OR REPLACE per-batch (incremental update mode).
    private var bulkInsertStmt: OpaquePointer? = nil

    public init(dbURL: URL) async throws {
        self.dbURL = dbURL
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(dbURL.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DBError.openFailed(msg)
        }
        self.db = h
        try applyPageSize()   // must be before any table creation
        try applyPragmas()
        try createSchema()
    }

    deinit {
        if let s = bulkInsertStmt { sqlite3_finalize(s) }
        if let db { sqlite3_close(db) }
    }

    // MARK: Internal helpers

    private func requireDB() throws -> OpaquePointer {
        guard let db else { throw DBError.openFailed("Database not open") }
        return db
    }

    private func applyPageSize() throws {
        let db = try requireDB()
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, Schema.pageSizeSQL, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw DBError.schemaFailed("page_size PRAGMA failed: \(msg)")
        }
    }

    private func applyPragmas() throws {
        let db = try requireDB()
        for pragma in Schema.pragmas {
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, pragma, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errmsg)
                throw DBError.schemaFailed("PRAGMA failed: \(msg)")
            }
        }
    }

    private func createSchema() throws {
        let db = try requireDB()
        for sql in Schema.allStatements {
            var errmsg: UnsafeMutablePointer<CChar>?
            let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
            if rc != SQLITE_OK {
                let msg = errmsg.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errmsg)
                throw DBError.schemaFailed("DDL failed: \(msg) | SQL: \(sql)")
            }
        }
    }

    // MARK: Public API — DDL & control

    /// Execute a raw SQL string (no bind parameters). Use only for DDL / control statements.
    public func execute(sql: String) throws {
        let db = try requireDB()
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            // Use errmsg from sqlite3_exec first; fall back to sqlite3_errmsg.
            // Include the SQL so callers can identify which statement failed.
            let detail = errmsg.map { String(cString: $0) } ?? dbErrMsg(db)
            sqlite3_free(errmsg)
            throw DBError.stepFailed("\(detail) | SQL: \(sql)")
        }
    }

    /// Prepare a parameterised statement. Caller is responsible for binding and stepping.
    public func prepare(sql: String) throws -> Statement {
        let db = try requireDB()
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        return Statement(handle: s, db: db)
    }

    /// Convenience: run a non-SELECT statement with bound parameters.
    public func run(sql: String, binders: (Statement) throws -> Void) throws {
        let stmt = try prepare(sql: sql)
        try binders(stmt)
        try stmt.step()
    }

    // MARK: Public API — Bulk build lifecycle

    /// Phase 1: enable fast write settings for bulk-import.
    /// synchronous=OFF  — skip fsync after each commit (biggest single win).
    /// wal_autocheckpoint=0 — disable automatic WAL checkpoints mid-build so
    ///                        large checkpoints don't pause write throughput.
    /// Note: locking_mode=EXCLUSIVE is intentionally omitted; it interacts
    /// poorly with macOS WAL mode and causes confusing SQLITE_OK-masked errors.
    public func enableBulkInsertMode() throws {
        try execute(sql: "PRAGMA synchronous = OFF")
        try execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }

    /// Restore safe write settings after bulk-import. Runs a WAL checkpoint to
    /// merge the WAL file back into the main DB.
    public func restoreWriteSettings() throws {
        try execute(sql: "PRAGMA synchronous = NORMAL")
        try execute(sql: "PRAGMA wal_autocheckpoint = 1000")  // restore default
        // Merge WAL into main DB file; safe to ignore failure here
        guard let db else { return }
        var errmsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, &errmsg)
        sqlite3_free(errmsg)
    }

    /// Drop secondary indexes before bulk insert to eliminate per-row B-tree maintenance.
    /// Call rebuildSecondaryIndexes() after the bulk insert completes.
    public func dropSecondaryIndexes() throws {
        try execute(sql: "DROP INDEX IF EXISTS idx_files_name")
        try execute(sql: "DROP INDEX IF EXISTS idx_files_ext")
        try execute(sql: "DROP INDEX IF EXISTS idx_files_size")
    }

    /// Rebuild secondary indexes and run ANALYZE. Call after bulk insert is complete.
    public func rebuildSecondaryIndexes() throws {
        for sql in Schema.createFilesIndexes {
            try execute(sql: sql)
        }
        try execute(sql: "ANALYZE files")
    }

    /// Delete all file records for a volume before a full rebuild.
    /// With indexes dropped and synchronous=OFF this is fast even for 1M+ rows.
    public func deleteFilesForVolume(_ volumeID: Int64) throws {
        let db = try requireDB()
        let sql = "DELETE FROM files WHERE volume_id = ?"
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, volumeID)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.stepFailed("deleteFiles rc=\(rc): \(dbErrMsg(db))")
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Prepare a session-level INSERT statement for reuse across batches.
    /// Uses INSERT OR IGNORE so duplicate (volume_id, rel_path) from parallel scanners
    /// are silently skipped rather than crashing. Pair with endBulkWriteSession() when done.
    public func beginBulkWriteSession() throws {
        let db = try requireDB()
        let sql = """
            INSERT OR IGNORE INTO files
                (volume_id, rel_path, name, file_ext, size, mod_time_ns,
                 is_dir, inode, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        bulkInsertStmt = s
    }

    /// Finalize the session-level INSERT statement. Safe to call even if session wasn't started.
    public func endBulkWriteSession() {
        if let s = bulkInsertStmt {
            sqlite3_finalize(s)
            bulkInsertStmt = nil
        }
    }

    // MARK: Public API — Write

    /// Atomically write a batch of records inside one BEGIN/COMMIT transaction.
    /// This method never suspends internally, so Swift actor re-entrancy cannot
    /// cause two concurrent BEGIN calls.
    ///
    /// If beginBulkWriteSession() was called, uses the pre-prepared statement with
    /// pure INSERT (fast path for full rebuilds where volume data was deleted first).
    /// Otherwise falls back to INSERT OR REPLACE per batch (incremental update mode).
    public func writeBatch(_ records: [FileInsertRecord]) throws {
        guard !records.isEmpty else { return }
        let db = try requireDB()

        var errmsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, "BEGIN", nil, nil, &errmsg)
        sqlite3_free(errmsg)

        if let s = bulkInsertStmt {
            // Fast path: session-level reused statement, pure INSERT.
            for r in records {
                sqlite3_bind_int64(s, 1, r.volumeID)
                sqlite3_bind_text(s, 2, r.relPath,   -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(s, 3, r.name,      -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(s, 4, r.fileExt,   -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int64(s, 5, r.size)
                sqlite3_bind_int64(s, 6, r.modTimeNs)
                sqlite3_bind_int64(s, 7, r.isDir ? 1 : 0)
                sqlite3_bind_int64(s, 8, Int64(r.inode))
                sqlite3_bind_double(s, 9, r.updatedAt)
                let rc = sqlite3_step(s)
                if rc != SQLITE_DONE && rc != SQLITE_ROW {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    throw DBError.stepFailed("writeBatch-fast rc=\(rc): \(dbErrMsg(db))")
                }
                sqlite3_reset(s)
            }
        } else {
            // Incremental path: INSERT OR REPLACE, prepare per batch.
            let insertSQL = """
                INSERT OR REPLACE INTO files
                    (volume_id, rel_path, name, file_ext, size, mod_time_ns,
                     is_dir, inode, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK,
                  let s = stmt else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                throw DBError.prepareFailed(dbErrMsg(db), sql: insertSQL)
            }
            defer { sqlite3_finalize(s) }

            for r in records {
                sqlite3_bind_int64(s, 1, r.volumeID)
                sqlite3_bind_text(s, 2, r.relPath,   -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(s, 3, r.name,      -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_text(s, 4, r.fileExt,   -1, SQLITE_TRANSIENT_DESTRUCTOR)
                sqlite3_bind_int64(s, 5, r.size)
                sqlite3_bind_int64(s, 6, r.modTimeNs)
                sqlite3_bind_int64(s, 7, r.isDir ? 1 : 0)
                sqlite3_bind_int64(s, 8, Int64(r.inode))
                sqlite3_bind_double(s, 9, r.updatedAt)
                let rc = sqlite3_step(s)
                if rc != SQLITE_DONE && rc != SQLITE_ROW {
                    sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                    throw DBError.stepFailed("writeBatch-slow rc=\(rc): \(dbErrMsg(db))")
                }
                sqlite3_reset(s)
            }
        }

        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    /// Rebuild the FTS index from the files table. Call after bulk insert.
    public func rebuildFTS() throws {
        try execute(sql: Schema.rebuildFTS)
    }

    /// Return the last insert rowid.
    public func lastInsertRowid() throws -> Int64 {
        let db = try requireDB()
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: Public API — Atomic queries (run entirely on DatabaseManager's executor)

    /// Upsert a volume record and return its id. Runs entirely on the DatabaseManager actor —
    /// no Statement object escapes the actor boundary.
    public func upsertVolumeRecord(uuid: String, name: String, mountPath: String,
                                    fsType: String, totalSize: Int64, isExternal: Bool) throws -> Int64 {
        let db = try requireDB()
        let sql = """
            INSERT INTO volumes (volume_uuid, volume_name, mount_path, fs_type,
                                 total_size, is_external, last_scan_at)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(volume_uuid) DO UPDATE SET
                volume_name = excluded.volume_name,
                mount_path  = excluded.mount_path,
                total_size  = excluded.total_size,
                is_external = excluded.is_external
            RETURNING id
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, uuid,      -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 2, name,      -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 3, mountPath, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_text(s, 4, fsType,    -1, SQLITE_TRANSIENT_DESTRUCTOR)
        sqlite3_bind_int64(s, 5, totalSize)
        sqlite3_bind_int64(s, 6, isExternal ? 1 : 0)

        let rc = sqlite3_step(s)
        if rc == SQLITE_ROW {
            return sqlite3_column_int64(s, 0)
        }
        if rc != SQLITE_DONE {
            throw DBError.stepFailed("upsertVolumeRecord: \(dbErrMsg(db))")
        }

        // Fallback: SELECT id if RETURNING not supported (SQLite < 3.35)
        let selSQL = "SELECT id FROM volumes WHERE volume_uuid = ?"
        var sel: OpaquePointer?
        guard sqlite3_prepare_v2(db, selSQL, -1, &sel, nil) == SQLITE_OK, let ss = sel else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: selSQL)
        }
        defer { sqlite3_finalize(ss) }
        sqlite3_bind_text(ss, 1, uuid, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        _ = sqlite3_step(ss)
        return sqlite3_column_int64(ss, 0)
    }

    /// Update last_scan_at for a volume. Runs entirely on the DatabaseManager actor.
    public func updateLastScan(volumeUUID: String, timestamp: Double) throws {
        let db = try requireDB()
        let sql = "UPDATE volumes SET last_scan_at = ? WHERE volume_uuid = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_double(s, 1, timestamp)
        sqlite3_bind_text(s, 2, volumeUUID, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw DBError.stepFailed("updateLastScan: \(dbErrMsg(db))")
        }
    }

    /// Count total rows in the files table. Runs entirely on the DatabaseManager actor.
    public func countFiles() throws -> Int {
        let db = try requireDB()
        let sql = "SELECT COUNT(*) FROM files"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        defer { sqlite3_finalize(s) }
        let rc = sqlite3_step(s)
        if rc == SQLITE_ROW {
            return Int(sqlite3_column_int64(s, 0))
        }
        return 0
    }

    // MARK: Public API — Search

    /// Generic row fetcher. Executes `sql` with bound parameters and maps each row via `mapper`.
    /// The `Statement` is valid only for the duration of the `mapper` call.
    public func queryRows<T>(
        sql: String,
        binders: (Statement) throws -> Void,
        mapper: (Statement) throws -> T
    ) throws -> [T] {
        let stmt = try prepare(sql: sql)
        try binders(stmt)
        var results: [T] = []
        while try stmt.step() {
            results.append(try mapper(stmt))
        }
        return results
    }

    /// Count query: returns the integer value in column 0 of the first row.
    public func queryCount(sql: String, binders: (Statement) throws -> Void) throws -> Int {
        let stmt = try prepare(sql: sql)
        try binders(stmt)
        if try stmt.step() {
            return Int(stmt.columnInt64(0))
        }
        return 0
    }

    // MARK: Public API — Single-record writes (for FSEvents incremental updates)

    /// Upsert a single file record (INSERT OR REPLACE).
    public func upsertFile(_ record: FileInsertRecord) throws {
        try writeBatch([record])
    }

    /// Delete a single file record by volumeID + relPath.
    public func deleteFile(volumeID: Int64, relPath: String) throws {
        let db = try requireDB()
        let sql = "DELETE FROM files WHERE volume_id = ? AND rel_path = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: sql)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, volumeID)
        sqlite3_bind_text(s, 2, relPath, -1, SQLITE_TRANSIENT_DESTRUCTOR)
        let rc = sqlite3_step(s)
        if rc != SQLITE_DONE && rc != SQLITE_ROW {
            throw DBError.stepFailed("deleteFile rc=\(rc): \(dbErrMsg(db))")
        }
    }

    // MARK: Public API — Snapshot diff (external drive remount)

    /// Apply a full snapshot diff for `volumeID`:
    ///   1. Inserts all `snapshot` rows into a TEMP table.
    ///   2. Upserts rows that are new or have changed metadata.
    ///   3. Deletes rows that no longer appear in the snapshot.
    ///   4. Drops the TEMP table.
    ///
    /// Diff key: (rel_path, mod_time_ns, size, is_dir) per PRD §7.3.
    ///
    /// Returns (upserted, deleted) affected row counts.
    public func applySnapshotDiff(
        volumeID: Int64,
        snapshot: [FileInsertRecord]
    ) throws -> (upserted: Int, deleted: Int) {
        let db = try requireDB()

        // ── Create / clear temp table ────────────────────────────────────────
        let createTmp = """
            CREATE TEMP TABLE IF NOT EXISTS tmp_snapshot (
                rel_path    TEXT PRIMARY KEY,
                name        TEXT NOT NULL,
                file_ext    TEXT DEFAULT '',
                size        INTEGER DEFAULT 0,
                mod_time_ns INTEGER NOT NULL,
                is_dir      INTEGER DEFAULT 0,
                inode       INTEGER DEFAULT 0,
                updated_at  REAL    NOT NULL
            )
            """
        var errmsg: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, createTmp, nil, nil, &errmsg); sqlite3_free(errmsg)
        sqlite3_exec(db, "DELETE FROM tmp_snapshot", nil, nil, &errmsg); sqlite3_free(errmsg)

        // ── Bulk insert snapshot ─────────────────────────────────────────────
        let insertSQL = """
            INSERT OR REPLACE INTO tmp_snapshot
                (rel_path, name, file_ext, size, mod_time_ns, is_dir, inode, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """
        var ins: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK, let insStmt = ins else {
            throw DBError.prepareFailed(dbErrMsg(db), sql: insertSQL)
        }
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for r in snapshot {
            sqlite3_bind_text(ins, 1, r.relPath,  -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(ins, 2, r.name,     -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(ins, 3, r.fileExt,  -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_int64(ins, 4, r.size)
            sqlite3_bind_int64(ins, 5, r.modTimeNs)
            sqlite3_bind_int64(ins, 6, r.isDir ? 1 : 0)
            sqlite3_bind_int64(ins, 7, Int64(r.inode))
            sqlite3_bind_double(ins, 8, r.updatedAt)
            let rc = sqlite3_step(ins)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                sqlite3_finalize(insStmt)
                throw DBError.stepFailed("snapshotDiff-insert rc=\(rc): \(dbErrMsg(db))")
            }
            sqlite3_reset(ins)
        }
        sqlite3_finalize(insStmt)
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        // ── Upsert changed / new rows ────────────────────────────────────────
        let upsertSQL = """
            INSERT OR REPLACE INTO files
                (volume_id, rel_path, name, file_ext, size, mod_time_ns, is_dir, inode, updated_at)
            SELECT ?, t.rel_path, t.name, t.file_ext, t.size, t.mod_time_ns,
                   t.is_dir, t.inode, t.updated_at
            FROM tmp_snapshot t
            WHERE NOT EXISTS (
                SELECT 1 FROM files f
                WHERE f.volume_id = ?
                  AND f.rel_path    = t.rel_path
                  AND f.mod_time_ns = t.mod_time_ns
                  AND f.size        = t.size
                  AND f.is_dir      = t.is_dir
            )
            """
        var us: OpaquePointer?
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        guard sqlite3_prepare_v2(db, upsertSQL, -1, &us, nil) == SQLITE_OK, let usStmt = us else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.prepareFailed(dbErrMsg(db), sql: upsertSQL)
        }
        sqlite3_bind_int64(us, 1, volumeID)
        sqlite3_bind_int64(us, 2, volumeID)
        let upsertRC = sqlite3_step(us)
        sqlite3_finalize(usStmt)
        if upsertRC != SQLITE_DONE && upsertRC != SQLITE_ROW {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.stepFailed("snapshotDiff-upsert rc=\(upsertRC): \(dbErrMsg(db))")
        }
        let upserted = Int(sqlite3_changes(db))
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        // ── Delete removed rows ───────────────────────────────────────────────
        let deleteSQL = """
            DELETE FROM files
            WHERE volume_id = ?
              AND NOT EXISTS (
                  SELECT 1 FROM tmp_snapshot WHERE rel_path = files.rel_path
              )
            """
        var ds: OpaquePointer?
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        guard sqlite3_prepare_v2(db, deleteSQL, -1, &ds, nil) == SQLITE_OK, let dsStmt = ds else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.prepareFailed(dbErrMsg(db), sql: deleteSQL)
        }
        sqlite3_bind_int64(ds, 1, volumeID)
        let deleteRC = sqlite3_step(ds)
        sqlite3_finalize(dsStmt)
        if deleteRC != SQLITE_DONE && deleteRC != SQLITE_ROW {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw DBError.stepFailed("snapshotDiff-delete rc=\(deleteRC): \(dbErrMsg(db))")
        }
        let deleted = Int(sqlite3_changes(db))
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        sqlite3_exec(db, "DROP TABLE IF EXISTS tmp_snapshot", nil, nil, nil)

        return (upserted: upserted, deleted: deleted)
    }
}

// MARK: - Helpers

private func dbErrMsg(_ db: OpaquePointer?) -> String {
    guard let db else { return "no db" }
    return String(cString: sqlite3_errmsg(db))
}
