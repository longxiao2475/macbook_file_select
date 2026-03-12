// IncrementalUpdater.swift — Incremental index updates for APFS/HFS+ and external drives.
//
// PRD §7.2 (APFS/HFS+): FSEvents paths → re-stat → upsert/delete individual records.
// PRD §7.3 (external drives): mount event → full snapshot diff via tmp_snapshot SQL table.
//
// Snapshot diff algorithm (PRD §7.3):
//   1. Re-scan the entire external volume via InodeSortedScanner / BSDScanner.
//   2. Pass all scanned records to DatabaseManager.applySnapshotDiff().
//   3. SQL diff: INSERT OR REPLACE for new/changed rows; DELETE for missing rows.
//   Diff key: (rel_path, mod_time_ns, size, is_dir) — avoids false negatives from same-second mtime.

import Foundation
import Darwin
import Database

// MARK: - DiffResult

public struct DiffResult: Sendable {
    /// Rows inserted or updated (new files + changed metadata).
    public let upserted: Int
    /// Rows deleted (files no longer on disk).
    public let deleted: Int
    public let elapsedSeconds: Double
}

// MARK: - IncrementalUpdater

public actor IncrementalUpdater {

    private let db: DatabaseManager

    public init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - FSEvents handler (APFS/HFS+ incremental update)

    /// Process a batch of FSEvents-changed paths: re-stat each path and upsert/delete DB records.
    ///
    /// - Parameters:
    ///   - paths: Absolute paths reported by FSEventStream (may include directories).
    ///   - volumeInfo: Volume metadata for the monitored volume.
    ///   - volumeID: Database row id for the volume.
    public func handleFSEvents(
        paths: [String],
        volumeInfo: VolumeInfo,
        volumeID: Int64
    ) async throws {
        let mountPath = volumeInfo.mountPath.hasSuffix("/") ? volumeInfo.mountPath
                                                           : volumeInfo.mountPath + "/"
        let mountPrefixLen = mountPath.utf8.count - 1
        let now = Date().timeIntervalSinceReferenceDate

        var toUpsert: [FileInsertRecord] = []
        var toDelete: [String] = []   // rel_paths to delete

        for absPath in paths {
            var st = Darwin.stat()
            if Darwin.lstat(absPath, &st) != 0 {
                // Path no longer exists → delete from index.
                let rel = relPath(of: absPath, mountPrefixLen: mountPrefixLen)
                toDelete.append(rel)
                continue
            }

            let mode = st.st_mode & S_IFMT
            guard mode == S_IFREG || mode == S_IFDIR else { continue }
            let isDir = mode == S_IFDIR

            let rel = relPath(of: absPath, mountPrefixLen: mountPrefixLen)
            let name = (absPath as NSString).lastPathComponent
            let ext = isDir ? "" : fileExt(of: name)
            let modNs = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000
                      + Int64(st.st_mtimespec.tv_nsec)

            toUpsert.append(FileInsertRecord(
                volumeID: volumeID,
                relPath: rel,
                name: name,
                fileExt: ext,
                size: Int64(st.st_size),
                modTimeNs: modNs,
                isDir: isDir,
                inode: UInt64(st.st_ino),
                updatedAt: now
            ))
        }

        if !toUpsert.isEmpty {
            try await db.writeBatch(toUpsert)
        }
        for rel in toDelete {
            try await db.deleteFile(volumeID: volumeID, relPath: rel)
        }
    }

    // MARK: - Snapshot diff (external drive remount)

    /// Full differential rescan of an external volume.
    /// Scans the current state into a snapshot and applies SQL-based diff against the DB.
    ///
    /// - Parameters:
    ///   - volumeInfo: Volume metadata.
    ///   - volumeID: Database row id for the volume.
    ///   - mode: Scan mode (`.full` or `.priorityOnly`).
    ///   - excludePrefixes: Path prefixes to skip entirely.
    ///   - excludedDirNames: Directory names to skip (added to NTFS built-in set).
    public func snapshotDiff(
        volumeInfo: VolumeInfo,
        volumeID: Int64,
        mode: ScanMode = .full,
        excludePrefixes: [String] = [],
        excludedDirNames: Set<String> = []
    ) async throws -> DiffResult {
        let startDate = Date()

        // Build the complete exclusion set.
        let isNTFS = volumeInfo.fsType.lowercased().hasPrefix("ntfs")
        var allExcluded = isNTFS ? IncrementalUpdater.ntfsBuiltinExcludedDirs : Set<String>()
        if case .priorityOnly = mode {
            allExcluded.formUnion(IncrementalUpdater.cacheBuiltinExcludedDirs)
        }
        allExcluded.formUnion(excludedDirNames)

        let priorityExtensions: Set<String>? = (mode == .priorityOnly)
            ? IndexManager.defaultPriorityExtensions
            : nil

        // Re-scan the volume using InodeSortedScanner (NTFS external) or BSDScanner.
        let useInodeSort = isNTFS && volumeInfo.isExternal
        var snapshot: [FileInsertRecord] = []
        let now = Date().timeIntervalSinceReferenceDate

        if useInodeSort {
            let scanner = InodeSortedScanner(
                rootPaths: [volumeInfo.mountPath],
                mountPath: volumeInfo.mountPath,
                volumeID: volumeID,
                excludePrefixes: excludePrefixes,
                excludedDirNames: allExcluded,
                priorityExtensions: priorityExtensions
            )
            let (stream, _) = scanner.scan()
            for await batch in stream {
                snapshot.append(contentsOf: batch.records.map { toInsertRecord($0, updatedAt: now) })
            }
        } else {
            let scanner = BSDScanner(
                rootPaths: [volumeInfo.mountPath],
                mountPath: volumeInfo.mountPath,
                volumeID: volumeID,
                excludePrefixes: excludePrefixes,
                excludedDirNames: allExcluded,
                priorityExtensions: priorityExtensions
            )
            for await batch in scanner.scan() {
                snapshot.append(contentsOf: batch.records.map { toInsertRecord($0, updatedAt: now) })
            }
        }

        // Apply SQL diff.
        let (upserted, deleted) = try await db.applySnapshotDiff(
            volumeID: volumeID,
            snapshot: snapshot
        )

        let elapsed = Date().timeIntervalSince(startDate)
        return DiffResult(upserted: upserted, deleted: deleted, elapsedSeconds: elapsed)
    }

    // MARK: - Private helpers

    private func relPath(of absPath: String, mountPrefixLen: Int) -> String {
        let u8 = absPath.utf8
        guard u8.count > mountPrefixLen,
              let idx = u8.index(u8.startIndex,
                                 offsetBy: mountPrefixLen,
                                 limitedBy: u8.endIndex) else { return "/" }
        return String(absPath[idx...])
    }

    private func fileExt(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."),
              dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    private func toInsertRecord(_ r: FileRecord, updatedAt: Double) -> FileInsertRecord {
        FileInsertRecord(
            volumeID:  r.volumeID,
            relPath:   r.relPath,
            name:      r.name,
            fileExt:   r.fileExt,
            size:      r.size,
            modTimeNs: r.modTimeNs,
            isDir:     r.isDir,
            inode:     r.inode,
            updatedAt: updatedAt
        )
    }

    // Reuse the same built-in exclusion sets from IndexManager.
    private static let ntfsBuiltinExcludedDirs: Set<String> = [
        "$RECYCLE.BIN", "System Volume Information",
        "$MFT", "$MFTMirr", "$LogFile", "$Volume", "$AttrDef",
        "$Bitmap", "$Boot", "$BadClus", "$Secure", "$UpCase", "$Extend",
        "pagefile.sys", "hiberfil.sys", "swapfile.sys",
    ]

    private static let cacheBuiltinExcludedDirs: Set<String> = [
        "node_modules", ".npm", ".yarn", ".pnpm-store",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", "venv", ".venv",
        ".gradle", ".m2", "DerivedData", ".cargo", ".cache",
        ".git", ".svn", ".hg", ".bzr",
        ".Trash", ".Trashes", ".Spotlight-V100", ".MobileBackups", "Thumbs",
    ]
}

// MARK: - ScanMode (conform to Equatable for comparison)
extension ScanMode: Equatable {
    public static func == (lhs: ScanMode, rhs: ScanMode) -> Bool {
        switch (lhs, rhs) {
        case (.full, .full), (.priorityOnly, .priorityOnly), (.supplement, .supplement): return true
        default: return false
        }
    }
}
