// BatchWriter.swift — Converts FileRecord batches to FileInsertRecord and
// delegates to DatabaseManager.writeBatch, which is a single atomic actor method.
// This eliminates the BEGIN/COMMIT re-entrancy issue: the entire transaction
// runs without suspension inside one DatabaseManager method invocation.
//
// Stage 0 instrumentation: tracks total write time so IndexManager can compute
// db_write_ms_per_batch and distinguish "scan slow" vs "write slow".

import Foundation
import Database

public actor BatchWriter {

    private let db: DatabaseManager
    private var totalWritten: Int = 0

    // Stage 0: write-side timing
    private var totalWriteMs: Double = 0
    private var writeBatchCount: Int = 0

    public init(db: DatabaseManager) {
        self.db = db
    }

    /// Write one batch atomically. Returns cumulative rows written.
    @discardableResult
    public func write(batch: [FileRecord]) async throws -> Int {
        guard !batch.isEmpty else { return totalWritten }

        let now = Date().timeIntervalSinceReferenceDate
        let insertRecords = batch.map { r in
            FileInsertRecord(
                volumeID:   r.volumeID,
                relPath:    r.relPath,
                name:       r.name,
                fileExt:    r.fileExt,
                size:       r.size,
                modTimeNs:  r.modTimeNs,
                isDir:      r.isDir,
                inode:      r.inode,
                updatedAt:  now
            )
        }

        let t0 = DispatchTime.now().uptimeNanoseconds
        try await db.writeBatch(insertRecords)
        let dtMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000

        totalWritten += batch.count
        totalWriteMs += dtMs
        writeBatchCount += 1
        return totalWritten
    }

    public var count: Int { totalWritten }

    /// Average time spent inside db.writeBatch() per call, in milliseconds.
    /// Returns 0 before the first batch is written.
    public var avgWriteMsPerBatch: Double {
        writeBatchCount > 0 ? totalWriteMs / Double(writeBatchCount) : 0
    }
}
